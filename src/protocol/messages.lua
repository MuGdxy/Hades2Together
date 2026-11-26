local Actions = import("protocol/actions.lua")

local Messages = {}

Messages.PROTOCOL = 1

function Messages.accepts(protocol)
  return protocol == Messages.PROTOCOL
end

function Messages.input(tick, playerId, moveX, moveY, buttons, aimX, aimY, seq)
  return {
    t = "in",
    tick = tick,
    playerId = playerId,
    moveX = moveX,
    moveY = moveY,
    buttons = buttons == nil and 0 or buttons,
    aimX = aimX == nil and 0 or aimX,
    aimY = aimY == nil and 0 or aimY,
    seq = seq,
  }
end

function Messages.hello(name, protocol)
  return {
    t = "hello",
    name = name,
    protocol = protocol or Messages.PROTOCOL,
  }
end

function Messages.roster(slots)
  return {
    t = "roster",
    slots = slots,
  }
end

function Messages.welcome(playerId, maxPlayers)
  return { t = "welcome", protocol = Messages.PROTOCOL, playerId = playerId, maxPlayers = maxPlayers }
end

function Messages.error(reason)
  return { t = "error", reason = reason }
end

local function integer(value, min, max)
  return type(value) == "number" and value >= min and value <= max and value % 1 == 0
end

function Messages.validAxis(value)
  return type(value) == "number" and value >= -1 and value <= 1
end

function Messages.validHello(msg)
  return Messages.accepts(msg.protocol) and type(msg.name) == "string"
    and #msg.name <= 64 and msg.name:find("%S") ~= nil and not msg.name:find("%c")
end

function Messages.validTick(tick)
  return integer(tick, 0, 9007199254740991)
end

local inputFields = {
  t = true, tick = true, playerId = true, seq = true,
  moveX = true, moveY = true, aimX = true, aimY = true, buttons = true,
}

function Messages.validInput(msg, maxPlayers)
  if type(msg) ~= "table" or msg.t ~= "in" then
    return false
  end
  for key in pairs(msg) do
    if not inputFields[key] then
      return false
    end
  end
  return integer(msg.playerId, 1, maxPlayers)
    and integer(msg.seq, 1, 9007199254740991)
    and Messages.validTick(msg.tick)
    and Messages.validAxis(msg.moveX) and Messages.validAxis(msg.moveY)
    and Messages.validAxis(msg.aimX) and Messages.validAxis(msg.aimY)
    and Actions.validMask(msg.buttons)
end

function Messages.snapshot(tick, heroes, enemies, room)
  return {
    t = "snap",
    tick = tick,
    heroes = heroes,
    enemies = enemies,
    room = room,
  }
end

function Messages.event(name, fields)
  local msg = { t = "ev", e = name }
  if fields then
    for key, value in pairs(fields) do
      msg[key] = value
    end
  end
  return msg
end

return Messages
