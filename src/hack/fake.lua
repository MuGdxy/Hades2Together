-- Stand-in world for tests. One enemy table, one health value.
-- The game binding will implement the same methods against the live process.

local Engine = import("hack/engine.lua")

local Fake = {}
Fake.__index = Fake

local function sortedById(map)
  local list = {}
  for _, actor in pairs(map) do
    list[#list + 1] = {
      id = actor.id,
      kind = actor.kind,
      hp = actor.hp,
      maxHp = actor.maxHp,
      x = actor.x,
      y = actor.y,
      alive = actor.alive,
    }
  end
  table.sort(list, function(a, b)
    return a.id < b.id
  end)
  return list
end

function Fake.new()
  local self = setmetatable({
    heroes = {},
    enemies = {},
    events = {},
    inputs = {},
    calls = {},
    heroContext = nil,
    focusTick = false,
    suppressed = false,
    camera = {},
    aggro = {},
    nextEnemy = 1,
    ended = nil,
    lastLoot = nil,
  }, Fake)
  return self
end

function Fake:BindHero(playerId, spec)
  spec = spec or {}
  local hp = spec.hp or 100
  self.heroes[playerId] = {
    id = playerId,
    hp = hp,
    maxHp = spec.maxHp or hp,
    x = spec.x or 0,
    y = spec.y or 0,
    alive = true,
  }
  return playerId
end

function Fake:spawnEnemy(kind, hp)
  local id = self.nextEnemy
  self.nextEnemy = id + 1
  self.enemies[id] = {
    id = id,
    kind = kind or "enemy",
    hp = hp,
    maxHp = hp,
    baseHp = hp,
    x = 0,
    y = 0,
  }
  return id
end

function Fake:damageEnemy(enemyId, amount, attackerId)
  local enemy = self.enemies[enemyId]
  if not enemy or enemy.hp <= 0 then
    return
  end
  enemy.hp = enemy.hp - amount
  if enemy.hp < 0 then
    enemy.hp = 0
  end
  self.events[#self.events + 1] = {
    name = "EnemyHit",
    enemyId = enemyId,
    amount = amount,
    attackerId = attackerId,
    hp = enemy.hp,
  }
  if enemy.hp == 0 then
    self.events[#self.events + 1] = {
      name = "EnemyDied",
      enemyId = enemyId,
      attackerId = attackerId,
    }
  end
end

function Fake:damageHero(playerId, amount)
  local hero = self.heroes[playerId]
  if not hero or not hero.alive then
    return
  end
  hero.hp = hero.hp - amount
  if hero.hp > 0 then
    return
  end
  hero.hp = 0
  hero.alive = false
  self.events[#self.events + 1] = {
    name = "HeroDown",
    playerId = playerId,
  }
end

function Fake:PushInput(playerId, frame)
  self.inputs[playerId] = frame
end

function Fake:ReadActors()
  return {
    heroes = sortedById(self.heroes),
    enemies = sortedById(self.enemies),
  }
end

function Fake:RunAsHero(playerId, fn)
  local previous = self.heroContext
  self.heroContext = playerId
  local ok, err = pcall(fn)
  self.heroContext = previous
  if not ok then
    error(err, 0)
  end
end

function Fake:SetCamera(playerIds)
  self.camera = playerIds
end

function Fake:SetAggroTargets(playerIds)
  self.aggro = playerIds
end

function Fake:SetFocusTick(enabled)
  self.focusTick = enabled and true or false
end

function Fake:ApplySnapshot(snapshot)
  for _, hero in ipairs(snapshot.heroes or {}) do
    local current = self.heroes[hero.id]
    if current then
      current.x = hero.x
      current.y = hero.y
      current.hp = hero.hp
      current.maxHp = hero.maxHp
      current.alive = hero.alive
    end
  end
  for _, enemy in ipairs(snapshot.enemies or {}) do
    local current = self.enemies[enemy.id]
    if current then
      current.x = enemy.x
      current.y = enemy.y
      current.hp = enemy.hp
      current.maxHp = enemy.maxHp
    end
  end
end

function Fake:SuppressLocalSim(enabled)
  self.suppressed = enabled and true or false
end

function Fake:Call(name, ...)
  local args = { ... }
  self.calls[#self.calls + 1] = {
    name = name,
    args = args,
    heroContext = self.heroContext,
  }
  if name == "ScaleEncounter" then
    local multiplier = args[1]
    for _, enemy in pairs(self.enemies) do
      local scaled = math.floor(enemy.baseHp * multiplier + 0.5)
      enemy.maxHp = scaled
      enemy.hp = scaled
    end
  elseif name == "OfferLoot" then
    self.lastLoot = {
      playerId = self.heroContext,
      reward = args[1],
    }
  elseif name == "EndRun" then
    self.ended = args[1]
  end
end

function Fake:PullEvents()
  local events = self.events
  self.events = {}
  return events
end

Engine.assert(Fake)
return Fake
