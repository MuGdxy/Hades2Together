local Session = import("protocol/session.lua")

local Party = {}

Party.MAX = Session.MAX_PLAYERS

function Party.new(maxPlayers)
  if maxPlayers == nil then
    maxPlayers = Party.MAX
  end
  assert(Session.validSeat(maxPlayers), "invalid maxPlayers")
  return { members = {}, maxPlayers = maxPlayers }
end

function Party.count(party)
  local count = 0
  for _ in pairs(party.members) do
    count = count + 1
  end
  return count
end

function Party.aliveCount(party)
  local count = 0
  for _, member in pairs(party.members) do
    if member.alive then
      count = count + 1
    end
  end
  return count
end

function Party.add(party, playerId)
  if type(playerId) ~= "number" then
    return false, "player id must be a number"
  end
  if party.members[playerId] then
    return false, "already in party"
  end
  if Party.count(party) >= (party.maxPlayers or Party.MAX) then
    return false, "party full"
  end
  party.members[playerId] = { id = playerId, alive = true }
  return true
end

function Party.kill(party, playerId)
  local member = party.members[playerId]
  if not member or not member.alive then
    return false
  end
  member.alive = false
  return true
end

return Party
