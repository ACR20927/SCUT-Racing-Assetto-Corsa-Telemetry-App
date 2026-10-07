-- Discover literal shared-event names without loading or running any car code.
-- CSP has no documented wildcard subscription, so runtime-generated names cannot
-- be inferred here. Payload fields are handled separately by the recorder.
local module = {}
local FALLBACK_EVENTS = {'VehicleTelemetry', 'Torque', 'motor_ctrl_mode', 'real_yawrate', 'ideal_yawrate', 'Fy'}
local SCAN_INTERVAL = 1
local FILES_PER_UPDATE = 4
local MAX_DIRECTORY_DEPTH = 16
local MAX_SOURCE_BYTES = 4 * 1024 * 1024
local MAX_EVENT_NAME_BYTES = 4096

local escapes = {a='\a', b='\b', f='\f', n='\n', r='\r', t='\t', v='\v'}

local function longBracket(source, position)
  if source:sub(position, position) ~= '[' then return nil end
  local following = position + 1
  while source:sub(following, following) == '=' do following = following + 1 end
  if source:sub(following, following) ~= '[' then return nil end
  return following + 1, ']' .. source:sub(position + 1, following - 1) .. ']'
end

local function tokensFrom(source)
  local tokens, position, size = {}, 1, #source
  local function add(kind, value)
    tokens[#tokens + 1] = {kind=kind, value=value}
  end
  while position <= size do
    local character = source:sub(position, position)
    if character:match('%s') then
      position = position + 1
    elseif source:sub(position, position + 1) == '--' then
      local contentStart, closing = longBracket(source, position + 2)
      if contentStart then
        local closingStart = source:find(closing, contentStart, true)
        if not closingStart then return nil, 'Unterminated long comment' end
        position = closingStart + #closing
      else
        position = source:find('[\r\n]', position + 2) or (size + 1)
      end
    elseif character == '"' or character == "'" then
      local quote, pieces, ended = character, {}, false
      position = position + 1
      while position <= size do
        character = source:sub(position, position)
        if character == quote then
          position, ended = position + 1, true
          break
        elseif character == '\n' or character == '\r' then
          return nil, 'Unescaped newline in a quoted string'
        elseif character == '\\' then
          position = position + 1
          character = source:sub(position, position)
          if character == '' then return nil, 'Unterminated string escape' end
          if character:match('%d') then
            local digits = source:sub(position, position + 2):match('^%d%d?%d?')
            local value = tonumber(digits)
            if value > 255 then return nil, 'Out-of-range decimal string escape' end
            pieces[#pieces + 1] = string.char(value)
            position = position + #digits
          elseif character == 'x' then
            local hexadecimal = source:sub(position + 1, position + 2)
            if not hexadecimal:match('^%x%x$') then return nil, 'Invalid hexadecimal string escape' end
            pieces[#pieces + 1] = string.char(tonumber(hexadecimal, 16))
            position = position + 3
          elseif character == 'z' then
            position = position + 1
            while source:sub(position, position):match('%s') do position = position + 1 end
          elseif character == '\n' or character == '\r' then
            pieces[#pieces + 1] = '\n'
            position = position + ((character == '\r' and source:sub(position + 1, position + 1) == '\n') and 2 or 1)
          else
            pieces[#pieces + 1] = escapes[character] or character
            position = position + 1
          end
        else
          pieces[#pieces + 1] = character
          position = position + 1
        end
      end
      if not ended then return nil, 'Unterminated quoted string' end
      add('string', table.concat(pieces))
    elseif character == '[' then
      local contentStart, closing = longBracket(source, position)
      if contentStart then
        local closingStart = source:find(closing, contentStart, true)
        if not closingStart then return nil, 'Unterminated long string' end
        local value = source:sub(contentStart, closingStart - 1):gsub('\r\n', '\n'):gsub('\r', '\n')
        if value:sub(1, 1) == '\n' then value = value:sub(2) end
        add('string', value)
        position = closingStart + #closing
      else
        add('symbol', character)
        position = position + 1
      end
    elseif character:match('[%a_]') then
      local _, ending = source:find('[%a_][%w_]*', position)
      local value = source:sub(position, ending)
      add('identifier', value)
      position = ending + 1
    elseif source:sub(position, position + 1) == '..' then
      add('symbol', '..')
      position = position + 2
    else
      add('symbol', character)
      position = position + 1
    end
  end
  return tokens
end

local function staticString(tokens, position, depth)
  if depth > 32 then return nil end
  local function factor(at)
    local token = tokens[at]
    if not token then return nil end
    if token.kind == 'string' then return token.value, at + 1 end
    if token.kind == 'symbol' and token.value == '(' then
      local value, following = staticString(tokens, at + 1, depth + 1)
      if value ~= nil and tokens[following] and tokens[following].value == ')' then
        return value, following + 1
      end
    end
    return nil
  end
  local value, following = factor(position)
  if value == nil then return nil end
  while tokens[following] and tokens[following].value == '..' do
    local right, afterRight = factor(following + 1)
    if right == nil then return nil end
    value, following = value .. right, afterRight
    if #value > MAX_EVENT_NAME_BYTES then return nil end
  end
  return value, following
end

local function findEvents(source)
  local tokens, errorMessage = tokensFrom(source)
  if not tokens then return nil, errorMessage end
  local events, unresolved = {}, 0
  for index = 1, #tokens - 3 do
    local a, b, c, d = tokens[index], tokens[index + 1], tokens[index + 2], tokens[index + 3]
    if a.kind == 'identifier' and a.value == 'ac'
        and b.kind == 'symbol' and b.value == '.'
        and c.kind == 'identifier' and c.value == 'broadcastSharedEvent'
        and d.kind == 'symbol' and d.value == '(' then
      local value, following = staticString(tokens, index + 4, 0)
      local ending = following and tokens[following]
      if value ~= nil and #value <= MAX_EVENT_NAME_BYTES and not value:find('\0', 1, true)
          and ending and ending.kind == 'symbol' and (ending.value == ',' or ending.value == ')') then
        events[value] = true
      else
        unresolved = unresolved + 1
      end
    end
  end
  return {events=events, unresolved=unresolved}
end

local Discovery = {}
Discovery.__index = Discovery

function Discovery:subscribe(name)
  if self.subscriptions[name] ~= nil or self.disposed then return end
  local success, disposable = pcall(ac.onSharedEvent, name, function(data, senderName, senderType, senderID)
    if self.disposed then return end
    local callbackOK, callbackError = pcall(self.onEvent, name, data, senderName, senderType, senderID)
    if not callbackOK then self.callbackError = tostring(callbackError) end
  end, false)
  if success then
    self.subscriptions[name] = disposable or true
    self.eventCount = self.eventCount + 1
  else
    self:addError('Cannot subscribe to ' .. name .. ': ' .. tostring(disposable))
  end
end

function Discovery:addError(message)
  if self.errorSet[message] then return end
  self.errorSet[message] = true
  self.errorCount = self.errorCount + 1
  if #self.errors < 4 then self.errors[#self.errors + 1] = message end
end

function Discovery:clearSubscriptions()
  for _, disposable in pairs(self.subscriptions) do
    if type(disposable) == 'function' then pcall(disposable) end
  end
  self.subscriptions, self.eventCount = {}, 0
end

function Discovery:beginScan(now)
  self.errors, self.errorSet, self.errorCount = {}, {}, 0
  self.files, self.fileIndex, self.fileCount, self.unresolvedCount = nil, 1, 0, 0
  local carOK, carID = pcall(ac.getCarID, 0)
  if not carOK or type(carID) ~= 'string' or carID == '' then
    self:addError('Current car ID is unavailable')
    self.nextScan = now + SCAN_INTERVAL
    return
  end
  if carID ~= self.carID then
    self:clearSubscriptions()
    self.carID, self.cache, self.callbackError = carID, {}, nil
    for _, name in ipairs(FALLBACK_EVENTS) do self:subscribe(name) end
  end
  local rootOK, carsRoot = pcall(ac.getFolder, ac.FolderID.ContentCars)
  if not rootOK or type(carsRoot) ~= 'string' or carsRoot == '' then
    self:addError('Car content folder is unavailable')
    self.nextScan = now + SCAN_INTERVAL
    return
  end
  self.dataDirectory = carsRoot .. '/' .. carID .. '/data'
  local files, known = {}, {}
  local function addFile(relativeName)
    if type(relativeName) ~= 'string' then return end
    relativeName = relativeName:gsub('\\', '/')
    if not relativeName:lower():match('%.lua$') or relativeName:sub(1, 1) == '/'
        or relativeName:find(':', 1, true) or relativeName:find('\0', 1, true)
        or ('/' .. relativeName .. '/'):find('/%.%./') then return end
    local key = relativeName:lower()
    if not known[key] then
      known[key] = true
      files[#files + 1] = relativeName
    end
  end
  if type(ac.getCarDataFiles) == 'function' then
    local listOK, list = pcall(ac.getCarDataFiles, 0)
    if listOK and type(list) == 'table' then
      for _, name in ipairs(list) do addFile(name) end
    elseif not listOK then
      self:addError('Cannot enumerate packed car data: ' .. tostring(list))
    end
  end
  local function scanDirectory(directory, prefix, depth)
    if depth > MAX_DIRECTORY_DEPTH then
      self:addError('Lua source directory exceeds discovery depth limit')
      return
    end
    local scanned, scanError = pcall(io.scanDir, directory, '*', function(name, attributes)
      if attributes.isDirectory then
        if not attributes.isReparsePoint then
          scanDirectory(directory .. '/' .. name, prefix .. name .. '/', depth + 1)
        end
      else
        addFile(prefix .. name)
      end
    end)
    if not scanned then self:addError('Cannot scan car data: ' .. tostring(scanError)) end
  end
  if type(io.scanDir) == 'function' then
    local existsOK, exists = pcall(io.dirExists, self.dataDirectory)
    if existsOK and exists then scanDirectory(self.dataDirectory, '', 0) end
  end
  table.sort(files)
  self.files, self.fileIndex, self.fileCount = files, 1, #files
  self.unresolvedCount = 0
  self.nextScan = now + SCAN_INTERVAL
  -- Forget deleted source contents, while keeping their existing subscriptions:
  -- only actual received events, not source text, determine what gets recorded.
  for relativeName in pairs(self.cache) do
    if not known[relativeName:lower()] then self.cache[relativeName] = nil end
  end
end

function Discovery:readFile(relativeName)
  local path = self.dataDirectory .. '/' .. relativeName
  local loaded, source = pcall(io.load, path)
  if not loaded or type(source) ~= 'string' then
    loaded, source = pcall(ac.readDataFile, path)
  end
  if not loaded or type(source) ~= 'string' then
    self:addError('Cannot read Lua source: ' .. relativeName)
    return
  end
  if #source > MAX_SOURCE_BYTES then
    self:addError('Lua source exceeds discovery size limit: ' .. relativeName)
    return
  end
  local cached = self.cache[relativeName]
  if not cached or cached.source ~= source then
    local parsed, parseError = findEvents(source)
    if not parsed then
      self:addError(relativeName .. ': ' .. tostring(parseError))
      return
    end
    cached = {source=source, result=parsed}
    self.cache[relativeName] = cached
  end
  self.unresolvedCount = self.unresolvedCount + cached.result.unresolved
  for name in pairs(cached.result.events) do self:subscribe(name) end
end

function Discovery:update(now, force)
  if self.disposed then return end
  now = tonumber(now) or 0
  if now ~= now or now == math.huge or now == -math.huge then return end
  if force or (not self.files and now >= self.nextScan) then self:beginScan(now) end
  if not self.files then return end
  for _ = 1, FILES_PER_UPDATE do
    local relativeName = self.files[self.fileIndex]
    if not relativeName then self.files = nil; return end
    self.fileIndex = self.fileIndex + 1
    local readOK, readError = pcall(self.readFile, self, relativeName)
    if not readOK then self:addError(relativeName .. ': ' .. tostring(readError)) end
  end
  if self.fileIndex > #self.files then self.files = nil end
end

function Discovery:status()
  local message = #self.errors > 0 and table.concat(self.errors, '; ') or nil
  if self.errorCount > #self.errors then
    message = (message or '') .. '; +' .. (self.errorCount - #self.errors) .. ' discovery errors'
  end
  if self.callbackError then message = (message and message .. '; ' or '') .. self.callbackError end
  return {events=self.eventCount, files=self.fileCount, unresolved=self.unresolvedCount, error=message}
end

function Discovery:dispose()
  if self.disposed then return end
  self.disposed = true
  self:clearSubscriptions()
  self.files, self.cache = nil, {}
end

function module.new(onEvent)
  assert(type(onEvent) == 'function', 'Event discovery requires an event callback')
  local instance = setmetatable({onEvent=onEvent, subscriptions={}, eventCount=0,
    fileCount=0, unresolvedCount=0, cache={}, nextScan=0, errors={}, errorSet={}, errorCount=0}, Discovery)
  for _, name in ipairs(FALLBACK_EVENTS) do instance:subscribe(name) end
  return instance
end

return module
