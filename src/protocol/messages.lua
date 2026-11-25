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
    buttons = buttons or 0,
    aimX = aimX or 0,
    aimY = aimY or 0,
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

function Messages.welcome(playerId)
  return { t = "welcome", protocol = Messages.PROTOCOL, playerId = playerId }
end

function Messages.error(reason)
  return { t = "error", reason = reason }
end

local function integer(value, min, max)
  return type(value) == "number" and value >= min and value <= max and value % 1 == 0
end

local function axis(value)
  return type(value) == "number" and value >= -1 and value <= 1
end

function Messages.validHello(msg)
  return Messages.accepts(msg.protocol) and type(msg.name) == "string"
    and #msg.name <= 64 and msg.name:find("%S") ~= nil and not msg.name:find("%c")
end

function Messages.validTick(tick)
  return integer(tick, 0, 9007199254740991)
end

function Messages.validInput(msg, maxPlayers)
  return integer(msg.playerId, 1, maxPlayers)
    and integer(msg.seq, 1, 9007199254740991)
    and Messages.validTick(msg.tick)
    and axis(msg.moveX) and axis(msg.moveY)
    and axis(msg.aimX) and axis(msg.aimY)
    and integer(msg.buttons, 0, 4294967295)
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
