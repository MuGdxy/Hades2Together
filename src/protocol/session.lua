local Session = {}

Session.MAX_PLAYERS = 4
Session.ROLES = {
  serve = true,
  ["serve+play"] = true,
  play = true,
}

function Session.new(role)
  if not Session.ROLES[role] then
    error("unknown role " .. tostring(role))
  end
  return {
    role = role,
    slots = {},
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

-- A seat stays with the name that took it, including across a disconnect.
function Session.join(session, name)
  if type(name) ~= "string" or name == "" then
    return nil, "name required"
  end
  for index = 1, Session.MAX_PLAYERS do
    local slot = session.slots[index]
    if slot and slot.name == name then
      if not slot.connected then
        slot.connectionGeneration = (slot.connectionGeneration or 1) + 1
      end
      slot.connected = true
      return index, "rejoined"
    end
  end
  for index = 1, Session.MAX_PLAYERS do
    if session.slots[index] == nil then
      session.slots[index] = { name = name, connected = true, connectionGeneration = 1 }
      return index, "joined"
    end
  end
  return nil, "full"
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
