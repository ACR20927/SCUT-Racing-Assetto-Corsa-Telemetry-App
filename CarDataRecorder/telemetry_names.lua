-- CSV labels are presentation only: event/path/sender identities remain in the journal.
local channels = require('telemetry_channels')
local names = {}
local knownPaths = {}

function names.pathForKey(key)
  return '[' .. JSON.stringify(key) .. ']'
end

for i = 1, #channels.fields do
  local field = channels.fields[i]
  knownPaths[names.pathForKey(field.name)] = field
end

local function pathParts(path)
  local parts, position = {}, 1
  while position <= #path do
    if path:sub(position, position) ~= '[' then return nil end
    if path:sub(position + 1, position + 1) == '"' then
      local start, ending = position + 1, position + 2
      while ending <= #path do
        local character = path:sub(ending, ending)
        if character == '\\' then ending = ending + 2
        elseif character == '"' then break
        else ending = ending + 1 end
      end
      if path:sub(ending, ending + 1) ~= '"]' then return nil end
      local ok, key = pcall(JSON.parse, path:sub(start, ending))
      if not ok or type(key) ~= 'string' then return nil end
      parts[#parts + 1] = {key = key, stringKey = true}
      position = ending + 2
    else
      local ending = path:find(']', position + 1, true)
      if not ending then return nil end
      parts[#parts + 1] = {key = path:sub(position + 1, ending - 1), stringKey = false}
      position = ending + 1
    end
  end
  return parts
end

local function readablePath(parts, fallback)
  if not parts then return fallback end
  local labels = {}
  for i = 1, #parts do
    local part = parts[i]
    if not part.stringKey then labels[i] = 'index_' .. part.key
    elseif part.key:match('^[%a_][%w_]*$') then labels[i] = part.key
    else labels[i] = '[' .. JSON.stringify(part.key) .. ']' end
  end
  return table.concat(labels, '__')
end

function names.describe(eventName, path)
  if eventName == channels.eventName then
    local known = knownPaths[path]
    if known then return known.name, known.unit end
  end
  local parts = pathParts(path)
  -- New flat values in the contract event remain plain column names as well.
  if eventName == channels.eventName and parts and #parts == 1 and parts[1].stringKey
      and parts[1].key ~= '' then
    return parts[1].key, ''
  end
  local name = path == '' and eventName or eventName .. '__' .. readablePath(parts, path)
  local unit = ''
  if (eventName == 'Torque' or eventName == 'Fy') and path:match('^%[%d+%]$') then
    unit = eventName == 'Torque' and 'N*m' or 'N'
  elseif path == '' and (eventName == 'real_yawrate' or eventName == 'ideal_yawrate') then
    unit = 'rad/s'
  end
  return name, unit
end

return names
