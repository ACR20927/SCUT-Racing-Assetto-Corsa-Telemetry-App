-- Offline integration coverage for the real recorder entry point and CSV journal.
-- Run with Nix's LuaJIT + lua51Packages.dkjson; AC/Steam is never launched.
-- Every write is confined to outputRoot. The sender source is read, never executed.
local json = require('dkjson')
local ffi = require('ffi')
ffi.cdef[[int mkdir(const char *path, unsigned int mode); int access(const char *path, int mode);]]

local pluginRoot = arg[1] or '/home/baizhu945/Documents/ACCarModel/SCUT-Racing-Assetto-Corsa-Telemetry-App/CarDataRecorder'
local outputRoot = arg[2] or '/home/baizhu945/Documents/Codex/2026-10-05/wo-d/work/ac-repair/telemetry-clean-tests'
local senderRoot = arg[3] or '/home/baizhu945/Documents/ACCarModel/script'
local stdOpen = io.open
local checks, cases = 0, {}
local wall, docs, callbacks, uiButton, uiRecoveryPath, currentSession = 100, nil, {}, nil, nil, nil
local logs, messages, uiText, releases, sourceReads = {}, {}, {}, {}, {}
local sim = {isLive = true, dt = 0.02}
local car = {timestamp = 0, speedKmh = 27.25, steer = -8, gas = 0, brake = 0.5, clutch = 0.3,
  position = {x = 1, y = -2, z = 3}, acceleration = {x = 0.2, y = 0.3, z = 0.4}}
local virtualCarRoot = outputRoot .. '/read-only-car-content'
local virtualData = virtualCarRoot .. '/FormaxEF26/data/'
local discoveryFixture = outputRoot .. '/sender-discovery-fixture.lua'
local directories = {[outputRoot] = true, [virtualData:sub(1, -2)] = true}

local function normalize(path) return path:gsub('\\', '/') end
local function check(value, message)
  checks = checks + 1
  if not value then error('FAIL: ' .. (message or 'assertion'), 2) end
end
local function equal(actual, expected, message)
  check(actual == expected, (message or 'value') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end
local function near(actual, expected, message)
  check(type(actual) == 'number' and math.abs(actual - expected) < 1e-10,
    (message or 'number') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end
local function readNative(path)
  local file = assert(stdOpen(normalize(path), 'rb'))
  local data = assert(file:read('*a')); assert(file:close()); return data
end
local function writeNative(path, data)
  path = normalize(path)
  check(path:sub(1, #outputRoot + 1) == outputRoot .. '/', 'test output write is confined')
  local file = assert(stdOpen(path, 'wb')); assert(file:write(data)); assert(file:close())
end
local function directory(path)
  path = normalize(path):gsub('/+$', '')
  check(path == outputRoot or path:sub(1, #outputRoot + 1) == outputRoot .. '/', 'directory write is confined')
  if ffi.C.mkdir(path, 493) ~= 0 then equal(ffi.errno(), 17, 'mkdir or already present') end
  directories[path] = true
  return true
end
local function actualReadPath(path)
  path = normalize(path)
  if path == virtualData .. 'telemetry.lua' then sourceReads.telemetry = true; return senderRoot .. '/telemetry.lua' end
  if path == virtualData .. 'sender-discovery-fixture.lua' then sourceReads.fixture = true; return discoveryFixture end
  return path
end

JSON = {
  stringify = function(value) return assert(json.encode(value)) end,
  parse = function(value)
    local decoded, _, err = json.decode(value)
    if err then error(err) end
    return decoded
  end
}
io.open = function(path, mode)
  local normalized = normalize(path)
  if mode and mode:find('[wa+]') then
    check(normalized:sub(1, #outputRoot + 1) == outputRoot .. '/', 'production I/O write is confined')
  end
  return stdOpen(actualReadPath(path), mode)
end
io.exists = function(path) return ffi.C.access(normalize(path), 0) == 0 end
io.dirExists = function(path) return directories[normalize(path):gsub('/+$', '')] == true end
io.createDir = directory
io.load = function(path)
  local file = stdOpen(actualReadPath(path), 'rb')
  if not file then return nil end
  local data = file:read('*a'); assert(file:close()); return data
end
io.scanDir = function(path, pattern, callback)
  equal(normalize(path), virtualData:sub(1, -2), 'discovery scans only the current virtual car')
  equal(pattern, '*', 'discovery enumeration pattern')
  callback('telemetry.lua', {isDirectory = false})
  callback('sender-discovery-fixture.lua', {isDirectory = false})
end
io.move = function(source, target, replace)
  source, target = normalize(source), normalize(target)
  check(source:sub(1, #outputRoot + 1) == outputRoot .. '/' and target:sub(1, #outputRoot + 1) == outputRoot .. '/',
    'publish paths are confined')
  if not replace and io.exists(target) then return false end
  return os.rename(source, target)
end
os.preciseClock = function() return wall end
vec2 = function(x, y) return {x = x, y = y} end

ac = {
  FolderID = {ACDocuments = 1, ContentCars = 2},
  getFolder = function(id) if id == 1 then return docs elseif id == 2 then return virtualCarRoot end end,
  getCarID = function() return 'FormaxEF26' end,
  getCarName = function() return 'Offline EF26' end,
  getCarDataFiles = function() return {'telemetry.lua', 'sender-discovery-fixture.lua'} end,
  readDataFile = function(path) return io.load(path) end,
  getSim = function() return sim end,
  getCar = function(index) equal(index, 0, 'recorder observes the player car'); return car end,
  log = function(text) logs[#logs + 1] = text end,
  setMessage = function(title, text) messages[#messages + 1] = {title, text} end,
  onRelease = function(callback) releases[#releases + 1] = callback end,
  onSharedEvent = function(name, callback, ownEvents)
    equal(ownEvents, false, 'shared-event subscription excludes own app events')
    callbacks[name] = callbacks[name] or {}
    callbacks[name][#callbacks[name] + 1] = callback
    return function()
      for i = #callbacks[name], 1, -1 do if callbacks[name][i] == callback then table.remove(callbacks[name], i) end end
    end
  end
}
ui = {TabBarFlags = {IntegratedTabs = 1}, Font = {Main = 1}}
for _, name in ipairs({'header', 'offsetCursorY', 'pushFont', 'popFont'}) do ui[name] = function() end end
ui.text = function(text) uiText[#uiText + 1] = text end
ui.textWrapped = ui.text
ui.tabBar = function(_, _, callback) callback() end
ui.tabItem = function(_, callback) callback() end
ui.inputText = function(_, value) return uiRecoveryPath or value end
ui.button = function(name)
  if uiButton == name then uiButton = nil; return true end
  return false
end

writeNative(discoveryFixture, "error('discovery must not execute sender code')\nac.broadcastSharedEvent('DiscoveredOnly', false)\n")
local productionBefore = {}
for _, file in ipairs({'CarDataRecorder.lua', 'event_discovery.lua', 'telemetry_fields.lua',
    'csv_session.lua', 'telemetry_channels.lua', 'telemetry_names.lua', 'manifest.ini'}) do
  productionBefore[file] = readNative(pluginRoot .. '/' .. file)
end
package.path = pluginRoot .. '/?.lua;' .. package.path
local CsvSession = require('csv_session')
package.loaded.csv_session = {new = function(options)
  currentSession = CsvSession.new(options); return currentSession
end}
local Channels = require('telemetry_channels')
script = {}
assert(loadfile(pluginRoot .. '/CarDataRecorder.lua'))()

local function click(label, recoveryPath)
  uiButton, uiRecoveryPath, uiText = label, recoveryPath, {}
  script.windowMain(0)
  equal(uiButton, nil, 'real UI button was available: ' .. label)
  uiRecoveryPath = nil
end
local function emit(data, sender, event)
  event, sender = event or 'VehicleTelemetry', sender or '4'
  check(callbacks[event] and #callbacks[event] == 1, 'one real discovered subscription for ' .. event)
  callbacks[event][1](data, 'Car physics script: ' .. sender, 'car_cphys', sender)
end
local function tick(dt, data, sender, freshPhysics)
  wall, sim.dt = wall + dt, dt
  if freshPhysics ~= false and sim.isLive and dt > 0 then car.timestamp = car.timestamp + 1 end
  if data ~= nil then emit(data, sender) end
  script.update(dt)
end
local function start(name)
  docs = outputRoot .. '/' .. name
  directory(docs)
  sim.isLive, sim.dt = true, 0.02
  click('Start Recording')
  check(currentSession.recording and not currentSession.error, 'real recorder started')
  return currentSession
end
local function export()
  local iterations = 0
  while currentSession.exporting do
    iterations = iterations + 1
    check(iterations < 10000, 'export must make finite progress')
    wall = wall + 0.001; script.update(0)
  end
  return currentSession
end
local function stop()
  click('Stop and Export CSV')
  export()
  check(currentSession.complete and not currentSession.error, 'Stop publishes a complete CSV')
  check(io.exists(currentSession.journalPath), 'raw journal retained after successful export')
  check(not io.exists(currentSession.partialPath), 'only finished CSV is published')
  return currentSession
end

-- Independent CSV reader handles RFC-style quotes and embedded CR/LF strings.
local function parseCSV(text)
  local rows, row, parts, quoted, i = {}, {}, {}, false, 1
  local function field() row[#row + 1] = table.concat(parts); parts = {} end
  local function line() field(); rows[#rows + 1] = row; row = {} end
  while i <= #text do
    local ch = text:sub(i, i)
    if quoted then
      if ch == '"' and text:sub(i + 1, i + 1) == '"' then parts[#parts + 1] = '"'; i = i + 1
      elseif ch == '"' then quoted = false
      else parts[#parts + 1] = ch end
    elseif ch == '"' then quoted = true
    elseif ch == ',' then field()
    elseif ch == '\r' and text:sub(i + 1, i + 1) == '\n' then line(); i = i + 1
    elseif ch == '\n' then line()
    else parts[#parts + 1] = ch end
    i = i + 1
  end
  check(not quoted, 'CSV quotes are balanced')
  if #parts > 0 or #row > 0 then line() end
  local headerIndex
  for j = 1, #rows do if rows[j][1] == 'time_s' then headerIndex = j; break end end
  check(headerIndex ~= nil, 'CSV contains readable time_s header')
  local header, units, data, index = rows[headerIndex], rows[headerIndex + 1], {}, {}
  for j = 1, #header do check(not index[header[j]], 'CSV column names are unique'); index[header[j]] = j end
  equal(#units, #header, 'units align with the one-column-per-channel schema')
  for j = headerIndex + 2, #rows do
    if not (#rows[j] == 1 and rows[j][1] == '') then
      equal(#rows[j], #header, 'each sample aligns with the complete CSV schema')
      data[#data + 1] = rows[j]
    end
  end
  return {header = header, units = units, rows = data, index = index}
end
local function csv(session) return parseCSV(readNative(session.filePath)) end
local function value(tableCSV, row, name) return tableCSV.rows[row][assert(tableCSV.index[name], name)] end
local function journal(path)
  local records, lines = {}, {}
  for line in readNative(path):gmatch('[^\n]+') do
    lines[#lines + 1] = line
    local envelope = JSON.parse(line)
    records[#records + 1] = JSON.parse(envelope.payload)
  end
  return records, lines
end
local function journalSamples(records)
  local rows, fields = {}, {}
  for _, record in ipairs(records) do
    if record.type == 'sample' then rows[#rows + 1] = record
    elseif record.type == 'field' then fields[record.field.id] = record.field end
  end
  return rows, fields
end
local function fieldID(fields, name, sourceID)
  for id, field in pairs(fields) do
    if field.name == name and (sourceID == nil or field.source.id == sourceID) then return tostring(id) end
  end
  error('missing field: ' .. name)
end
local function pass(name) cases[#cases + 1] = name; print('PASS ' .. name) end

-- Baseline: unavailable CG sideslip still exists, every standard unit/name is checked.
local default = start('default54')
check(sourceReads.telemetry and sourceReads.fixture, 'real discovery read sender sources without executing them')
check(callbacks.DiscoveredOnly ~= nil, 'non-fallback literal event was discovered from Lua source')
equal(#Channels.fields, 42, 'sender contract contains 42 channels')
local packet = {}
for i, field in ipairs(Channels.fields) do if field.name ~= 'cg_sideslip_estimate_rad' then packet[field.name] = i / 8 end end
packet.FL_motor_torque_command_Nm, packet.motor_ctrl_mode, packet.yaw_rate_target_radps = 0, 0, 0
tick(0.02, packet); tick(0.02)
sim.isLive = false; tick(1, packet)
equal(default.dataCount, 2, 'paused simulation does not record events or rows')
sim.isLive = true; tick(0.02, packet); tick(0.12, packet)
default = stop()
local baseline = csv(default)
equal(#baseline.header, 54, 'default file has exactly 54 value columns')
equal(#baseline.rows, 4, 'no fabricated low-frame-rate catch-up rows')
near(default.duration, 0.18, 'recording duration excludes pause')
near(tonumber(value(baseline, 4, 'time_s')), 0.18, 'large-dt row uses its true time')
local expected = {
  {'time_s','s'}, {'speed_kmh','km/h'}, {'steering_angle_deg','deg'}, {'throttle_pct','%'},
  {'brake_pct','%'}, {'clutch_pct','%'}, {'position_world_x_m','m'}, {'position_world_y_m','m'},
  {'position_world_z_m','m'}, {'acceleration_longitudinal_g','g'}, {'acceleration_lateral_g','g'},
  {'acceleration_vertical_g','g'}
}
for _, wheel in ipairs({'FL','FR','RL','RR'}) do expected[#expected + 1] = {wheel .. '_motor_torque_command_Nm','N*m'} end
for _, field in ipairs({{'motor_ctrl_mode',''}, {'yaw_rate_actual_radps','rad/s'}, {'yaw_rate_target_radps','rad/s'}}) do
  expected[#expected + 1] = field
end
for _, wheel in ipairs({'FL','FR','RL','RR'}) do
  for _, field in ipairs({{'tyre_fx_raw_N','N'}, {'tyre_fy_raw_N','N'}, {'tyre_normal_load_N','N'},
      {'tyre_force_body_x_N','N'}, {'tyre_force_body_y_N','N'}, {'tyre_force_body_z_N','N'}, {'tyre_slip_angle_rad','rad'}}) do
    expected[#expected + 1] = {wheel .. '_' .. field[1], field[2]}
  end
end
expected[#expected + 1] = {'cg_sideslip_estimate_rad','rad'}
for _, axis in ipairs({'x','y','z'}) do expected[#expected + 1] = {'tyre_force_sum_body_' .. axis .. '_N','N'} end
for _, axis in ipairs({'x','y','z'}) do expected[#expected + 1] = {'tyre_moment_sum_cg_estimate_body_' .. axis .. '_Nm','N*m'} end
equal(#expected, 54, 'independent expected readable schema')
for i, field in ipairs(expected) do
  equal(baseline.header[i], field[1], 'standard channel name/order ' .. i)
  equal(baseline.units[i], field[2], 'standard channel unit ' .. i)
  check(not field[1]:find('Telemetry', 1, true) and not field[1]:find('@', 1, true)
    and not field[1]:find('__type', 1, true) and not field[1]:find('__received', 1, true)
    and not field[1]:find('__updates', 1, true), 'CSV excludes transport/diagnostic columns')
end
-- Distinct sentinels in each wheel/axis catch any reordered torque, slip, force or
-- moment value, rather than merely checking that all expected labels exist.
for i = 13, #expected do
  local name = expected[i][1]
  if name ~= 'cg_sideslip_estimate_rad' then
    equal(value(baseline, 1, name), string.format('%.17g', packet[name]), 'standard payload value maps to its exact channel: ' .. name)
  end
end
equal(value(baseline, 1, 'FL_motor_torque_command_Nm'), '0', 'real motor zero stays zero')
equal(value(baseline, 1, 'motor_ctrl_mode'), '0', 'real mode zero stays zero')
equal(value(baseline, 1, 'yaw_rate_target_radps'), '0', 'real yaw zero stays zero')
for row = 1, #baseline.rows do equal(value(baseline, row, 'cg_sideslip_estimate_rad'), '', 'CG unavailable all session') end
for col = 13, 54 do equal(baseline.rows[2][col], '', 'no new packet means blank, never held value') end
equal(value(baseline, 1, 'steering_angle_deg'), '8', 'native steering sign')
near(tonumber(value(baseline, 1, 'acceleration_longitudinal_g')), 0.4, 'native longitudinal acceleration')
near(tonumber(value(baseline, 1, 'acceleration_lateral_g')), 0.2, 'native lateral acceleration')
near(tonumber(value(baseline, 1, 'acceleration_vertical_g')), 0.3, 'native vertical acceleration')
pass('default 54 readable channels, unavailable CG, units, real zeros, pause and low-frame-rate sampling')

-- A complete application recording with changing packet shape and sender identity.
local dynamic = start('dynamic-fields')
local message = 'commas, "quotes"\nnext line\r\nlast line'
wall = wall + 0.005
emit({FL_motor_torque_command_Nm = 0, boolean_flag = false, rolling = 11, removed = 100,
  nested = {x = 1, y = 2}, message = message})
tick(0.02, {FL_motor_torque_command_Nm = 0, boolean_flag = false, rolling = 22,
  nested = {x = 3}, message = message})
tick(0.02)
wall = wall + 0.001; emit(false, '4', 'DiscoveredOnly')
tick(0.02, {rolling = 0, boolean_flag = true, newly_added = 'later', nested = {x = 9, y = 10}})
wall = wall + 0.001; emit(nil, '4', 'DiscoveredOnly')
tick(0.02, {boolean_flag = false})
tick(0.02, {rolling = 7, removed = 0, nested = {y = -3}, boolean_flag = false})
wall = wall + 0.001; emit({rolling = 11}, '4')
tick(0.02, {rolling = 99, boolean_flag = false}, '5')
tick(0.02, {rolling = 100}, '5')
tick(0.003, {rolling = 12})
equal(dynamic.dataCount, 7, 'short final interval is still pending before Stop')
dynamic = stop()
local changed = csv(dynamic)
equal(#changed.rows, 8, 'Stop retains the short final pending snapshot')
equal(value(changed, 1, 'removed'), '', 'same-interval replacement clears removed field')
equal(value(changed, 1, 'VehicleTelemetry__nested__y'), '', 'replacement clears removed nested field')
equal(value(changed, 1, 'VehicleTelemetry__nested__x'), '3', 'latest nested value')
equal(value(changed, 1, 'rolling'), '22', 'last packet wins within one interval')
equal(value(changed, 1, 'boolean_flag'), 'false', 'false survives CSV conversion')
equal(value(changed, 1, 'message'), message, 'CSV quoting retains commas, quotes, LF and CRLF')
for col = 13, #changed.header do equal(changed.rows[2][col], '', 'no-packet dynamic sample is blank') end
equal(value(changed, 3, 'rolling'), '0', 'new packet contains a real numeric zero')
equal(value(changed, 3, 'DiscoveredOnly'), 'false', 'non-fallback discovered scalar false')
equal(value(changed, 3, 'newly_added'), 'later', 'mid-session field appears in the union header')
equal(value(changed, 1, 'newly_added'), '', 'new field is blank in historical rows')
equal(value(changed, 4, 'rolling'), '', 'field disappearance is immediate')
equal(value(changed, 5, 'rolling'), '7', 'field can return without resubscribing')
equal(value(changed, 5, 'removed'), '0', 'deleted field can rejoin with zero')
equal(value(changed, 8, 'rolling'), '12', 'pending arrival is captured at Stop')
near(tonumber(value(changed, 8, 'time_s')), 0.143, 'final sample has actual shorter interval')
equal(#changed.header, 12 + #dynamic.fields, 'one CSV value column per native or dynamic channel')
local dynamicRecords = journal(dynamic.journalPath)
local samples, fields = journalSamples(dynamicRecords)
local rollingA = fieldID(fields, 'rolling', '4')
local rollingB
for id, field in pairs(fields) do if field.path == '["rolling"]' and field.source.id == '5' then rollingB = tostring(id) end end
check(rollingB and rollingB ~= rollingA, 'same event/path from another sender has its own schema identity')
equal(changed.rows[6][changed.index[fields[tonumber(rollingB)].name]], '99', 'sender B column contains sender B data')
equal(value(changed, 6, 'rolling'), '11', 'sender A is independent in simultaneous sample')
equal(value(changed, 7, 'rolling'), '', 'sender A does not inherit sender B data')
equal(changed.rows[7][changed.index[fields[tonumber(rollingB)].name]], '100', 'sender B updates independently')
local booleanID, torqueID, scalarID = fieldID(fields, 'boolean_flag', '4'),
  fieldID(fields, 'FL_motor_torque_command_Nm', '4'), fieldID(fields, 'DiscoveredOnly', '4')
equal(samples[1].custom[rollingA].updates, '2', 'journal counts both rolling arrivals')
equal(samples[1].custom[torqueID].updates, '2', 'journal counts both zero torque arrivals')
equal(samples[1].custom[booleanID].kind, 'boolean', 'journal retains false value type')
equal(samples[1].custom[booleanID].value, 'false', 'journal retains false payload')
check(tonumber(samples[1].custom[rollingA].received) >= 0, 'journal retains receive time independently from sample time')
equal(fields[tonumber(rollingA)].source.type, 'car_cphys', 'journal retains source script type')
equal(fields[tonumber(rollingA)].source.id, '4', 'journal retains source ID')
equal(fields[tonumber(rollingA)].event, 'VehicleTelemetry', 'journal retains event identity')
equal(samples[4].custom[scalarID].kind, 'nil', 'explicit nil arrival is distinguishable from no arrival in journal')
check(samples[2].custom[scalarID] == nil, 'absence has no fabricated journal entry')
equal(samples[4].custom[scalarID].updates, '1', 'explicit nil arrival is counted')
for _, name in ipairs(changed.header) do
  check(not name:find('@', 1, true) and not name:find('__type', 1, true)
    and not name:find('__received_wall_s', 1, true) and not name:find('__updates', 1, true),
    'dynamic CSV keeps diagnostics out of the data columns')
end
pass('changing schema, whole-packet replacement, false/string/nil, new/removed/returning fields, independent senders and diagnostics')

-- Fifty genuine physics frames produce fifty samples; no replay/pause/duplicate-frame fabrication.
local rate = start('rate50')
for i = 1, 50 do tick(0.02, {motor_ctrl_mode = i}) end
equal(rate.dataCount, 50, '50 genuine frames give exactly 50 samples')
near(rate.duration, 1, '50 genuine frames span one simulation second')
sim.isLive = false
for _ = 1, 5 do tick(0.2, {motor_ctrl_mode = 500}) end
equal(rate.dataCount, 50, 'paused/replay packets produce no samples')
sim.isLive = true
tick(0, {motor_ctrl_mode = 600})
equal(rate.dataCount, 50, 'zero physics delta produces no sample')
tick(0.02, {motor_ctrl_mode = 700}, nil, false)
equal(rate.dataCount, 50, 'duplicate physics timestamp produces no sample')
tick(0.02, {motor_ctrl_mode = 800})
equal(rate.dataCount, 51, 'next real physics frame gives one sample')
tick(0.11, {motor_ctrl_mode = 900})
equal(rate.dataCount, 52, 'long frame produces one latest sample, not repeated snapshots')
rate = stop()
local timed = csv(rate)
for i = 1, 50 do near(tonumber(value(timed, i, 'time_s')), i * 0.02, '50 Hz real sample timestamp') end
equal(value(timed, 51, 'motor_ctrl_mode'), '800', 'duplicate timestamp data is superseded by new packet')
equal(value(timed, 52, 'motor_ctrl_mode'), '900', 'latest long-frame packet')
pass('50 Hz genuine frame cadence, pause/replay exclusion, duplicate timestamps and no fake catch-up samples')

local function recover(path)
  click('Recover Journal to CSV', path)
  export()
  return currentSession
end
local function sameCSV(a, b, expectedRows)
  equal(#a.header, #b.header, 'recovery preserves complete union schema')
  for col = 1, #a.header do equal(b.header[col], a.header[col], 'recovered column name'); equal(b.units[col], a.units[col], 'recovered unit') end
  equal(#b.rows, expectedRows or #a.rows, 'recovered sample count')
  for row = 1, #b.rows do for col = 1, #a.header do equal(b.rows[row][col], a.rows[row][col], 'recovered original sample value') end end
end
local recovered = recover(dynamic.journalPath)
check(recovered.complete and not recovered.error, 'finished journal recovery succeeds through the real UI')
sameCSV(changed, csv(recovered))
near(recovered.duration, dynamic.duration, 'recovery preserves true duration for average Hz')
check(recovered.recoveryNotice and recovered.recoveryNotice:find('finalized', 1, true), 'finished recovery is labelled')
pass('complete journal -> real recovery UI -> numerically identical single-value CSV')

local _, rawLines = journal(dynamic.journalPath)
local lastSample
for i = #dynamicRecords, 1, -1 do if dynamicRecords[i].type == 'sample' then lastSample = i; break end end
local prefix = {}
for i = 1, lastSample - 1 do prefix[#prefix + 1] = rawLines[i] end
prefix[#prefix + 1] = rawLines[lastSample]:sub(1, math.floor(#rawLines[lastSample] / 2))
local tailPath = outputRoot .. '/truncated-final.journal.jsonl'
local damagedTail = table.concat(prefix, '\n')
writeNative(tailPath, damagedTail)
local tailRecovered = recover(tailPath)
check(tailRecovered.complete and not tailRecovered.error, 'one truncated final record allows prefix recovery')
sameCSV(changed, csv(tailRecovered), #changed.rows - 1)
check(tailRecovered.recoveryNotice:find('ignored', 1, true) and tailRecovered.recoveryNotice:find('unknown', 1, true),
  'partial recovery explicitly discloses ignored tail and unknown loss')
equal(readNative(tailPath), damagedTail, 'truncated raw journal remains intact')
pass('truncated final record restores only verified prefix and explicitly reports unknown tail loss')

local firstSample
for i = 1, #dynamicRecords do if dynamicRecords[i].type == 'sample' then firstSample = i; break end end
local middleLines = {}
for i = 1, #rawLines do middleLines[i] = i == firstSample and 'BROKEN-MIDDLE-RECORD' or rawLines[i] end
local middlePath = outputRoot .. '/broken-middle.journal.jsonl'
local damagedMiddle = table.concat(middleLines, '\n') .. '\n'
writeNative(middlePath, damagedMiddle)
local middleRecovered = recover(middlePath)
check(not middleRecovered.complete and middleRecovered.error and not middleRecovered.exporting,
  'middle corruption refuses to publish an incomplete CSV')
check(not io.exists(middleRecovered.filePath), 'middle corruption leaves no falsely complete CSV')
equal(readNative(middlePath), damagedMiddle, 'corrupt original journal remains untouched')
pass('middle journal corruption is rejected without publishing a CSV or altering the raw file')

for name, before in pairs(productionBefore) do equal(readNative(pluginRoot .. '/' .. name), before, 'production file unchanged: ' .. name) end
local report = {checks = checks, cases = cases, status = 'PASS', gameLaunched = false,
  defaultColumns = #baseline.header, defaultRows = #baseline.rows, dynamicRows = #changed.rows,
  genuine50HzRows = 50, recoveryEquivalent = true, truncatedTailRows = #changed.rows - 1,
  middleCorruptionRejected = true, outputRoot = outputRoot}
writeNative(outputRoot .. '/report.json', JSON.stringify(report) .. '\n')
print(string.format('PASS all %d integration cases, %d checks; production files unchanged; game not launched', #cases, checks))
