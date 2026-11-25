local Messages = import("protocol/messages.lua")

local Input = {}

function Input.frame(tick, playerId, state, seq)
  state = state or {}
  return Messages.input(
    tick,
    playerId,
    state.moveX or 0,
    state.moveY or 0,
    state.buttons or 0,
    state.aimX or 0,
    state.aimY or 0,
    seq
  )
end

return Input
