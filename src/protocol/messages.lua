local Messages = {}

Messages.PROTOCOL = 1

function Messages.accepts(protocol)
  return protocol == Messages.PROTOCOL
end

function Messages.input(tick, playerId, moveX, moveY, buttons, aimX, aimY)
  return {
    t = "in",
    tick = tick,
    playerId = playerId,
    moveX = moveX,
    moveY = moveY,
    buttons = buttons or 0,
    aimX = aimX or 0,
    aimY = aimY or 0,
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

function Messages.snapshot(tick, heroes, enemies)
  return {
    t = "snap",
    tick = tick,
    heroes = heroes,
    enemies = enemies,
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
