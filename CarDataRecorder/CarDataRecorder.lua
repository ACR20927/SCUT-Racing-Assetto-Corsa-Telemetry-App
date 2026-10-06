local recording = false
local csvFile = nil
local dataCount = 0
local elapsed = 0
local nextSampleIndex = 1
local missedSamples = 0
local lastPhysicsTimestamp = nil
local lastFlushTime = 0
local filePath = nil
local lastError = nil

local sampleRate = 50
local sampleInterval = 1 / sampleRate
local telemetryTimeout = 0.5
local telemetry = {}
local eventNames = {'Torque', 'motor_ctrl_mode', 'real_yawrate', 'ideal_yawrate', 'Fy'}

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

-- Subscribe once per app lifetime, not once per recording. Missing values stay missing.
for i = 1, #eventNames do
  local eventName = eventNames[i]
  ac.onSharedEvent(eventName, function(data)
    local values = {}
    if eventName == 'Torque' or eventName == 'Fy' then
      if type(data) == 'table' then
        for wheel = 1, 4 do values[wheel] = finiteNumber(data[wheel]) end
      end
    else
      values[1] = finiteNumber(data)
    end
    telemetry[eventName] = {values = values, receivedAt = os.preciseClock()}
  end)
end

local function receivedValues(eventName, now)
  local entry = telemetry[eventName]
  if entry and now - entry.receivedAt <= telemetryTimeout then
    return entry.values
  end
  return {}
end

local function missingTelemetry(now)
  local missing = {}
  for i = 1, #eventNames do
    local name = eventNames[i]
    local values = receivedValues(name, now)
    local count = (name == 'Torque' or name == 'Fy') and 4 or 1
    for j = 1, count do
      if values[j] == nil then
        missing[#missing + 1] = name
        break
      end
    end
  end
  return table.concat(missing, ', ')
end

-- Header and units share one schema. Wheel ordering is LF, RF, LR, RR throughout.
local columns = {
  {'Time', 's'}, {'Speed', 'km/h'}, {'Steer', 'deg'},
  {'Throttle', '%'}, {'Brake', '%'}, {'Clutch', '%'},
  {'Pos_X', 'm'}, {'Pos_Y', 'm'}, {'Pos_Z', 'm'},
  {'Acc_X', 'g'}, {'Acc_Y', 'g'}, {'Acc_Z', 'g'},
  {'TorqueLF', 'N*m'}, {'TorqueRF', 'N*m'}, {'TorqueLR', 'N*m'}, {'TorqueRR', 'N*m'},
  {'FxLF', 'N'}, {'FxRF', 'N'}, {'FxLR', 'N'}, {'FxRR', 'N'},
  {'FyLF', 'N'}, {'FyRF', 'N'}, {'FyLR', 'N'}, {'FyRR', 'N'},
  {'LoadLF', 'N'}, {'LoadRF', 'N'}, {'LoadLR', 'N'}, {'LoadRR', 'N'},
  {'FyCalcLF', 'N'}, {'FyCalcRF', 'N'}, {'FyCalcLR', 'N'}, {'FyCalcRR', 'N'},
  {'Motor_Ctrl_mode', ''}, {'Real_Yawrate', 'rad/s'}, {'Ideal_Yawrate', 'rad/s'}
}

local function quoteCSV(value)
  return '"' .. tostring(value or ''):gsub('"', '""'):gsub('[\r\n]', ' ') .. '"'
end

local function fileOperation(file, method, ...)
  local ok, result, err = pcall(file[method], file, ...)
  if not ok then return false, tostring(result) end
  if not result then return false, tostring(err or (method .. ' failed')) end
  return true
end

local function reportError(message)
  lastError = message
  ac.log('Car Data Recorder: ERROR: ' .. message)
  ac.setMessage('Car Data Recorder', message)
end

local function closeRecording()
  local file = csvFile
  csvFile = nil
  recording = false
  if not file then return true end
  local flushed, flushError = fileOperation(file, 'flush')
  local closed, closeError = fileOperation(file, 'close')
  if not flushed or not closed then
    local err = flushError or closeError
    reportError(err)
    return false, err
  end
  ac.log(string.format('Car Data Recorder: stopped; %d rows, %d missed slots - %s',
    dataCount, missedSamples, filePath or ''))
  return true
end

local function writeText(text)
  local ok, err = fileOperation(csvFile, 'write', text)
  if not ok then
    closeRecording()
    reportError('CSV write failed: ' .. err)
  end
  return ok, err
end

local function buildHeader()
  local carName = ac.getCarName(0) or 'Unknown'
  local metadata = {
    {'Format', 'AiM CSV File'}, {'Session', 'Unknown'}, {'Vehicle', carName},
    {'Racer', os.getenv('USERNAME') or 'Unknown'}, {'Championship', ''},
    {'Comment', 'Target 50 Hz; frame-driven, actual Time is irregular; no catch-up samples. '
      .. 'Torque is motor-shaft command. Blank means unavailable. Pos is world XYZ in metres. '
      .. 'Acc XYZ is longitudinal/lateral/vertical in g.'},
    {'Date', os.date('%Y-%m-%d')}, {'Time', os.date('%H:%M:%S')},
    {'Sample Rate', sampleRate}, {'Duration', 'Unknown'},
    {'Beacon Markers', 'Unknown'}, {'Segment Times', 'Unknown'}
  }
  local lines = {}
  for i = 1, #metadata do
    lines[#lines + 1] = quoteCSV(metadata[i][1]) .. ',' .. quoteCSV(metadata[i][2])
  end
  lines[#lines + 1] = ''
  local names, units = {}, {}
  for i = 1, #columns do
    names[i], units[i] = quoteCSV(columns[i][1]), quoteCSV(columns[i][2])
  end
  lines[#lines + 1] = table.concat(names, ',')
  lines[#lines + 1] = table.concat(units, ',')
  return table.concat(lines, '\n') .. '\n\n'
end

local function startRecording()
  if recording then return true end
  local docsPath = ac.getFolder(ac.FolderID.ACDocuments)
  if not docsPath or docsPath == '' then return false, 'Could not find Assetto Corsa Documents folder' end
  if not io.dirExists(docsPath) and not io.createDir(docsPath) then
    return false, 'Could not create Documents folder: ' .. docsPath
  end
  local base = docsPath .. '\\car_data_' .. os.date('%Y%m%d_%H%M%S')
  local candidate, suffix = base .. '.csv', 0
  while io.exists(candidate) do
    suffix = suffix + 1
    candidate = base .. '_' .. suffix .. '.csv'
  end
  local file, err = io.open(candidate, 'w')
  if not file then return false, 'Could not create CSV: ' .. tostring(err) end
  csvFile, filePath = file, candidate
  dataCount, elapsed, nextSampleIndex, missedSamples = 0, 0, 1, 0
  lastPhysicsTimestamp, lastFlushTime, lastError = nil, 0, nil
  telemetry = {}
  if not writeText(buildHeader()) then return false, lastError end
  local flushed, flushError = fileOperation(csvFile, 'flush')
  if not flushed then
    closeRecording()
    return false, 'Could not flush CSV header: ' .. flushError
  end
  recording = true
  ac.log('Car Data Recorder: Recording started - ' .. filePath)
  return true
end

local function sampleCar(car, sampleTime)
  local fields = {}
  local function append(value)
    local number = finiteNumber(value)
    fields[#fields + 1] = number and string.format('%.6f', number) or ''
  end
  append(sampleTime)
  append(car.speedKmh)
  append(scale(car.steer, -1))  -- Preserve the ECU's steering sign convention.
  append(scale(car.gas, 100))
  append(scale(car.brake, 100))
  append(scale(car.clutch, 100))
  local pos = car.position
  append(pos and pos.x)
  append(pos and pos.y)
  append(pos and pos.z)
  local acc = car.acceleration
  append(acc and acc.z)  -- Longitudinal, lateral, vertical (already measured in g).
  append(acc and acc.x)
  append(acc and acc.y)
  local now = os.preciseClock()
  local torque = receivedValues('Torque', now)
  for i = 1, 4 do append(torque[i]) end
  local wheels = car.physicsAvailable and car.wheels or nil
  for _, key in ipairs({'fx', 'fy', 'load'}) do
    for i = 0, 3 do
      local wheel = wheels and wheels[i]
      append(wheel and wheel[key])
    end
  end
  local calcFy = receivedValues('Fy', now)
  for i = 1, 4 do append(calcFy[i]) end
  append(receivedValues('motor_ctrl_mode', now)[1])
  append(receivedValues('real_yawrate', now)[1])
  append(receivedValues('ideal_yawrate', now)[1])
  return table.concat(fields, ',') .. '\n'
end

-- Sampling is independent of UI visibility. Do not fabricate multiple rows from one frame.
function script.update(dt)
  if not recording or not csvFile then return end
  local sim = ac.getSim()
  if not sim.isLive then return end
  local simDt = finiteNumber(sim.dt)
  if not simDt or simDt <= 0 then return end
  elapsed = elapsed + simDt
  local dueIndex = math.floor(elapsed / sampleInterval + 1e-7)
  if dueIndex < nextSampleIndex then return end
  local car = ac.getCar(0)
  if not car then return end
  local timestamp = finiteNumber(car.timestamp)
  if timestamp and timestamp > 0 and timestamp == lastPhysicsTimestamp then return end
  if not writeText(sampleCar(car, elapsed)) then return end
  missedSamples = missedSamples + dueIndex - nextSampleIndex
  nextSampleIndex = dueIndex + 1
  lastPhysicsTimestamp = timestamp
  dataCount = dataCount + 1
  -- Buffer rows, with a periodic flush and a final flush when stopped or unloaded.
  if elapsed - lastFlushTime >= 1 then
    local ok, err = fileOperation(csvFile, 'flush')
    if not ok then
      closeRecording()
      reportError('CSV flush failed: ' .. err)
      return
    end
    lastFlushTime = elapsed
  end
end

function script.windowMain(dt)
  ui.header('Car Data Recorder')
  ui.offsetCursorY(4)
  ui.tabBar('cdr_tabs', ui.TabBarFlags.IntegratedTabs, function()
    ui.tabItem('Recorder', function()
      ui.pushFont(ui.Font.Main)
      ui.text(recording and 'Status: RECORDING' or 'Status: Ready')
      ui.text('Records: ' .. tostring(dataCount))
      ui.text(string.format('Target: %d Hz | Average: %.2f Hz', sampleRate,
        elapsed > 0 and dataCount / elapsed or 0))
      ui.text('Missed sample slots: ' .. tostring(missedSamples))
      ui.text('File: ' .. (filePath and filePath:match('[^\\/]*$') or ''))
      if lastError then ui.textWrapped('Error: ' .. lastError) end
      if recording then
        local missing = missingTelemetry(os.preciseClock())
        if missing ~= '' then ui.textWrapped('Unavailable (CSV blank): ' .. missing) end
        ui.textWrapped('Recording continues when this window is closed. Stop here to finish the file.')
        if ui.button('Stop Recording', vec2(-0.1, 0)) then closeRecording() end
      elseif ui.button('Start Recording', vec2(-0.1, 0)) then
        local ok, err = startRecording()
        if not ok then reportError('Failed to start: ' .. tostring(err)) end
      end
      ui.popFont()
    end)
    ui.tabItem('About', function()
      ui.textWrapped('Records player car telemetry to Documents/Assetto Corsa. '
        .. 'Target is 50 Hz, limited by rendered frames; actual sample times are in Time. '
        .. 'Paused simulation and replays are not recorded. Missing or stale custom data is blank. '
        .. 'Torque is the motor-shaft command, not actual wheel torque. '
        .. 'Position is world XYZ, not GPS. Acc XYZ is longitudinal/lateral/vertical in g. '
        .. 'FyCalc is optional: columns stay blank when the ECU does not provide those estimates.')
    end)
  end)
end

ac.onRelease(function() closeRecording() end)
