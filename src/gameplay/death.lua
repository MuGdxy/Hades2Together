local Party = import("gameplay/party.lua")
local Commands = import("gameplay/commands.lua")

local Death = {}

-- One hero falling leaves the run going. The run ends when nobody is alive.
function Death.onHeroDown(party, playerId)
  if not Party.kill(party, playerId) then
    return {}
  end
  if Party.aliveCount(party) == 0 then
    return { Commands.endRun("wipe") }
  end
  return { Commands.heroDown(playerId) }
end

return Death
