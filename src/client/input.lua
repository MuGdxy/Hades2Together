local Messages = import("protocol/messages.lua")
local Actions = import("protocol/actions.lua")

local Input = {}

function Input.parse(words, first)
  local moveX, moveY = tonumber(words[first]), tonumber(words[first + 1])
  if not Messages.validAxis(moveX) or not Messages.validAxis(moveY) then
    return nil, "input axes must be numbers in [-1,1]"
  end
  local buttons, unknown = Actions.mask(words, first + 2)
  if not buttons then return nil, "unknown input action " .. unknown end
  return { moveX = moveX, moveY = moveY, buttons = buttons }
end

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
