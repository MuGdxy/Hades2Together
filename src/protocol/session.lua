local Session = {}

Session.MAX_PLAYERS = 4
Session.ROLES = {
  serve = true,
  ["serve+play"] = true,
  play = true,
}

function Session.validSeat(value, maxPlayers)
  return type(value) == "number" and value >= 1 and value <= (maxPlayers or 9007199254740991)
    and value % 1 == 0
end

function Session.capacity(session)
  return session.maxPlayers or Session.MAX_PLAYERS
end

function Session.new(role, maxPlayers)
  if not Session.ROLES[role] then
    error("unknown role " .. tostring(role))
  end
  if maxPlayers == nil then
    maxPlayers = Session.MAX_PLAYERS
  end
  assert(Session.validSeat(maxPlayers), "invalid maxPlayers")
  return {
    role = role,
    slots = {},
    maxPlayers = maxPlayers,
  }
end

function Session.isAuthority(session)
  return session.role == "serve" or session.role == "serve+play"
end

function Session.loadsClient(session)
  return session.role == "play" or session.role == "serve+play"
end

function Session.count(session)
  local count = 0
  for _ in pairs(session.slots) do
    count = count + 1
  end
  return count
end

function Session.findSeat(session, name)
  for index, slot in pairs(session.slots) do
    if slot.name == name then
      return index
    end
  end
end

-- A seat stays with the name that took it, including across a disconnect.
function Session.join(session, name, seatId)
  if type(name) ~= "string" or name == "" then
    return nil, "name required"
  end
  local maxPlayers = Session.capacity(session)
  if seatId ~= nil and not Session.validSeat(seatId, maxPlayers) then
    return nil, "invalid seat"
  end
  local reserved = Session.findSeat(session, name)
  if reserved then
    if seatId ~= nil and seatId ~= reserved then
      return nil, "name reserved at another seat"
    end
    local slot = session.slots[reserved]
    if not slot.connected then
      slot.connectionGeneration = (slot.connectionGeneration or 1) + 1
    end
    slot.connected = true
    return reserved, "rejoined"
  end
  if seatId then
    if session.slots[seatId] then
      return nil, "seat occupied"
    end
  else
    seatId = 1
    while seatId <= maxPlayers and session.slots[seatId] do
      seatId = seatId + 1
    end
    if seatId > maxPlayers then
      return nil, "full"
    end
  end
  session.slots[seatId] = { name = name, connected = true, connectionGeneration = 1 }
  return seatId, "joined"
end

function Session.release(session, index)
  local slot = session.slots[index]
  if not slot then
    return false
  end
  slot.connected = false
  return true
end

-- Frees a seat when its first join fails. A disconnect uses release instead.
function Session.drop(session, index)
  if not session.slots[index] then
    return false
  end
  session.slots[index] = nil
  return true
end

return Session
