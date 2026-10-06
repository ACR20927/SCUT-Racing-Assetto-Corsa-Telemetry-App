local EventDiscovery = require('event_discovery')
local TelemetryFields = require('telemetry_fields')
local CsvSession = require('csv_session')

local session = nil
local pending = {}
local fieldIDs = {}
local elapsed = 0
local nextSampleIndex = 1
local missedSamples = 0
local lastPhysicsTimestamp = nil
local lastError = nil
local reportedError = nil
local recoveryPath = ''
local sampleRate = 50
local sampleInterval = 1 / sampleRate

-- Native data remains available even for cars without a telemetry sender.
local baseColumns = {
  {'Time', 's'}, {'Speed', 'km/h'}, {'Steer', 'deg'},
  {'Throttle', '%'}, {'Brake', '%'}, {'Clutch', '%'},
  {'Pos_X', 'm'}, {'Pos_Y', 'm'}, {'Pos_Z', 'm'},
  {'Acc_X', 'g'}, {'Acc_Y', 'g'}, {'Acc_Z', 'g'},
  {'FxLF', 'N'}, {'FxRF', 'N'}, {'FxLR', 'N'}, {'FxRR', 'N'},
  {'FyLF', 'N'}, {'FyRF', 'N'}, {'FyLR', 'N'}, {'FyRR', 'N'},
  {'LoadLF', 'N'}, {'LoadRF', 'N'}, {'LoadLR', 'N'}, {'LoadRR', 'N'}
}

local function finiteNumber(value)
  if type(value) ~= 'number' or value ~= value or value == math.huge or value == -math.huge then
    return nil
  end
  return value
end

local function scale(value, multiplier)
  local number = finiteNumber(value)
  return number and number * multiplier or nil
end

local function numberText(value)
  local number = finiteNumber(value)
  return number and string.format('%.17g', number) or ''
end

local function valueText(field)
  if field.kind == 'number' then return numberText(field.value) end
  if field.value == nil then return '' end
  if field.kind == 'boolean' then return field.value and 'true' or 'false' end
  return tostring(field.value)
end

local function reportError(message)
  lastError = tostring(message or 'Unknown error')
  if reportedError ~= lastError then
    reportedError = lastError
    ac.log('Car Data Recorder: ERROR: ' .. lastError)
    ac.setMessage('Car Data Recorder', lastError)
  end
end

local function sessionOptions()
  return {baseColumns = baseColumns, sampleRate = sampleRate,
    carName = ac.getCarName(0) or 'Unknown', driverName = os.getenv('USERNAME') or 'Unknown'}
end

-- Units are optional. New fields are recorded without inventing their physical units.
local function knownUnit(eventName, path)
  if eventName == 'Torque' and path:match('^%[%d+%]$') then return 'N*m' end
  if eventName == 'Fy' and path:match('^%[%d+%]$') then return 'N' end
  if path == '' and (eventName == 'real_yawrate' or eventName == 'ideal_yawrate') then return 'rad/s' end
  return ''
end

local function receiveEvent(eventName, data, senderName, senderType, senderID)
  if not session or not session.recording or not ac.getSim().isLive then return end
  -- Keep different senders separate, without guessing undocumented sender ID meanings.
  local source = {name = tostring(senderName or ''), type = tostring(senderType or ''),
    id = tostring(senderID or '')}
  local identity = JSON.stringify({eventName, source.type, source.id, source.name})
  local previous = pending[identity]
  local packet = {values = {}, received = os.preciseClock() - session.startedWall,
    counts = previous and previous.counts or {}}
  local fields = TelemetryFields.flatten(data)
  for i = 1, #fields do
    local field = fields[i]
    local fieldKey = JSON.stringify({identity, field.path})
    local id = fieldIDs[fieldKey]
    if not id then
      local name = 'Telemetry[' .. JSON.stringify(eventName) .. ']' .. field.path
        .. ' @' .. JSON.stringify({source.type, source.id, source.name})
      local err
      id, err = session:addField({name = name, unit = knownUnit(eventName, field.path),
        event = eventName, path = field.path, source = source})
      if not id then reportError(err); return end
      fieldIDs[fieldKey] = id
    end
    local idKey = tostring(id)
    packet.counts[idKey] = (packet.counts[idKey] or 0) + 1
    packet.values[idKey] = {kind = field.kind, value = valueText(field), updates = packet.counts[idKey]}
  end
  -- Replace the WHOLE payload. A field removed from a later packet is immediately absent.
  pending[identity] = packet
end

local discovery = EventDiscovery.new(receiveEvent)

local function nativeValues(car, sampleTime)
  local values = {}
  local function append(value) values[#values + 1] = numberText(value) end
  append(sampleTime)
  append(car.speedKmh)
  append(scale(car.steer, -1))
  append(scale(car.gas, 100))
  append(scale(car.brake, 100))
  append(scale(car.clutch, 100))
  local pos = car.position
  append(pos and pos.x); append(pos and pos.y); append(pos and pos.z)
  local acc = car.acceleration
  append(acc and acc.z); append(acc and acc.x); append(acc and acc.y)
  local wheels = car.physicsAvailable and car.wheels or nil
  for _, key in ipairs({'fx', 'fy', 'load'}) do
    for i = 0, 3 do
      local wheel = wheels and wheels[i]
      append(wheel and wheel[key])
    end
  end
  return values
end

local function startRecording()
  if session and (session.recording or session.exporting) then return end
  local nextSession = CsvSession.new(sessionOptions())
  local ok, err = nextSession:start()
  if not ok then reportError(err); return end
  session = nextSession
  pending, fieldIDs = {}, {}
  elapsed, nextSampleIndex, missedSamples = 0, 1, 0
  lastPhysicsTimestamp, lastError, reportedError = nil, nil, nil
  recoveryPath = session.journalPath
  discovery:update(os.preciseClock(), true)
  ac.log('Car Data Recorder: recording journal - ' .. session.journalPath)
end

local function appendSnapshot(car)
  local custom = {}
  for _, packet in pairs(pending) do
    for id, field in pairs(packet.values) do
      custom[id] = {value = field.value, kind = field.kind,
        received = packet.received, updates = field.updates}
    end
  end
  local ok, err = session:append({time = elapsed, base = nativeValues(car, elapsed), custom = custom})
  if not ok then reportError(err); return false end
  pending = {}
  return true
end

local function stopRecording()
  if not session or not session.recording then return end
  -- Preserve arrivals in the final, shorter-than-20ms sampling interval.
  if next(pending) ~= nil and ac.getSim().isLive then
    local car = ac.getCar(0)
    if car and not appendSnapshot(car) then return end
  end
  pending = {}
  local ok, err = session:finish()
  if not ok then reportError(err) end
end

-- Shared events are delivered at the app's update cadence. Each sample keeps the latest
-- packet received since the previous sample, with a reception timestamp and update count.
-- No new packet means MISSING, never an unmarked last-known value.
function script.update(dt)
  local now = os.preciseClock()
  discovery:update(now)
  if not session then return end
  if session.exporting then
    local ok, err = session:updateExport(0.004)
    if not ok then reportError(err) end
    return
  end
  if not session.recording then return end
  local ok, err = session:flushIfDue(now)
  if not ok then reportError(err); return end
  local sim = ac.getSim()
  if not sim.isLive then pending = {}; return end
  local simDt = finiteNumber(sim.dt)
  if not simDt or simDt <= 0 then return end
  elapsed = elapsed + simDt
  local dueIndex = math.floor(elapsed / sampleInterval + 1e-7)
  if dueIndex < nextSampleIndex then return end
  local car = ac.getCar(0)
  if not car then return end
  local timestamp = finiteNumber(car.timestamp)
  if timestamp and timestamp > 0 and timestamp == lastPhysicsTimestamp then return end
  if not appendSnapshot(car) then return end
  missedSamples = missedSamples + dueIndex - nextSampleIndex
  nextSampleIndex = dueIndex + 1
  lastPhysicsTimestamp = timestamp
end

local function fileName(path)
  return path and path:match('[^\\/]*$') or ''
end

function script.windowMain(dt)
  ui.header('Car Data Recorder')
  ui.offsetCursorY(4)
  ui.tabBar('cdr_tabs', ui.TabBarFlags.IntegratedTabs, function()
    ui.tabItem('Recorder', function()
      ui.pushFont(ui.Font.Main)
      local state = session and (session.recording and 'RECORDING'
        or session.exporting and 'EXPORTING CSV' or session.error and 'ERROR'
        or session.complete and 'CSV READY' or 'Ready') or 'Ready'
      ui.text('Status: ' .. state)
      local count = session and session.dataCount or 0
      ui.text('Samples: ' .. tostring(count))
      local duration = session and session.recovered and session.duration or elapsed
      ui.text(string.format('Target: %d Hz | Average: %.2f Hz', sampleRate,
        duration and duration > 0 and count / duration or 0))
      ui.text('Missed sample slots: ' .. tostring(missedSamples))
      ui.text('Custom fields: ' .. tostring(session and #session.fields or 0))
      local detected = discovery:status()
      ui.text(string.format('Discovered: %d events / %d Lua files', detected.events, detected.files))
      if detected.unresolved > 0 then
        ui.textWrapped('Unresolved event names: ' .. detected.unresolved
          .. '. Variable-based or runtime-generated names cannot be discovered from source.')
      end
      if detected.error then ui.textWrapped('Discovery: ' .. detected.error) end
      if lastError or (session and session.error) then
        ui.textWrapped('Error: ' .. (lastError or session.error))
      end
      if session then
        ui.textWrapped('CSV (created after Stop): ' .. fileName(session.filePath))
        ui.textWrapped('Recovery journal: ' .. fileName(session.journalPath))
        if session.recoveryNotice then ui.textWrapped(session.recoveryNotice) end
      end
      if session and session.recording then
        ui.textWrapped('Close this window to hide it; recording continues. Stop to generate the complete CSV.')
        if ui.button('Stop and Export CSV', vec2(-0.1, 0)) then stopRecording() end
      elseif session and session.exporting then
        ui.text('Exported samples: ' .. tostring(session.exportedRows or 0))
        ui.textWrapped('Keep AC running until export finishes. The raw journal is retained.')
      elseif ui.button('Start Recording', vec2(-0.1, 0)) then
        startRecording()
      end
      ui.popFont()
    end)
    ui.tabItem('About', function()
      ui.textWrapped('Records native vehicle data and dynamically discovered shared events. '
        .. 'Literal event names in the current car data Lua files are discovered automatically. '
        .. 'Within known events, any number of nested fields can appear or disappear. '
        .. 'Dynamic runtime-generated event names and aliases need an explicit discoverable broadcast. '
        .. 'No ECU or controller files are changed.\n\n'
        .. 'Stop produces one CSV with the union of all recorded fields. '
        .. 'Each custom field has value, type, reception wall time and update count columns. '
        .. 'A sample without a new packet is marked missing; values are not carried forward. '
        .. 'Numbers, booleans, strings, tables and CSP vectors are supported. '
        .. 'Invalid values and unsupported structures have explicit type/status markers.\n\n'
        .. '50 Hz is a frame-limited target. Actual simulation sample times are in Time. '
        .. 'Multiple updates within one sample are reduced to the latest packet; '
        .. 'the per-field update count describes how many arrivals contained that field. Reception time is not ECU generation time. '
        .. 'Paused simulation and replays are excluded. New event discovery may take one scan cycle. '
        .. 'Position is world XYZ; Acc XYZ is longitudinal/lateral/vertical in g. '
        .. 'Torque is a motor-shaft command. Unknown custom units are left unspecified.')
    end)
    ui.tabItem('Recovery', function()
      ui.textWrapped('If AC exits before CSV export completes, recover the retained .jsonl journal here. '
        .. 'Use the Windows path within the Steam/Proton prefix, or browse the recording folder yourself.')
      recoveryPath = ui.inputText('Journal path', recoveryPath)
      if not session or (not session.recording and not session.exporting) then
        if ui.button('Recover Journal to CSV', vec2(-0.1, 0)) then
          local recoveredSession = CsvSession.new(sessionOptions())
          local ok, err = recoveredSession:recover(recoveryPath)
          if ok then
            session = recoveredSession
            pending, fieldIDs = {}, {}
            lastError, reportedError = nil, nil
          else reportError(err) end
        end
      end
    end)
  end)
end

ac.onRelease(function()
  stopRecording()
  discovery:dispose()
  if session then
    local ok, err = session:closeOnRelease()
    if not ok then ac.log('Car Data Recorder: release: ' .. tostring(err)) end
  end
end)
