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
      slot.connected = true
      return index, "rejoined"
    end
  end
  for index = 1, Session.MAX_PLAYERS do
    if session.slots[index] == nil then
      session.slots[index] = { name = name, connected = true }
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

return Session
