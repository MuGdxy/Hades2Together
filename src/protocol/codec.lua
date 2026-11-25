-- Restricted serializer for protocol tables.
-- Values: nil, boolean, number, string, array, string-keyed object.
-- Object keys are written in sorted order so the same table encodes the same bytes.

local Codec = {}

Codec.MAX_BYTES = 64 * 1024
local MAX_DEPTH = 24

local function isArray(value)
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" then
      return false
    end
    count = count + 1
  end
  return count == #value
end

local function encode(value)
  local kind = type(value)
  if value == nil then
    return "z"
  end
  if kind == "boolean" then
    return value and "t" or "f"
  end
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      error("codec cannot encode non-finite number")
    end
    return "n" .. string.format("%.17g", value) .. ";"
  end
  if kind == "string" then
    return "s" .. tostring(#value) .. ":" .. value
  end
  if kind ~= "table" then
    error("codec cannot encode " .. kind)
  end

  if isArray(value) then
    local parts = { "a", tostring(#value), ";" }
    for index = 1, #value do
      parts[#parts + 1] = encode(value[index])
    end
    return table.concat(parts)
  end

  local keys = {}
  for key in pairs(value) do
    if type(key) ~= "string" then
      error("codec object keys must be strings")
    end
    keys[#keys + 1] = key
  end
  table.sort(keys)
  local parts = { "o", tostring(#keys), ";" }
  for _, key in ipairs(keys) do
    parts[#parts + 1] = encode(key)
    parts[#parts + 1] = encode(value[key])
  end
  return table.concat(parts)
end

local function span(data, index, delimiter)
  local stop = data:find(delimiter, index, true)
  if not stop then
    error("codec missing " .. delimiter)
  end
  return data:sub(index, stop - 1), stop + 1
end

local function countAt(data, index, delimiter)
  local digits, cursor = span(data, index, delimiter)
  local count = tonumber(digits)
  if not digits:match("^%d+$") or not count or count > #data - cursor + 1 then
    error("codec invalid length or count")
  end
  return count, cursor
end

local function decodeAt(data, index, depth)
  if depth > MAX_DEPTH then
    error("codec nesting limit")
  end
  local tag = data:sub(index, index)
  if tag == "" then
    error("codec truncated")
  end
  index = index + 1

  if tag == "z" then
    return nil, index
  end
  if tag == "t" then
    return true, index
  end
  if tag == "f" then
    return false, index
  end
  if tag == "n" then
    local token, cursor = span(data, index, ";")
    local number = tonumber(token)
    if not number or number ~= number or math.abs(number) == math.huge then
      error("codec bad number")
    end
    return number, cursor
  end
  if tag == "s" then
    local length, startAt = countAt(data, index, ":")
    local finish = startAt + length - 1
    return data:sub(startAt, finish), finish + 1
  end

  if tag == "a" then
    local count, cursor = countAt(data, index, ";")
    local array = {}
    for item = 1, count do
      array[item], cursor = decodeAt(data, cursor, depth + 1)
    end
    return array, cursor
  end
  if tag == "o" then
    local count, cursor = countAt(data, index, ";")
    local object, seen = {}, {}
    for _ = 1, count do
      local key
      key, cursor = decodeAt(data, cursor, depth + 1)
      if type(key) ~= "string" or seen[key] then
        error("codec invalid or repeated object key")
      end
      seen[key] = true
      object[key], cursor = decodeAt(data, cursor, depth + 1)
    end
    return object, cursor
  end

  error("codec bad tag")
end

function Codec.encode(value)
  return encode(value)
end

function Codec.decode(data)
  if type(data) ~= "string" then
    return nil, "codec data must be a string"
  end
  if #data > Codec.MAX_BYTES then
    return nil, "codec byte limit"
  end
  local ok, value, cursor = pcall(decodeAt, data, 1, 0)
  if not ok then
    return nil, value
  end
  if cursor ~= #data + 1 then
    return nil, "codec trailing bytes"
  end
  return value
end

return Codec
