-- Two in-memory endpoints. What one sends, the other drains.
-- TCP uses the same send/drain shape.

local Loopback = {}

function Loopback.pair()
  local toRight = {}
  local toLeft = {}

  local left = {
    send = function(_, kind, msg)
      toRight[#toRight + 1] = { kind = kind, msg = msg }
    end,
    drain = function()
      local items = toLeft
      toLeft = {}
      return items
    end,
  }

  local right = {
    send = function(_, kind, msg)
      toLeft[#toLeft + 1] = { kind = kind, msg = msg }
    end,
    drain = function()
      local items = toRight
      toRight = {}
      return items
    end,
  }

  return left, right
end

return Loopback
