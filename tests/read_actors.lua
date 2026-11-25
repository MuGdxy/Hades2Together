local environment = setmetatable({}, { __index = _G })
local modules = {}

function environment.import(path)
  if not modules[path] then
    modules[path] = assert(loadfile("src/" .. path, "t", environment))()
  end
  return modules[path]
end

local function unit(id, hp, maxHp)
  return { ObjectId = id, Health = hp, MaxHealth = maxHp }
end

local hero = unit(40000, 30, 40)
local brawler = unit(12, 6, 255)
local guard = unit(21, 60, 60)
local team = { 21, 12, 21, 40000, 30, 31, 32, 33, 34, 35, 36, 37 }
local names = { [40000] = "_PlayerUnit", [12] = "Brawler", [21] = "Guard",
  [31] = "RemovedGuard", [32] = "Guard", [33] = "Guard", [34] = "Guard", [36] = "Guard", [37] = "Guard" }
local alive = { [40000] = true, [12] = true, [21] = true, [31] = false,
  [32] = true, [33] = true, [34] = true, [35] = true, [36] = true, [37] = true }
local game = {
  CurrentRun = { CurrentRoom = { Name = "F_Combat01" }, Hero = hero },
  ActiveEnemies = {
    [21] = guard, [12] = brawler, [40000] = hero,
    [30] = unit(30, 0, 0), -- Props can be registered by stock SetupUnit.
    [31] = unit(31, 60, 60), -- The engine has stopped reporting it alive.
    [32] = { ObjectId = 32, Health = 0, MaxHealth = 60, IsDead = true },
    [33] = unit(999, 60, 60), -- Stale table under a different engine ID.
    [34] = unit(34, math.huge, 60),
    [35] = unit(35, 60, 60), -- Location can default even if the ID no longer exists.
    [36] = unit(36, 60, 60), -- Invalid position.
    [37] = unit(37, -1, 60),
    [99] = unit(99, 15, 15), -- Tracked but outside EnemyTeam.
  },
  GetIds = function(args)
    assert(args.Name == "EnemyTeam")
    return team
  end,
  GetName = function(args) return names[args.Id] end,
  IsAlive = function(args) return alive[args.Id] end,
  GetLocation = function(args)
    return { X = args.Id == 36 and math.huge or args.Id + 0.5, Y = -2 }
  end,
  GetAngle = function(args)
    return args.Id == 21 and math.huge or 0
  end,
}
environment.rom = { game = game }
local capture = environment.import("hack/game.lua").new({ slots = { [2] = { connected = true } } })
local Codec = environment.import("protocol/codec.lua")
local Messages = environment.import("protocol/messages.lua")

local first = capture:ReadActors()
assert(#first.heroes == 1 and #first.enemies == 2)
assert(first.heroes[1].id == 40000 and first.heroes[1].hp == 30 and first.heroes[1].maxHp == 40)
assert(first.heroes[1].facing == 0 and first.heroes[1].alive)
assert(first.enemies[1].id == 12 and first.enemies[1].kind == "Brawler")
assert(first.enemies[1].x == 12.5 and first.enemies[1].y == -2 and first.enemies[1].hp == 6)
assert(first.enemies[2].id == 21 and first.enemies[2].facing == nil)
assert(first.enemies[1].action == nil and first.enemies[1].phase == nil and first.enemies[1].actionInstance == nil)
local encoded = Codec.encode(Messages.snapshot(1, first.heroes, first.enemies))
local restored = assert(Codec.decode(encoded))
assert(restored.heroes[1].id == 40000 and restored.enemies[2].id == 21)

team[1], team[2] = team[2], team[1]
local reordered = capture:ReadActors()
assert(Codec.encode(Messages.snapshot(1, reordered.heroes, reordered.enemies)) == encoded)

hero.Health = 0
hero.IsDead = true
game.ActiveEnemies[12] = nil
team = { 21, 12 }
local nextView = capture:ReadActors()
assert(#nextView.enemies == 1 and nextView.enemies[1].id == 21)
assert(nextView.heroes[1].hp == 0 and nextView.heroes[1].alive == false)
assert(first.heroes[1].hp == 30 and first.heroes[1].alive and #first.enemies == 2)

team = {}
assert(#capture:ReadActors().enemies == 0)
names[40000] = nil
assert(#capture:ReadActors().heroes == 0)
game.CurrentRun = nil
local empty = capture:ReadActors()
assert(#empty.heroes == 0 and #empty.enemies == 0)

print("live actor projection passed")
