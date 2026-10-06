-- Turn a shared-event payload into named scalar fields without assuming its schema.
-- Paths use JSON-style brackets: [1] is distinct from ["1"]. The scalar root is "".
local telemetryFields = {}
local maxDepth = 32

local function safeString(value)
  local ok, result = pcall(tostring, value)
  return ok and result or '<unprintable>'
end

local function jsonString(value)
  return '"' .. value:gsub('[%z\1-\31\\"]', function(character)
    if character == '"' then return '\\"' end
    if character == '\\' then return '\\\\' end
    return string.format('\\u%04x', string.byte(character))
  end) .. '"'
end

local function finiteNumber(value)
  return value == value and value ~= math.huge and value ~= -math.huge
end

local function numberText(value)
  if value ~= value then return 'NaN' end
  if value == math.huge then return '+Infinity' end
  if value == -math.huge then return '-Infinity' end
  -- Lua considers negative zero and positive zero to be the same table key.
  if value == 0 then return '0' end
  return string.format('%.17g', value)
end

local function keyDescription(key)
  local kind = type(key)
  if kind == 'number' then
    local text = numberText(key)
    if finiteNumber(key) then return '[' .. text .. ']', 1, key end
    return '[number:' .. jsonString(text) .. ']', 1, text
  end
  if kind == 'string' then return '[' .. jsonString(key) .. ']', 2, key end
  if kind == 'boolean' then
    return '[boolean:' .. tostring(key) .. ']', 3, key and 1 or 0
  end
  -- Such keys are not serializable by normal event senders, but describe rather
  -- than silently drop them if a caller nevertheless supplies one.
  local text = safeString(key)
  return '[' .. kind .. ':' .. jsonString(text) .. ']', 4, kind .. ':' .. text
end

local function sortedKeys(value)
  local keys = {}
  for key in next, value do
    local path, rank, sortValue = keyDescription(key)
    keys[#keys + 1] = {key = key, path = path, rank = rank,
      sortValue = sortValue, order = #keys + 1}
  end
  table.sort(keys, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    local at, bt = type(a.sortValue), type(b.sortValue)
    if at ~= bt then return at < bt end
    if a.sortValue ~= b.sortValue then return a.sortValue < b.sortValue end
    return a.order < b.order
  end)
  return keys
end

local function getTypeChecker(factory, name)
  if factory == nil then return nil end
  local ok, checker = pcall(function() return factory[name] end)
  if ok and type(checker) == 'function' then return checker end
  return nil
end

-- These predicates are documented in the CSP SDK (ac_primitive_*.d.lua).
-- Resolve them once; the module also remains usable without CSP math globals.
local componentTypes = {
  {check = getTypeChecker(vec2, 'isvec2'), fields = {'x', 'y'}},
  {check = getTypeChecker(vec3, 'isvec3'), fields = {'x', 'y', 'z'}},
  {check = getTypeChecker(vec4, 'isvec4'), fields = {'x', 'y', 'z', 'w'}},
  {check = getTypeChecker(rgb, 'isrgb'), fields = {'r', 'g', 'b'}},
  {check = getTypeChecker(rgbm, 'isrgbm'), fields = {'r', 'g', 'b', 'mult'}}
}

local function getComponents(value)
  for i = 1, #componentTypes do
    local candidate = componentTypes[i]
    if candidate.check then
      local ok, matches = pcall(candidate.check, value)
      if ok and matches then return candidate.fields end
    end
  end
  return nil
end

local function readComponent(value, name)
  return value[name]
end

function telemetryFields.flatten(data)
  local fields = {}
  -- Track the active ancestry only: shared non-cyclic subtables are expanded at
  -- each path, while a true cycle becomes an explicit marker at its own path.
  local ancestors = {}
  local function append(path, kind, value)
    fields[#fields + 1] = {path = path, kind = kind, value = value}
  end

  local walk
  walk = function(value, path, depth)
    local kind = type(value)
    if kind == 'nil' then
      append(path, 'nil')
    elseif kind == 'number' then
      if finiteNumber(value) then append(path, 'number', value)
      else append(path, 'nonfinite', numberText(value)) end
    elseif kind == 'string' or kind == 'boolean' then
      append(path, kind, value)
    elseif kind == 'table' then
      if ancestors[value] ~= nil then
        append(path, 'cycle', ancestors[value] == '' and '<root>' or ancestors[value])
        return
      end
      if next(value) == nil then
        append(path, 'empty_table', '{}')
        return
      end
      if depth >= maxDepth then
        append(path, 'depth_limit', 'Maximum nesting depth: ' .. maxDepth)
        return
      end
      ancestors[value] = path
      local keys = sortedKeys(value)
      for i = 1, #keys do
        local entry = keys[i]
        if entry.rank == 4 then
          append(path .. entry.path, 'unsupported', 'Unsupported table key: '
            .. type(entry.key) .. '; value type: ' .. type(rawget(value, entry.key)))
        else
          -- Avoid arbitrary __index/__pairs behaviour on untrusted payloads.
          walk(rawget(value, entry.key), path .. entry.path, depth + 1)
        end
      end
      ancestors[value] = nil
    elseif kind == 'cdata' or kind == 'userdata' then
      local components = getComponents(value)
      if not components then
        append(path, 'unsupported', kind .. ': ' .. safeString(value))
        return
      end
      if depth >= maxDepth then
        append(path, 'depth_limit', 'Maximum nesting depth: ' .. maxDepth)
        return
      end
      for i = 1, #components do
        local name = components[i]
        local childPath = path .. '[' .. jsonString(name) .. ']'
        local ok, component = pcall(readComponent, value, name)
        if ok then walk(component, childPath, depth + 1)
        else append(childPath, 'error', safeString(component)) end
      end
    else
      append(path, 'unsupported', kind .. ': ' .. safeString(value))
    end
  end

  local ok, err = pcall(walk, data, '', 0)
  if not ok then append('', 'error', safeString(err)) end
  return fields
end

return telemetryFields
