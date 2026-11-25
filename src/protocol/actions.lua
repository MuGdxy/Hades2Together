local Actions = { VERSION = 1 }

-- Protocol V1 assigns bit 0 to the first name, bit 1 to the second, and so on.
local names = { "Attack1", "Attack2", "Attack3", "Rush", "Use", "Shout", "Select", "Cancel" }
local bits = {}
for index, name in ipairs(names) do
  bits[name] = 2 ^ (index - 1)
end
local maxMask = 2 ^ #names - 1

function Actions.names()
  return table.concat(names, " ")
end

function Actions.bit(name)
  return bits[name]
end

function Actions.mask(words, first)
  local mask, seen = 0, {}
  for index = first, #words do
    local name = words[index]
    local bit = bits[name]
    if not bit then
      return nil, name
    end
    if not seen[name] then
      seen[name] = true
      mask = mask + bit
    end
  end
  return mask
end

function Actions.validMask(mask)
  return type(mask) == "number" and mask >= 0 and mask <= maxMask and mask % 1 == 0
end

return Actions
