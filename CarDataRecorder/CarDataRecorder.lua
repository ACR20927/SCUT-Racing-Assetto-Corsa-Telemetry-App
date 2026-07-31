
local recording = false
local csvFile = nil
local dataCount = 0
local start_time = 0
local next_sample_time = 0
local filePath = nil

local sample_rate=50
local sample_interval = 1/sample_rate
local torqueLF, torqueRF, torqueLR, torqueRR = 0, 0, 0, 0
local motor_ctrl_mode=nil
local real_yawrate, ideal_yawrate = 0, 0

local function getDocumentsPath()
  local userProfile = os.getenv('USERPROFILE')
  if userProfile then
    local path = userProfile .. '\\Documents\\Assetto Corsa'
    os.execute('mkdir "' .. path .. '" 2>nul')
    return path
  end
  return nil
end

local function getTimestamp()
  return os.date('%Y%m%d_%H%M%S')
end

local function getDateTime()
  return os.date('%Y-%m-%d %H:%M:%S')
end

local function getCurrentTime()
  return os.time()
end

local function startRecording()
  ac.onSharedEvent('Torque', function(data, senderName, senderType, senderID)
    torqueLF, torqueRF, torqueLR, torqueRR = data[1], data[2], data[3], data[4]
    end)
  ac.onSharedEvent('motor_ctrl_mode', function(data, senderName, senderType, senderID)
    motor_ctrl_mode = data
    end)
  ac.onSharedEvent('real_yawrate', function(data, senderName, senderType, senderID)
    real_yawrate = data
    end)
  ac.onSharedEvent('ideal_yawrate', function(data, senderName, senderType, senderID)
    ideal_yawrate = data or "Unknown"
    end)
  local docsPath = getDocumentsPath()
  if not docsPath then
    ac.log('ERROR: Could not find Documents path')
    return false, 'No Documents path'
  end
  local timestamp = getTimestamp()
  filePath = docsPath .. '\\car_data_' .. timestamp .. '.csv'
  csvFile = io.open(filePath, 'w')
  if not csvFile then
    ac.log('ERROR: Could not create CSV file: ' .. filePath)
    return false, 'File creation failed'
  end
  csvFile:write('"Format","AiM CSV File"\n')
  csvFile:write('"Session","Unknown"\n')
  local carName = ac.getCarName(0) or 'Unknown' 
  csvFile:write('"Vehicle","' .. carName .. '"\n')
  local driverName = os.getenv('USERNAME') or 'Unknown'
  csvFile:write('"Racer","' .. driverName .. '"\n')
  csvFile:write('"Championship",""\n')
  csvFile:write('"Comment",""\n')
    local dateTime = getDateTime()
    csvFile:write('"Date","' .. dateTime .. '"\n')
  local timeStr = os.date('%H:%M:%S')
  csvFile:write('"Time","' .. timeStr .. '"\n')
  csvFile:write('"Sample Rate","' .. sample_rate .. '"\n')
  csvFile:write('"Duration","Unknown"\n')
  csvFile:write('"Session","Unknown"\n')
  csvFile:write('"Beacon Markers","Unknown"\n')
  csvFile:write('"Segment Times","Unknown"\n')
  csvFile:write('\n')

  --下面放要传输的数据标题

  csvFile:write('"Time",')
  csvFile:write('"Speed",')
  csvFile:write('"Steer",')
  csvFile:write('"Throttle",')
  csvFile:write('"Brake",')
  csvFile:write('"Clutch",')
  csvFile:write('"GPS Latitude",')
  csvFile:write('"GPS Longitude",')
  csvFile:write('"Pos_Z",')
  csvFile:write('"Acc_X",')
  csvFile:write('"Acc_Y",')
  csvFile:write('"Acc_Z",')
  csvFile:write('"TorqueLF",')
  csvFile:write('"TorqueRR",')
  csvFile:write('"TorqueLR",')
  csvFile:write('"TorqueRF",')
  csvFile:write('"Motor_Ctrl_mode",')
  csvFile:write('"Real_Yawrate",')
  csvFile:write('"Ideal_Yawrate"')

  --上面放要传输的数据标题
  csvFile:write('\n')
  --下面放要传输的数据单位
  
  csvFile:write('"s","km/h","deg","%","%","%",')
  csvFile:write('"m","m","m","g","g","g","N/m","N/m","N/m","N/m"," ","rad","rad"\n\n')

  --上面放要传输的数据单位

  csvFile:flush()
  recording = true
  dataCount = 0
  start_time = os.clock()
  next_sample_time = start_time + sample_interval
  ac.log('Car Data Recorder: Recording started - ' .. filePath)
  return true
end


local function stopRecording()
  if csvFile then
    csvFile:close()
    recording = false
    ac.log('Car Data Recorder: Recording stopped')
  end
end


local function onStartButtonClicked()
  if not recording then
    local ok, err = startRecording()
    if not ok then
      ac.setMessage('Car Data Recorder', 'Failed to start: ' .. (err or 'Unknown error'))
    end
  end
end

local function onStopButtonClicked()
  if recording then
    stopRecording()
  end
end

function script.windowMain(dt)
  ui.header('Car Data Recorder')
  ui.offsetCursorY(4)
  ui.tabBar('cdr_tabs', ui.TabBarFlags.IntegratedTabs, function()
    ui.tabItem('Recorder', function()
      ui.pushFont(ui.Font.Main)
      if recording then
        ui.text('Status: RECORDING')
        ui.text('Records: ' .. tostring(dataCount))
        ui.text('File: ' .. (filePath and filePath:match('[^\\/]*$') or ''))
        if ui.button('Stop Recording', vec2(-0.1, 0)) then
          stopRecording()
        end
      else
        ui.text('Status: Ready')
        ui.text('Records: ' .. tostring(dataCount))
        ui.text('File: ' .. (filePath and filePath:match('[^\\/]*$') or ''))
        if ui.button('Start Recording', vec2(-0.1, 0)) then
          onStartButtonClicked()
        end
      end
      ui.popFont()
    end)
    ui.tabItem('About', function()
      ui.textWrapped('This app records car telemetry data (speed, throttle, brake, GPS, acceleration) to a CSV file in your Documents/Assetto Corsa folder.\n\nInspired by CarMirrorsConfigurator app UI structure.')
    end)
  end)
    

  if recording and csvFile then
    local now = os.clock()
    if now >= next_sample_time then
      next_sample_time = next_sample_time + sample_interval
      local car = ac.getCar(0)
      if car then

        --下面放要传输的数据
        local current_time = now - start_time
        csvFile:write(string.format('%.3f,', current_time))
        local vehspd = car.speedKmh or 0
        csvFile:write(string.format('%.3f,', vehspd))
        local steer = -car.steer or 0
        csvFile:write(string.format('%.3f,', steer))
        local throttle = car.gas*100 or 0
        csvFile:write(string.format('%.3f,', throttle))
        local brake = car.brake*100 or 0
        csvFile:write(string.format('%.3f,', brake))
        local clutch = car.clutch*100 or 0
        csvFile:write(string.format('%.3f,', clutch))
        local pos = car.position or vec3(0, 0, 0)
        local lat = pos.x
        local lon = pos.z
        local posZ = pos.y
        csvFile:write(string.format('%.3f,%.3f,%.3f,', lat, lon, posZ))
        local acc = car.acceleration or vec3(0, 0, 0)
        local accY = acc.x
        local accZ = acc.y
        local accX = acc.z
        csvFile:write(string.format('%.3f,%.3f,%.3f,', accX, accY, accZ))
        csvFile:write(string.format('%.3f,%.3f,%.3f,%.3f,', torqueLF, torqueRF, torqueLR, torqueRR))
        csvFile:write(string.format('%s,', motor_ctrl_mode))
        csvFile:write(string.format('%.3f,%.3f,', real_yawrate, ideal_yawrate))

        --上面放要传输的数据
        csvFile:write('\n')
        csvFile:flush()
        dataCount = dataCount + 1
      end
    end
  end
end