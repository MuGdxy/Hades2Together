local Messages = import("protocol/messages.lua")
local Session = import("protocol/session.lua")

local Room = {}

local function id(value)
  return Messages.validTick(value) and value > 0
end

local function name(value)
  return type(value) == "string" and #value > 0 and #value <= 128 and not value:find("%c")
end

-- Return the record keys so rewards can also check room membership.
local function unique(list, keyFor)
  if type(list) ~= "table" then
    return nil
  end
  local keys, count, length = {}, 0, #list
  for index, record in pairs(list) do
    if not id(index) or index > length then
      return nil
    end
    local key = keyFor(record)
    if not key or keys[key] then
      return nil
    end
    keys[key] = true
    count = count + 1
  end
  if count == length then
    return keys
  end
end

local function exitId(exit)
  if type(exit) == "table" and id(exit.id) and type(exit.readyToUse) == "boolean"
    and type(exit.inUse) == "boolean" and (exit.destination == nil or name(exit.destination)) then
    return exit.id
  end
end

local claimStates = { eligible = true, claiming = true, consumed = true }

local function validOptions(claim)
  if claim.options == nil then return claim.selected == nil end
  local options = unique(claim.options, function(option) return name(option) and option end)
  return options and (claim.selected == nil or (claim.state == "claiming" and options[claim.selected]))
    and (claim.choice == nil or options[claim.choice])
end

local function rewardId(reward, participants, maxPlayers)
  if type(reward) ~= "table" or not id(reward.id) or not id(reward.encounterId)
    or not name(reward.kind) or (reward.objectId ~= nil and not id(reward.objectId)) then
    return nil
  end
  if reward.claims ~= nil and not unique(reward.claims, function(claim)
    if type(claim) == "table" and Session.validSeat(claim.playerId, maxPlayers) and claimStates[claim.state]
      and (not participants or participants[claim.playerId]) and validOptions(claim)
      and (claim.choice == nil or claim.state == "consumed" and name(claim.choice)) then
      return claim.playerId
    end
  end) then
    return nil
  end
  return reward.id
end

function Room.valid(room, maxPlayers)
  if type(room) ~= "table" or not id(room.id) or not name(room.name)
    or type(room.exitsUnlocked) ~= "boolean" or type(room.leaving) ~= "boolean" then
    return false
  end
  local encounter = room.encounter
  if encounter ~= nil and (type(encounter) ~= "table" or not id(encounter.id)
    or not name(encounter.name) or type(encounter.completed) ~= "boolean") then
    return false
  end
  if maxPlayers == nil then
    maxPlayers = Session.MAX_PLAYERS
  elseif not Session.validSeat(maxPlayers) then
    return false
  end
  local participants = unique(room.participants, function(seat)
    if Session.validSeat(seat, maxPlayers) then
      return seat
    end
  end)
  if room.participants ~= nil and not participants then
    return false
  end
  return (room.exits == nil or unique(room.exits, exitId) ~= nil)
    and (room.rewards == nil or unique(room.rewards, function(reward)
      return rewardId(reward, participants, maxPlayers)
    end) ~= nil)
end

return Room
