local Commands = {}

function Commands.heroDown(playerId)
  return { type = "HeroDown", playerId = playerId }
end

function Commands.endRun(reason)
  return { type = "EndRun", reason = reason }
end

function Commands.offerLoot(playerId, reward)
  return { type = "OfferLoot", playerId = playerId, reward = reward }
end

function Commands.scaleEncounter(multiplier)
  return { type = "ScaleEncounter", multiplier = multiplier }
end

function Commands.spawnHero(playerId, spec)
  return { type = "SpawnHero", playerId = playerId, spec = spec }
end

return Commands
