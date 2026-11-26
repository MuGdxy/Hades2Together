-- Execute installed DamageEnemy -> CheckOnDamagedPowers -> CheckPoseidonSplash.
-- Only the binding, scene, damage event and engine/presentation leaves are fixtures.
local scripts = assert(arg[1], "pass the installed Content/Scripts directory")
local function noop() end
local stock = setmetatable({}, { __index = function(_, key)
  if key:match("^On%u") then return noop end -- engine registration
  return _G[key]
end })
stock._G, stock.Import, stock.Color = stock, noop, {}
stock.TraitData, stock.TraitSetData, stock.LootData = {}, {}, { TrialUpgrade = { PermanentTraits = {} } }
stock.ToLookup = function(list)
  local lookup = {}
  for _, value in ipairs(list) do lookup[value] = true end
  return lookup
end
for _, script in ipairs({ "UtilityLogic", "EventLogic", "WeaponSets", "WeaponLogic", "TraitLogic",
    "TraitData", "TraitData_Poseidon", "CombatLogic", "PowersLogic" }) do
  assert(loadfile(scripts .. "/" .. script .. ".lua", "t", stock))()
end
local function actor(id)
  return { ObjectId = id, TraitDictionary = {}, Traits = {}, HeroTraitValuesCache = {
    CustomExDefinitions = {}, AddWeaponsToTraits = {}, AddSummonWeaponsToTraits = {}, OnDamageEnemyFunction = {},
  } }
end
local host, guest, bare = actor(40000), actor(1000002), actor(1000003)
local room = { Name = "F_Combat01", Encounter = {} }
local victim = { ObjectId = 81, TriggersOnDamageEffects = true, MaxHealth = 100, Health = 100,
  EarlyExit = true, SkipDamageText = true, SkipDamagePresentation = true }
stock.CurrentRun = { Hero = host, CurrentRoom = room }
stock.MapState, stock.ActiveEnemies = { SpellSummons = {} }, { [81] = victim }
stock.SessionState = { MapLoads = 1, GlobalCooldowns = {}, GlobalCounts = {} }
stock.SessionMapState = { FirstHitRecord = {}, ExProjectileIds = {} }
stock.WeaponData, stock.ProjectileData = {}, {}
stock.WeaponSetLookups, stock._worldTime = { HeroSpellWeapons = {} }, 10
stock.UpdateHealthBar = noop
stock.thread = function(fn, ...) return assert(coroutine.resume(coroutine.create(fn), ...)) end
local shots = {}
stock.CreateProjectileFromUnit = function(args) shots[#shots + 1] = args end

local weapon, special = "PoseidonWeaponBoon", "PoseidonSpecialBoon"
for _, name in ipairs({ weapon, special }) do
  local data = stock.TraitData[name]
  data.Name = name
  -- RunData prepares these lookups at boot. Exercise the two base staff weapons.
  local action = data.OnEnemyDamagedAction
  action.ValidWeaponsLookup = stock.ToLookup(action.ValidWeapons)
  for _, key in ipairs({ "MultihitWeaponWhitelist", "MultihitProjectileWhitelist" }) do
    action.Args[key .. "Lookup"] = stock.ToLookup(action.Args[key])
  end
end
local function equip(unit, name, rarity)
  local trait = stock.GetProcessedTraitData({ Unit = unit, TraitName = name, StackNum = 1, Rarity = rarity })
  unit.Traits[#unit.Traits + 1], unit.TraitDictionary[name] = trait, { trait }
end
equip(host, weapon, "Common")
equip(guest, weapon, "Rare")
host.Traits[2] = { ConeModifier = { ScaleIncrease = 2 } }

-- Count admission before the stock splash cooldown can mask a second call.
local admissions, recordHit = {}, stock.ProjectileRecordUnitHit
stock.ProjectileRecordUnitHit = function(id, key)
  if key == "CheckPoseidonSplash" then admissions[id] = (admissions[id] or 0) + 1 end
  return recordHit(id, key)
end

local units = { [2] = guest, [3] = bare }
local env = setmetatable({ rom = { game = stock, log = { warning = error }, data = {
  h2t_guest_capacity = true, h2t_guest_actor = function(seat)
    return { actor = units[seat], id = units[seat].ObjectId, load = 1 }
  end,
} } }, { __index = _G })
local modules = {}
function env.import(path)
  if not modules[path] then modules[path] = assert(loadfile("src/" .. path, "t", env))() end
  return modules[path]
end
local Session = env.import("protocol/session.lua")
local session = Session.new("serve+play")
local game = env.import("hack/game.lua").new(session, 1)
game.guestInputs = {}
for seat, unit in pairs(units) do
  assert(Session.join(session, "Guest" .. seat, seat))
  game.guestInputs[seat] = { actor = unit, id = unit.ObjectId, hero = host, room = room, load = 1,
    slot = session.slots[seat], session = session }
end
game:Install()
local installed = stock.CheckOnDamagedPowers
game:Install()
assert(stock.CheckOnDamagedPowers == installed)
local function hit(unit, id, weapon, attackerId, projectile)
  stock.DamageEnemy(victim, { Victim = victim, AttackerTable = unit, AttackerId = attackerId or unit.ObjectId,
    SourceWeapon = weapon or "WeaponStaffSwing", ProjectileId = id, SourceProjectile = projectile or "ProjectileStaffSwing1",
    DamageAmount = 1, ImpactAngle = 30 })
end
local function shot(index, unit, multiplier, scale)
  local p = assert(shots[index])
  assert(p.Id == unit.ObjectId and p.Name == "PoseidonSplashSplinter" and p.DestinationId == victim.ObjectId)
  assert(p.DamageMultiplier == multiplier and p.ScaleMultiplier == scale and p.Angle == 30)
end
hit(bare, 102)
hit(guest, 103, "WeaponStaffBall")
hit(guest, 104, nil, bare.ObjectId)
hit(guest, 107, nil, nil, "PoseidonSplashSplinter")
assert(#shots == 0)
hit(host, 101)
shot(1, host, 1, 2)
assert(Session.release(session, 2)) -- an already emitted hit still has its world owner
equip(guest, special, "Rare")
hit(guest, 105)
shot(2, guest, 1.25, 1)
assert(admissions[105] == 1 and #shots == 2)
stock._worldTime = stock._worldTime + 1
hit(guest, 108, "WeaponStaffBall", nil, "ProjectileStaffBall")
shot(3, guest, 1.5, 1)
assert(admissions[108] == 1 and #shots == 3)
stock._worldTime = stock._worldTime + 1
hit(guest, 105) -- original per-projectile repeat rule
assert(#shots == 3)
table.remove(guest.Traits, 1)
guest.TraitDictionary[weapon] = nil
hit(guest, 109, "WeaponStaffBall", nil, "ProjectileStaffBall")
shot(4, guest, 1.5, 1)
units[2] = bare -- cached actor still exists, native binding no longer matches
hit(guest, 106, "WeaponStaffBall", nil, "ProjectileStaffBall")
assert(not admissions[106] and #shots == 4 and stock.CurrentRun.Hero == host)
print("retail damage thread: guest 1000002 with both Rare boons, staff swing (105) x1.25 and staff special (108) x1.50, one admission and one splash each on victim 81; special-only also passed")
