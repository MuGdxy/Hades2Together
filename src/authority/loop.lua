local Engine = import("hack/engine.lua")
local Party = import("gameplay/party.lua")
local Death = import("gameplay/death.lua")
local Scaling = import("gameplay/scaling.lua")
local Loot = import("gameplay/loot.lua")
local Messages = import("protocol/messages.lua")
local Room = import("protocol/room.lua")

local Authority = {}

function Authority.start(engine, options)
  Engine.assert(engine)
  options = options or {}
  return {
    engine = engine,
    party = Party.new(),
    tick = 0,
    stockRules = options.stockRules == true,
    hpPerExtra = options.hpPerExtraPlayer or Scaling.DEFAULT_PER_EXTRA,
    lootPolicy = options.lootPolicy or "round_robin",
    lootContext = { cursor = 1 },
    scaled = false,
    ended = false,
  }
end

function Authority.addPlayer(auth, playerId, spec)
  local ok, err = Party.add(auth.party, playerId)
  if not ok then
    return false, err
  end
  auth.engine:BindHero(playerId, spec)
  return true
end

function Authority.apply(auth, commands)
  for _, command in ipairs(commands) do
    if command.type == "EndRun" then
      auth.ended = true
      auth.engine:Call("EndRun", command.reason)
    elseif command.type == "HeroDown" then
      auth.engine:Call("HeroDown", command.playerId)
    elseif command.type == "OfferLoot" then
      auth.engine:RunAsHero(command.playerId, function()
        auth.engine:Call("OfferLoot", command.reward)
      end)
    elseif command.type == "ScaleEncounter" then
      auth.engine:Call("ScaleEncounter", command.multiplier)
    else
      error("unknown command " .. tostring(command.type))
    end
  end
end

-- The legacy fixture loop scales its first encounter. Stock mode only forwards
-- input and observes the engine's state after that step.
function Authority.step(auth, inputs)
  if auth.ended then
    local actors = auth.engine:ReadActors()
    return {
      snapshot = Messages.snapshot(auth.tick, actors.heroes, actors.enemies),
      commands = {},
    }
  end

  auth.tick = auth.tick + 1
  for _, frame in ipairs(inputs or {}) do
    auth.engine:PushInput(frame.playerId, frame)
  end

  if auth.stockRules then
    local actors = auth.engine:ReadActors()
    local room = actors.room
    if room ~= nil then
      assert(Room.valid(room), "invalid authoritative room projection")
      assert(not auth.roomId or room.id >= auth.roomId, "authoritative room instance regressed")
      auth.roomId = room.id
    end
    return {
      snapshot = Messages.snapshot(auth.tick, actors.heroes, actors.enemies, room),
      commands = {},
    }
  end

  local commands = {}
  if not auth.scaled then
    local multiplier = Scaling.hpMultiplier(Party.count(auth.party), auth.hpPerExtra)
    commands[#commands + 1] = { type = "ScaleEncounter", multiplier = multiplier }
    auth.scaled = true
  end

  for _, event in ipairs(auth.engine:PullEvents()) do
    if event.name == "HeroDown" then
      local produced = Death.onHeroDown(auth.party, event.playerId)
      for _, command in ipairs(produced) do
        commands[#commands + 1] = command
      end
    elseif event.name == "EnemyDied" then
      auth.lootContext.killerId = event.attackerId
      local playerId = Loot.assign(auth.party, auth.lootPolicy, auth.lootContext)
      if playerId then
        commands[#commands + 1] = {
          type = "OfferLoot",
          playerId = playerId,
          reward = { source = event.enemyId },
        }
      end
    end
  end

  Authority.apply(auth, commands)
  local actors = auth.engine:ReadActors()
  return {
    snapshot = Messages.snapshot(auth.tick, actors.heroes, actors.enemies),
    commands = commands,
  }
end

return Authority
