local Messages = import("protocol/messages.lua")

local Input = {}

function Input.frame(tick, playerId, state, seq)
  if state ~= nil and type(state) ~= "table" then
    return nil
  end
  state = state or {}
  return Messages.input(
    tick,
    playerId,
    state.moveX == nil and 0 or state.moveX,
    state.moveY == nil and 0 or state.moveY,
    state.buttons,
    state.aimX,
    state.aimY,
    seq
  )
end

return Input
