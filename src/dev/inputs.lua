-- Scripted movement. Lines are: slot moveX moveY seconds
-- Optional: name slot Name
-- Blank lines and lines starting with # are ignored.

local Inputs = {}

local MAX_SLOT = 4

function Inputs.parse(text)
  local names = {}
  local steps = {}
  for slot = 1, MAX_SLOT do
    steps[slot] = {}
  end
  if type(text) ~= "string" then
    return { names = names, steps = steps }
  end
  for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    if not line:match("^%s*#") and line:match("%S") then
      local nameSlot, name = line:match("^%s*name%s+(%d+)%s+(.+)$")
      if nameSlot then
        local slot = tonumber(nameSlot)
        if slot and slot >= 1 and slot <= MAX_SLOT then
          names[slot] = name:gsub("%s+$", "")
        end
      else
        local slotText, mxText, myText, durText = line:match("^%s*(%d+)%s+([%+%-%d%.]+)%s+([%+%-%d%.]+)%s+([%+%-%d%.]+)%s*$")
        local slot = tonumber(slotText)
        local mx = tonumber(mxText)
        local my = tonumber(myText)
        local dur = tonumber(durText)
        if slot and steps[slot] and mx and my and dur and dur > 0 then
          local list = steps[slot]
          list[#list + 1] = { mx = mx, my = my, dur = dur }
        end
      end
    end
  end
  return { names = names, steps = steps }
end

function Inputs.stick(script, slot, time)
  local list = script.steps[slot]
  if not list then
    return 0, 0
  end
  local cursor = 0
  for index = 1, #list do
    local step = list[index]
    if time < cursor + step.dur then
      return step.mx, step.my, true
    end
    cursor = cursor + step.dur
  end
  return 0, 0
end

return Inputs
