local Scaling = {}

Scaling.DEFAULT_PER_EXTRA = 0.75

function Scaling.hpMultiplier(partySize, perExtra)
  perExtra = perExtra or Scaling.DEFAULT_PER_EXTRA
  if partySize < 1 then
    partySize = 1
  end
  return 1 + (partySize - 1) * perExtra
end

function Scaling.hitPoints(baseHp, partySize, perExtra)
  local scaled = baseHp * Scaling.hpMultiplier(partySize, perExtra)
  return math.floor(scaled + 0.5)
end

return Scaling
