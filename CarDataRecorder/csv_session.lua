-- A growing telemetry schema cannot be put in the header of an already written CSV.
-- Keep an append-only, checksummed JSONL journal while recording, then stream a wide
-- CSV with the union of all discovered fields. The journal is never removed.
local csvSession = {}
local Session = {}
Session.__index = Session

local FORMAT = 'CarDataRecorder journal'
local VERSION = 1

local function finite(value)
  return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer(value)
  return finite(value) and value >= 0 and value == math.floor(value)
end

local function clock()
  local ok, value = pcall(os.preciseClock)
  if ok and finite(value) then return value end
  return os.clock()
end

local function numericText(value)
  return string.format('%.17g', value)
end

local function quote(value)
  -- Retain embedded CR/LF and quotes exactly: CSV readers understand quoted fields.
  return '"' .. tostring(value == nil and '' or value):gsub('"', '""') .. '"'
end

local function csvLine(values)
  local result = {}
  for i = 1, #values do result[i] = quote(values[i]) end
  return table.concat(result, ',') .. '\r\n'
end

local function fileCall(file, method, ...)
  if not file then return false, 'No file handle for ' .. method end
  local ok, result, err = pcall(function(...) return file[method](file, ...) end, ...)
  if not ok then return false, tostring(result) end
  if not result then return false, tostring(err or (method .. ' failed')) end
  return true, result
end

local function openFile(path, mode)
  local ok, file, err = pcall(io.open, path, mode)
  if not ok then return nil, tostring(file) end
  if not file then return nil, tostring(err or 'io.open failed') end
  return file
end

local function ioBoolean(fn, ...)
  local ok, result, err = pcall(fn, ...)
  if not ok then return false, tostring(result) end
  if not result then return false, tostring(err or 'File operation failed') end
  return true
end

local function exists(path)
  local ok, result = pcall(io.exists, path)
  if not ok then return nil, tostring(result) end
  return result == true
end

local function checksum(text)
  -- Adler-32 protects complete records even with CSP's deliberately lenient JSON parser.
  local a, b = 1, 0
  for i = 1, #text do
    a = (a + text:byte(i)) % 65521
    b = (b + a) % 65521
  end
  return string.format('%.0f', b * 65536 + a)
end

local function serialize(record)
  local ok, payload = pcall(JSON.stringify, record)
  if not ok or type(payload) ~= 'string' then
    return nil, 'Could not serialize journal record: ' .. tostring(payload)
  end
  local encodedOK, encoded = pcall(JSON.stringify, {
    version = VERSION, checksum = checksum(payload), payload = payload
  })
  if not encodedOK or type(encoded) ~= 'string' then
    return nil, 'Could not serialize journal envelope: ' .. tostring(encoded)
  end
  return encoded .. '\n'
end

local function deserialize(line)
  if type(line) ~= 'string' or line:sub(1, 1) ~= '{' or line:sub(-1) ~= '}' then
    return nil, 'Incomplete or invalid journal line', true
  end
  local ok, envelope = pcall(JSON.parse, line)
  if not ok or type(envelope) ~= 'table' then
    return nil, 'Invalid journal envelope JSON', true
  end
  if envelope.version ~= VERSION or type(envelope.payload) ~= 'string' or type(envelope.checksum) ~= 'string' then
    return nil, 'Invalid journal envelope schema', false
  end
  if checksum(envelope.payload) ~= envelope.checksum then
    return nil, 'Journal checksum mismatch (possibly an interrupted write)', true
  end
  local parsedOK, record = pcall(JSON.parse, envelope.payload)
  if not parsedOK or type(record) ~= 'table' or type(record.type) ~= 'string' then
    return nil, 'Invalid journal record schema', false
  end
  return record
end

local function copyColumns(columns)
  if type(columns) ~= 'table' or #columns == 0 then return nil, 'No base columns supplied' end
  local result, names = {}, {}
  for i = 1, #columns do
    local column = columns[i]
    if type(column) ~= 'table' then return nil, 'Invalid base column ' .. i end
    local name, unit = column.name or column[1], column.unit or column[2] or ''
    if type(name) ~= 'string' or name == '' or type(unit) ~= 'string' or names[name] then
      return nil, 'Invalid or duplicated base column name at index ' .. i
    end
    result[i], names[name] = {name = name, unit = unit}, true
  end
  return result
end

local function safeField(definition, id)
  if type(definition) ~= 'table' or type(definition.name) ~= 'string' or definition.name == '' then
    return nil, 'A dynamic field needs a non-empty name'
  end
  local result = {id = id, name = definition.name, unit = definition.unit or '',
    event = definition.event or '', path = definition.path or '', source = definition.source or ''}
  for _, key in ipairs({'unit', 'event', 'path'}) do
    if type(result[key]) ~= 'string' then return nil, 'Field ' .. key .. ' must be a string' end
  end
  if type(result.source) == 'table' then
    local source = {}
    for key, value in pairs(result.source) do
      if type(key) ~= 'string' or (type(value) ~= 'string' and type(value) ~= 'boolean' and not finite(value)) then
        return nil, 'Field source metadata must contain primitive string-keyed values'
      end
      source[key] = value
    end
    result.source = source
  elseif type(result.source) ~= 'string' then
    return nil, 'Field source must be a string or metadata table'
  end
  return result
end

local function groupNames(name)
  -- The journal still keeps all diagnostic metadata; CSV exposes values only.
  return {name}
end

local function sameField(a, b)
  if not a or not b or a.id ~= b.id or a.name ~= b.name or a.unit ~= b.unit
      or a.event ~= b.event or a.path ~= b.path or type(a.source) ~= type(b.source) then return false end
  if type(a.source) ~= 'table' then return a.source == b.source end
  for key, value in pairs(a.source) do if b.source[key] ~= value then return false end end
  for key, value in pairs(b.source) do if a.source[key] ~= value then return false end end
  return true
end

function Session:_reserveField(field)
  for _, name in ipairs(groupNames(field.name)) do
    if self._columnNames[name] then return false, 'Duplicated CSV column: ' .. name end
  end
  for _, name in ipairs(groupNames(field.name)) do self._columnNames[name] = true end
  return true
end

function Session:_resetColumns(columns)
  local copied, err = copyColumns(columns)
  if not copied then return false, err end
  self.baseColumns, self._columnNames, self.fields = copied, {}, {}
  for i = 1, #copied do self._columnNames[copied[i].name] = true end
  return true
end

function Session:_closeHandles()
  local errors = {}
  for _, key in ipairs({'_journal', '_reader', '_output'}) do
    local file = self[key]
    self[key] = nil
    if file then
      if key ~= '_reader' then
        local ok, err = fileCall(file, 'flush')
        if not ok then errors[#errors + 1] = err end
      end
      local ok, err = fileCall(file, 'close')
      if not ok then errors[#errors + 1] = err end
    end
  end
  return #errors == 0, table.concat(errors, '; ')
end

function Session:_fail(message)
  self.recording, self.exporting, self.complete = false, false, false
  self.error = tostring(message)
  local ok, err = self:_closeHandles()
  if not ok then self.error = self.error .. '; while closing: ' .. err end
  return false, self.error
end

function Session:_writeRecord(record)
  local text, err = serialize(record)
  if not text then return self:_fail(err) end
  local ok, writeErr = fileCall(self._journal, 'write', text)
  if not ok then return self:_fail('Journal write failed: ' .. writeErr) end
  return true
end

local function uniquePaths(base, journalRequired)
  local suffix = 0
  while true do
    local candidate = base .. (suffix == 0 and '' or '_' .. suffix)
    local csv, journal, partial = candidate .. '.csv', candidate .. '.journal.jsonl', candidate .. '.csv.partial'
    local csvExists, err = exists(csv)
    if csvExists == nil then return nil, err end
    local partialExists, partialErr = exists(partial)
    if partialExists == nil then return nil, partialErr end
    local journalExists = false
    if journalRequired then
      journalExists, err = exists(journal)
      if journalExists == nil then return nil, err end
    end
    if not csvExists and not partialExists and not journalExists then
      return {filePath = csv, journalPath = journal, partialPath = partial}
    end
    suffix = suffix + 1
  end
end

function Session:start()
  if self.recording then return true end
  if self.exporting then return false, 'Wait for the current CSV export to finish' end
  local closed, closeErr = self:_closeHandles()
  if not closed then return self:_fail('Could not close previous files: ' .. closeErr) end
  for _, key in ipairs({'bodyFrame', 'anglePositive'}) do
    if self.options[key] ~= nil and type(self.options[key]) ~= 'string' then
      return self:_fail('Optional ' .. key .. ' metadata must be a string')
    end
  end
  self.error, self.complete, self.recovered, self.recoveryNotice = nil, false, false, nil
  self.dataCount, self.exportedRows, self._lastTime, self.duration = 0, 0, nil, 0
  self._ignoredTail = nil
  self.sampleRate = finite(self.options.sampleRate) and self.options.sampleRate > 0 and self.options.sampleRate or 50
  local columnsOK, columnsErr = self:_resetColumns(self.options.baseColumns)
  if not columnsOK then return self:_fail(columnsErr) end
  local folderOK, docsPath = pcall(ac.getFolder, ac.FolderID.ACDocuments)
  if not folderOK or type(docsPath) ~= 'string' or docsPath == '' then
    return self:_fail('Could not find Assetto Corsa Documents folder')
  end
  local directoryOK, directoryExists = pcall(io.dirExists, docsPath)
  if not directoryOK then return self:_fail(tostring(directoryExists)) end
  if not directoryExists then
    local created, createErr = ioBoolean(io.createDir, docsPath)
    if not created then return self:_fail('Could not create Documents folder: ' .. createErr) end
  end
  local paths, err = uniquePaths(docsPath:gsub('[\\/]+$', '') .. '\\car_data_' .. os.date('%Y%m%d_%H%M%S'), true)
  if not paths then return self:_fail('Could not choose output path: ' .. err) end
  self.filePath, self.journalPath, self.partialPath = paths.filePath, paths.journalPath, paths.partialPath
  local file, openErr = openFile(self.journalPath, 'wb')
  if not file then return self:_fail('Could not create journal: ' .. openErr) end
  self._journal = file
  self.metadata = {format = FORMAT, version = VERSION, baseColumns = self.baseColumns,
    sampleRate = self.sampleRate, carName = tostring(self.options.carName or 'Unknown'),
    driverName = tostring(self.options.driverName or 'Unknown'),
    date = os.date('%Y-%m-%d'), startTime = os.date('%H:%M:%S'),
    bodyFrame = self.options.bodyFrame, anglePositive = self.options.anglePositive}
  local wrote, writeErr = self:_writeRecord({type = 'header', metadata = self.metadata})
  if not wrote then return false, writeErr end
  local flushed, flushErr = fileCall(self._journal, 'flush')
  if not flushed then return self:_fail('Could not flush journal header: ' .. flushErr) end
  self.startedWall = clock()
  self._lastFlushWall, self.recording = self.startedWall, true
  return true
end

function Session:addField(definition)
  if not self.recording then return nil, self.error or 'Not recording' end
  local field, err = safeField(definition, #self.fields + 1)
  if not field then return nil, err end
  local originalName, suffix = field.name, 0
  while true do
    local free = true
    for _, name in ipairs(groupNames(field.name)) do
      if self._columnNames[name] then free = false; break end
    end
    if free then break end
    suffix = suffix + 1
    field.name = originalName .. '__source' .. (suffix + 1)
  end
  -- Schema must be written before the first sample referencing its field ID.
  local ok, writeErr = self:_writeRecord({type = 'field', field = field})
  if not ok then return nil, writeErr end
  self.fields[#self.fields + 1] = field
  self:_reserveField(field)
  return field.id
end

local function normalizedSample(self, row)
  if type(row) ~= 'table' or not finite(row.time) then return nil, 'Sample time must be finite' end
  if type(row.base) ~= 'table' or #row.base ~= #self.baseColumns then
    return nil, 'Base sample column count does not match the schema'
  end
  local base, custom = {}, {}
  for i = 1, #self.baseColumns do
    if type(row.base[i]) ~= 'string' then return nil, 'Base values must be CSV value strings' end
    base[i] = row.base[i]
  end
  if row.custom ~= nil and type(row.custom) ~= 'table' then return nil, 'Custom sample must be a table' end
  for id, value in pairs(row.custom or {}) do
    local index = type(id) == 'string' and tonumber(id) or nil
    if not integer(index) or index < 1 or tostring(index) ~= id or not self.fields[index] then
      return nil, 'Sample references an unknown field ID: ' .. tostring(id)
    end
    if type(value) ~= 'table' or type(value.value) ~= 'string' or type(value.kind) ~= 'string'
        or not integer(value.updates or 0) or (value.received ~= nil and not finite(value.received)) then
      return nil, 'Invalid custom value for field ' .. id
    end
    custom[id] = {value = value.value, kind = value.kind,
      received = value.received ~= nil and numericText(value.received) or '',
      updates = string.format('%.0f', value.updates or 0)}
  end
  return {type = 'sample', time = numericText(row.time), base = base, custom = custom}
end

function Session:append(row)
  if not self.recording then return false, self.error or 'Not recording' end
  local sample, err = normalizedSample(self, row)
  if not sample then return self:_fail(err) end
  local ok, writeErr = self:_writeRecord(sample)
  if not ok then return false, writeErr end
  self.dataCount, self._lastTime = self.dataCount + 1, sample.time
  self.duration = row.time
  return true
end

function Session:flushIfDue(nowWall)
  if not self.recording then return self.error == nil, self.error end
  local now = finite(nowWall) and nowWall or clock()
  if now < self._lastFlushWall then self._lastFlushWall = now end
  if now - self._lastFlushWall < 1 then return true end
  local ok, err = fileCall(self._journal, 'flush')
  if not ok then return self:_fail('Journal flush failed: ' .. err) end
  self._lastFlushWall = now
  return true
end

function Session:_writeCSVHeader()
  local metadata = self.metadata
  local frameComment
  if metadata.bodyFrame == 'X_forward_Y_left_Z_up' then
    frameComment = 'Body axes: X=forward, Y=left, Z=up (right-handed). '
      .. 'Body acceleration and force/moment components use these axes. '
      .. 'Wheel longitudinal/lateral forces are positive forward/left. '
      .. 'Wheel slip is the negative of AC solver slipAngle in radians, retaining its low-speed relaxation and reverse-driving convention; '
      .. 'it is not a full-range velocity angle. CG sideslip is atan2(body velocity Y, body velocity X), unavailable below 0.1 m/s. '
  elseif metadata.bodyFrame ~= nil and metadata.bodyFrame ~= '' then
    frameComment = 'Recorded body frame: ' .. metadata.bodyFrame .. '. Recovery does not change its components. '
  else
    frameComment = 'Body frame is unspecified in this journal; recovery does not infer or change it. '
  end
  if metadata.anglePositive == 'counterclockwise_viewed_from_above' then
    frameComment = frameComment .. 'Planar angles, yaw and steering are positive counterclockwise viewed from above. '
  elseif metadata.anglePositive ~= nil and metadata.anglePositive ~= '' then
    frameComment = frameComment .. 'Recorded angular sign convention: ' .. metadata.anglePositive .. '. '
  else
    frameComment = frameComment .. 'Angular sign convention is unspecified in this journal. '
  end
  local comment = 'Target ' .. tostring(metadata.sampleRate) .. ' Hz; frame-driven irregular simulation '
    .. self.baseColumns[1].name .. '; '
    .. 'no fabricated catch-up rows. Dynamic values are arrivals since the preceding sample, not held values. '
    .. 'CSV contains one value column per channel; missing or nil values are blank, true zero remains zero. '
    .. 'Types, receiver wall-clock timestamps, per-field arrival counts and sender identities are retained in the journal. '
    .. 'Receiver timestamps are not ECU generation times. Unknown custom units are unspecified. '
    .. 'Position remains fixed AC world XYZ in metres; it is not rotated into the vehicle frame. '
    .. frameComment
    .. 'All dynamic fields discovered during this recording are included in this header.'
  if self.recoveryNotice then comment = comment .. ' ' .. self.recoveryNotice end
  local rows = {
    {'Format', 'AiM CSV File'}, {'Session', 'Unknown'}, {'Vehicle', metadata.carName},
    {'Racer', metadata.driverName}, {'Championship', ''}, {'Comment', comment},
    {'Date', metadata.date}, {'Time', metadata.startTime}, {'Sample Rate', metadata.sampleRate},
    {'Duration', self._lastTime or '0'}, {'Beacon Markers', 'Unknown'}, {'Segment Times', 'Unknown'}
  }
  local lines = {}
  for i = 1, #rows do lines[#lines + 1] = csvLine(rows[i]) end
  lines[#lines + 1] = '\r\n'
  local names, units = {}, {}
  for i = 1, #self.baseColumns do
    names[#names + 1], units[#units + 1] = self.baseColumns[i].name, self.baseColumns[i].unit
  end
  for i = 1, #self.fields do
    local field = self.fields[i]
    names[#names + 1] = field.name
    units[#units + 1] = field.unit
  end
  lines[#lines + 1] = csvLine(names)
  lines[#lines + 1] = csvLine(units)
  lines[#lines + 1] = '\r\n'
  local ok, err = fileCall(self._output, 'write', table.concat(lines))
  if not ok then return self:_fail('CSV header write failed: ' .. err) end
  return true
end

function Session:_newScan()
  self._scan = {header = false, footer = false, fields = 0, rows = 0, line = 0, lastTime = nil,
    ignoredTailVerified = false}
end

function Session:_beginOutput()
  local reader, readErr = openFile(self.journalPath, 'rb')
  if not reader then return self:_fail('Could not read journal: ' .. readErr) end
  self._reader = reader
  local existsAlready, existsErr = exists(self.partialPath)
  if existsAlready == nil then return self:_fail(existsErr) end
  if existsAlready then return self:_fail('Refusing to overwrite existing partial CSV: ' .. self.partialPath) end
  local output, writeErr = openFile(self.partialPath, 'wb')
  if not output then return self:_fail('Could not create partial CSV: ' .. writeErr) end
  self._output, self.exportedRows, self._phase = output, 0, 'output'
  self:_newScan()
  local ok, err = self:_writeCSVHeader()
  if not ok then return false, err end
  self.exporting = true
  return true
end

function Session:finish()
  if self.exporting then return true end
  if not self.recording then
    if self.complete then return true end
    return false, self.error or 'Not recording'
  end
  local ok, err = self:_writeRecord({type = 'end', rows = self.dataCount, fields = #self.fields,
    lastTime = self._lastTime or ''})
  if not ok then return false, err end
  local flushed, flushErr = fileCall(self._journal, 'flush')
  local closed, closeErr = fileCall(self._journal, 'close')
  self._journal, self.recording = nil, false
  if not flushed or not closed then return self:_fail('Could not finalize journal: ' .. (flushErr or closeErr)) end
  self._expectedRows, self._expectedFields, self._allowInterrupted = self.dataCount, #self.fields, false
  return self:_beginOutput()
end

local function validateStoredSample(self, record, knownFields)
  if type(record.time) ~= 'string' or not finite(tonumber(record.time)) or type(record.base) ~= 'table'
      or #record.base ~= #self.baseColumns or type(record.custom) ~= 'table' then
    return false, 'Invalid sample layout'
  end
  for i = 1, #self.baseColumns do
    if type(record.base[i]) ~= 'string' then return false, 'Invalid stored base value' end
  end
  for id, value in pairs(record.custom) do
    local index = type(id) == 'string' and tonumber(id) or nil
    if not integer(index) or index < 1 or tostring(index) ~= id or index > knownFields then
      return false, 'Sample references a field before its schema definition'
    end
    if type(value) ~= 'table' or type(value.value) ~= 'string' or type(value.kind) ~= 'string'
        or type(value.received) ~= 'string' or (value.received ~= '' and not finite(tonumber(value.received)))
        or type(value.updates) ~= 'string' or not integer(tonumber(value.updates)) then
      return false, 'Invalid stored custom value'
    end
  end
  return true
end

function Session:_consumeRecord(record)
  local scan = self._scan
  if scan.footer then return false, 'Record found after end marker' end
  if not scan.header then
    if record.type ~= 'header' or type(record.metadata) ~= 'table' then return false, 'Missing journal header' end
    local m = record.metadata
    if m.format ~= FORMAT or m.version ~= VERSION or not finite(m.sampleRate) or m.sampleRate <= 0
        or type(m.carName) ~= 'string' or type(m.driverName) ~= 'string'
        or type(m.date) ~= 'string' or type(m.startTime) ~= 'string'
        or (m.bodyFrame ~= nil and type(m.bodyFrame) ~= 'string')
        or (m.anglePositive ~= nil and type(m.anglePositive) ~= 'string') then
      return false, 'Invalid journal metadata'
    end
    if self._phase == 'scan' then
      local ok, err = self:_resetColumns(m.baseColumns)
      if not ok then return false, err end
      self.metadata, self.sampleRate = m, m.sampleRate
    else
      if m.bodyFrame ~= self.metadata.bodyFrame or m.anglePositive ~= self.metadata.anglePositive then
        return false, 'Journal frame/sign metadata changed during export'
      end
      local columns, err = copyColumns(m.baseColumns)
      if not columns then return false, err end
      if #columns ~= #self.baseColumns then return false, 'Journal base schema changed' end
      for i = 1, #columns do
        if columns[i].name ~= self.baseColumns[i].name or columns[i].unit ~= self.baseColumns[i].unit then
          return false, 'Journal base schema changed'
        end
      end
    end
    scan.header = true
    return true
  end
  if record.type == 'field' then
    local definition = record.field
    if type(definition) ~= 'table' or definition.id ~= scan.fields + 1 then return false, 'Invalid field order' end
    local field, err = safeField(definition, definition.id)
    if not field then return false, err end
    if self._phase == 'scan' then
      local reserved, reserveErr = self:_reserveField(field)
      if not reserved then return false, reserveErr end
      self.fields[#self.fields + 1] = field
    elseif not sameField(field, self.fields[field.id]) then
      return false, 'Journal field schema changed during export'
    end
    scan.fields = scan.fields + 1
    return true
  end
  if record.type == 'sample' then
    local valid, err = validateStoredSample(self, record, scan.fields)
    if not valid then return false, err end
    if self._phase == 'output' then
      local values = {}
      for i = 1, #self.baseColumns do values[#values + 1] = record.base[i] end
      for i = 1, #self.fields do
        local value = record.custom[tostring(i)]
        values[#values + 1] = value and value.value or ''
      end
      local ok, writeErr = fileCall(self._output, 'write', csvLine(values))
      if not ok then return false, 'CSV row write failed: ' .. writeErr end
      self.exportedRows = self.exportedRows + 1
    end
    scan.rows, scan.lastTime = scan.rows + 1, record.time
    return true
  end
  if record.type == 'end' then
    if not integer(record.rows) or not integer(record.fields) or record.rows ~= scan.rows
        or record.fields ~= scan.fields or record.lastTime ~= (scan.lastTime or '') then
      return false, 'Journal end marker does not match the recorded sample/schema counts'
    end
    scan.footer = true
    return true
  end
  return false, 'Unknown journal record type: ' .. tostring(record.type)
end

function Session:_finishPass()
  local scan = self._scan
  if not scan.header then return self:_fail('Journal contains no valid header') end
  if not scan.footer and not self._allowInterrupted then return self:_fail('Journal has no end marker') end
  local closed, closeErr = fileCall(self._reader, 'close')
  self._reader = nil
  if not closed then return self:_fail('Could not close journal reader: ' .. closeErr) end
  if self._phase == 'scan' then
    self.dataCount, self._lastTime = scan.rows, scan.lastTime
    self.duration = tonumber(scan.lastTime) or 0
    self._expectedRows, self._expectedFields = scan.rows, scan.fields
    self._recoveryHasFooter = scan.footer
    if self._ignoredTail then
      self.recoveryNotice = 'Recovered interrupted session: ignored the damaged or truncated final journal line '
        .. self._ignoredTail.line .. '; only the preceding checksummed complete records are exported. '
        .. 'The missing final record, original recording duration, and any unflushed tail are unknown.'
    elseif not scan.footer then
      self.recoveryNotice = 'Recovered interrupted session: only complete, durable journal samples are available; '
        .. 'the original recording duration and any unflushed tail are unknown.'
    else
      self.recoveryNotice = 'Recovered from a finalized journal; original recording timestamps are retained.'
    end
    return self:_beginOutput()
  end
  if scan.rows ~= self._expectedRows or scan.fields ~= self._expectedFields
      or self.exportedRows ~= self._expectedRows
      or (self.recovered and scan.footer ~= self._recoveryHasFooter)
      or (self._ignoredTail and not scan.ignoredTailVerified) then
    return self:_fail('CSV export counts do not match the complete journal scan')
  end
  local flushed, flushErr = fileCall(self._output, 'flush')
  local outputClosed, outputCloseErr = fileCall(self._output, 'close')
  self._output = nil
  if not flushed or not outputClosed then
    return self:_fail('Could not finalize partial CSV: ' .. (flushErr or outputCloseErr))
  end
  local moved, moveErr = ioBoolean(io.move, self.partialPath, self.filePath, false)
  if not moved then return self:_fail('Could not publish complete CSV (partial file retained): ' .. moveErr) end
  self.exporting, self.complete, self._phase = false, true, nil
  return true
end

function Session:_recoverDamagedTail(line, parseErr)
  local scan = self._scan
  if not self.recovered or not self._allowInterrupted or not scan.header or scan.footer then
    return self:_fail('Journal line ' .. scan.line .. ': ' .. parseErr)
  end
  -- Only a malformed physical final line is recoverable. Semantic validation
  -- failures in otherwise decoded records still fail in _consumeRecord().
  local ok, nextLine, readErr = pcall(function() return self._reader:read('*l') end)
  if not ok then return self:_fail('Journal tail read failed: ' .. tostring(nextLine)) end
  if readErr then return self:_fail('Journal tail read failed: ' .. tostring(readErr)) end
  if nextLine ~= nil then
    return self:_fail('Journal line ' .. scan.line .. ': ' .. parseErr .. '; damaged record is not the final line')
  end
  local tail = {line = scan.line, checksum = checksum(line), length = #line}
  if self._phase == 'scan' then
    self._ignoredTail = tail
  else
    local expected = self._ignoredTail
    if not expected or tail.line ~= expected.line or tail.checksum ~= expected.checksum
        or tail.length ~= expected.length then
      return self:_fail('Damaged journal tail changed between recovery scan and CSV export')
    end
    scan.ignoredTailVerified = true
  end
  return self:_finishPass()
end

function Session:updateExport(budgetSeconds)
  if not self.exporting then return self.error == nil, self.error end
  local budget = finite(budgetSeconds) and budgetSeconds > 0 and budgetSeconds or 0.004
  local started, processed = clock(), 0
  repeat
    local ok, line, readErr = pcall(function() return self._reader:read('*l') end)
    if not ok then return self:_fail('Journal read failed: ' .. tostring(line)) end
    if line == nil then
      if readErr then return self:_fail('Journal read failed: ' .. tostring(readErr)) end
      return self:_finishPass()
    end
    self._scan.line = self._scan.line + 1
    local record, parseErr, damaged = deserialize(line)
    if not record then
      if damaged then return self:_recoverDamagedTail(line, parseErr) end
      return self:_fail('Journal line ' .. self._scan.line .. ': ' .. parseErr)
    end
    local consumed, consumeErr = self:_consumeRecord(record)
    if not consumed then return self:_fail('Journal line ' .. self._scan.line .. ': ' .. consumeErr) end
    processed = processed + 1
  until processed >= 256 or clock() - started >= budget
  return true
end

function Session:recover(journalPath)
  if self.recording or self.exporting then return false, 'Stop the current session before recovery' end
  if type(journalPath) ~= 'string' or journalPath == '' then return false, 'Enter a journal path' end
  local closed, closeErr = self:_closeHandles()
  if not closed then return self:_fail('Could not close previous files: ' .. closeErr) end
  self.error, self.complete, self.recovered, self.recoveryNotice = nil, false, true, nil
  self.startedWall = 0
  self.dataCount, self.exportedRows, self._lastTime, self.metadata, self.duration = 0, 0, nil, nil, 0
  self._ignoredTail = nil
  self.fields, self.baseColumns, self._columnNames = {}, {}, {}
  local reader, readErr = openFile(journalPath, 'rb')
  if not reader then return self:_fail('Could not open recovery journal: ' .. readErr) end
  self.journalPath, self._reader = journalPath, reader
  local base = journalPath:gsub('%.journal%.jsonl$', '')
  if base == journalPath then base = journalPath .. '_recovered' end
  local paths, pathsErr = uniquePaths(base, false)
  if not paths then return self:_fail('Could not choose recovery output path: ' .. pathsErr) end
  self.filePath, self.partialPath = paths.filePath, paths.partialPath
  self._phase, self.exporting, self._allowInterrupted = 'scan', true, true
  self:_newScan()
  return true
end

function Session:closeOnRelease()
  if self.recording then
    local ok, err = self:finish()
    if not ok then return false, err end
  end
  -- Avoid keeping a quitting game blocked indefinitely. A retained journal can be
  -- recovered in the next run if a very large export cannot finish in two seconds.
  local started = clock()
  while self.exporting and clock() - started < 2 do
    local ok, err = self:updateExport(0.02)
    if not ok then return false, err end
  end
  if self.exporting then
    return self:_fail('App closed before CSV export completed. Recover the retained journal: ' .. self.journalPath)
  end
  if self.error then return false, self.error end
  local ok, err = self:_closeHandles()
  if not ok then return self:_fail('Could not close session files: ' .. err) end
  return true
end

function csvSession.new(options)
  options = options or {}
  local sampleRate = finite(options.sampleRate) and options.sampleRate > 0 and options.sampleRate or 50
  return setmetatable({options = options, sampleRate = sampleRate, fields = {},
    recording = false, exporting = false, complete = false, dataCount = 0, exportedRows = 0, startedWall = 0,
    duration = 0}, Session)
end

return csvSession
