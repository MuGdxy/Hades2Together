-- Restricted serializer for protocol tables.
-- Values: nil, boolean, number, string, array, string-keyed object.
-- Object keys are written in sorted order so the same table encodes the same bytes.

local Codec = {}

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

local function decodeAt(data, index)
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
    local semi = data:find(";", index, true)
    if not semi then
      error("codec truncated number")
    end
    local number = tonumber(data:sub(index, semi - 1))
    if not number then
      error("codec bad number")
    end
    return number, semi + 1
  end
  if tag == "s" then
    local colon = data:find(":", index, true)
    if not colon then
      error("codec truncated string")
    end
    local length = tonumber(data:sub(index, colon - 1))
    if not length or length < 0 then
      error("codec bad string length")
    end
    local startAt = colon + 1
    local finish = startAt + length - 1
    if finish > #data then
      error("codec truncated string bytes")
    end
    return data:sub(startAt, finish), finish + 1
  end

  local function takeCount(from)
    local semi = data:find(";", from, true)
    if not semi then
      error("codec truncated count")
    end
    local count = tonumber(data:sub(from, semi - 1))
    if not count or count < 0 then
      error("codec bad count")
    end
    return count, semi + 1
  end

  if tag == "a" then
    local count, cursor = takeCount(index)
    local array = {}
    for item = 1, count do
      array[item], cursor = decodeAt(data, cursor)
    end
    return array, cursor
  end
  if tag == "o" then
    local count, cursor = takeCount(index)
    local object = {}
    for _ = 1, count do
      local key
      key, cursor = decodeAt(data, cursor)
      if type(key) ~= "string" then
        error("codec object key was not a string")
      end
      object[key], cursor = decodeAt(data, cursor)
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
  local ok, value, cursor = pcall(decodeAt, data, 1)
  if not ok then
    return nil, value
  end
  if cursor ~= #data + 1 then
    return nil, "codec trailing bytes"
  end
  return value
end

return Codec
