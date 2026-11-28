-- Scripted movement. Lines are: slot moveX moveY seconds
-- Optional: name slot Name
-- Blank lines and lines starting with # are ignored.

local Inputs = {}

local Messages = import("protocol/messages.lua")
local Session = import("protocol/session.lua")

function Inputs.parse(text, maxPlayers)
  local names = {}
  local steps = {}
  if maxPlayers == nil then
    maxPlayers = Session.MAX_PLAYERS
    -- Preserve the original one-argument result for existing callers.
    for slot = 1, maxPlayers do
      steps[slot] = {}
    end
  else
    assert(Session.validSeat(maxPlayers), "invalid maxPlayers")
  end
  if type(text) ~= "string" then
    return { names = names, steps = steps }
  end
  for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    if not line:match("^%s*#") and line:match("%S") then
      local nameSlot, name = line:match("^%s*name%s+(%d+)%s+(.+)$")
      if nameSlot then
        local slot = tonumber(nameSlot)
        if Session.validSeat(slot, maxPlayers) then
          names[slot] = name:gsub("%s+$", "")
        end
      else
        local slotText, mxText, myText, durText = line:match("^%s*(%d+)%s+([%+%-%d%.]+)%s+([%+%-%d%.]+)%s+([%+%-%d%.]+)%s*$")
        local slot = tonumber(slotText)
        local mx = tonumber(mxText)
        local my = tonumber(myText)
        local dur = tonumber(durText)
        if Session.validSeat(slot, maxPlayers) and Messages.validAxis(mx) and Messages.validAxis(my)
            and dur and dur > 0 and dur < math.huge then
          local list = steps[slot] or {}
          list[#list + 1] = { mx = mx, my = my, dur = dur }
          steps[slot] = list
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
