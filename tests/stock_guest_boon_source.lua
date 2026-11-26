-- Standalone retail candidate-source probe. Pass "grant" for the isolated
-- guest selection and original grant side-effect replay, or "unit-grant" for
-- the authority's actor-addressed grant.
local scripts = assert(arg[1], "pass the installed Content/Scripts directory")
local stock = setmetatable({
  Import = function() end, OnSpawn = function() end,
  AddIncomingDamageModifier = function() end,
  HeroData = { Weapons = {}, Traits = {}, TraitDictionary = {}, BoonData = {} },
  MetaUpgradeData = {
    EnemyDamageShrineUpgrade = { ChangeValue = 0 },
    BanUnpickedBoonsShrineUpgrade = { ChangeValue = 0 },
  },
  ScreenData = { UpgradeChoice = { MaxChoices = 3 } },
  TraitRarityData = { BoonRarityRollOrder = {}, RarityValues = { Common = 1 } },
  TraitData = {
    PoseidonWeaponBoon = { Name = "PoseidonWeaponBoon", Slot = "Melee" },
    PoseidonSpecialBoon = { Name = "PoseidonSpecialBoon", Slot = "Secondary" },
    PoseidonCastBoon = { Name = "PoseidonCastBoon", Slot = "Ranged" },
  },
  IsRarityForcedCommon = function() return true end,
  IsGameStateEligible = function() return false end, -- no exchange branch
}, { __index = _G })
for _, name in ipairs({ "UtilityLogic", "RunLogic", "TraitLogic", "UpgradeChoiceLogic" }) do
  assert(loadfile(scripts .. "/" .. name .. ".lua", "t", stock))()
end

local host = stock.CreateNewHero(nil, { WeaponName = "WeaponStaffSwing" })
local guest = stock.CreateNewHero(nil, { WeaponName = "WeaponStaffSwing" })
host.ObjectId, guest.ObjectId = 40000, 1000002
stock.CurrentRun = { Hero = host, CurrentRoom = {}, BannedTraits = {} }
local owned = { Name = "PoseidonWeaponBoon", Slot = "Melee", RestrictBoonChoices = true }
guest.Traits[1], guest.TraitDictionary[owned.Name] = owned, { owned }
local loot = { Name = "PoseidonUpgrade", GodLoot = true,
  PriorityUpgrades = { owned.Name, "PoseidonSpecialBoon", "PoseidonCastBoon" } }
if arg[2] ~= "unit-grant" then
  assert(stock.GetTotalTraitCount(guest) == 1 and stock.GetTotalTraitCount(host) == 0)
  local countAssertion
  stock.DebugAssert = function(args) countAssertion = args.Condition end
  assert(stock.GetTraitCount(guest, { Name = owned.Name }) == 0 and countAssertion == false)

  -- Three priority entries avoid random trimming and isolate the beneficiary lookup.
  stock.SetTraitsOnLoot(loot, { Unit = guest })
  assert(loot.UpgradeOptions[1].ItemName == owned.Name and #loot.UpgradeOptions == 3)
  assert(stock.CalcNumLootChoices(loot, { Unit = guest }) == 3)
  print("guest owns PoseidonWeaponBoon and restricts choices; retail roll with Unit=guest still offers it, limit=3")

  -- Even a helper that accepts Unit caches the lookup on the primary Hero.
  local key = "RestrictBoonChoices"
  assert(stock.GetHeroTraitValues(key, { Unit = guest })[1] == true)
  assert(host.HeroTraitValuesCache[key][1] == true and guest.HeroTraitValuesCache[key] == nil)
  assert(stock.GetHeroTraitValues(key)[1] == true and not stock.HasHeroTraitValue(key))
  assert(stock.CurrentRun.Hero == host)
  print("original trait-value lookup on guest populated host cache; CurrentRun.Hero stayed the host")
end

-- Feed that same owned/restricted Unit through the production room projection.
-- Use the installed Poseidon pool; the room fixture bans non-core fill traits.
stock.LootSetData, stock.Color, stock.GameData, stock.GlobalVoiceLines, stock.PresetEventArgs = {}, {}, {}, {}, {}
stock.LootData = {}
assert(loadfile(scripts .. "/LootData_Poseidon.lua", "t", stock))()
local source = stock.LootSetData.Poseidon.PoseidonUpgrade
source.ObjectId, source.Name, source.GodLoot = 909, "PoseidonUpgrade", true
source.UpgradeOptions = loot.UpgradeOptions
stock.TraitData.PoseidonSprintBoon = { Name = "PoseidonSprintBoon", Slot = "Rush" }
stock.TraitData.PoseidonManaBoon = { Name = "PoseidonManaBoon", Slot = "Mana" }
stock.TraitRequirements = {}
for _, name in ipairs(source.Traits) do
  stock.TraitData[name] = { Name = name }
  stock.CurrentRun.BannedTraits[name] = true
end
local globalRngCalls = 0
stock.GetGlobalRng = function()
  globalRngCalls = globalRngCalls + 1
  error("guest draw touched stock RNG")
end
local room = { Name = "F_Reprieve01", Encounter = { Name = "HealthRestore" }, SpawnRewardOnId = 55 }
stock.CurrentRun.CurrentRoom = room
stock.SessionState, stock.SessionMapState = { MapLoads = 1 }, { DeferredObstacleInitializationFinished = true }
stock.MapState = { RewardPointsUsed = { [55] = 909 }, RoomRequiredObjects = { [909] = source } }
stock.LootObjects = { [909] = source }
stock.IdExists = function(args) return args.Id == 909 end
stock.IsUseable, stock.GetName = stock.IdExists, function() return source.Name end
local other = stock.CreateNewHero(nil, { WeaponName = "WeaponStaffSwing" })
other.ObjectId = 1000003
stock.HeroData.BoonData.RarityChances = { Rare = 0.1 }
stock.TraitRarityData.RarityValues.Rare = 1
stock.TraitRarityData.BoonRarityRollOrder = { "Common", "Rare" }
guest.BoonData.GameStateRequirements = { { Path = { "GameState", "CompletedRunsCache" }, Comparison = ">=", Value = 2 } }
guest.BoonData.ReplaceChance = 0.1
owned.RarityBonus = { RequiredGod = "PoseidonUpgrade", Rare = 0.25 }
local units = { [2] = guest, [3] = other }
local native = { h2t_guest_capacity = true, h2t_guest_actor = function(seat)
  local actor = units[seat]
  return { actor = actor, id = actor.ObjectId, load = 1 }
end }
local env = setmetatable({ rom = { game = stock, data = native } }, { __index = _G })
local modules = {}
function env.import(path)
  if not modules[path] then modules[path] = assert(loadfile("src/" .. path, "t", env))() end
  return modules[path]
end
local Session, Game, Adapter = env.import("protocol/session.lua"), env.import("hack/game.lua"), env.import("hack/stock_boon.lua")
local function makeGame()
  source.UpgradeOptions = loot.UpgradeOptions
  local session = Session.new("serve+play")
  for seat = 1, 3 do assert(Session.join(session, "player" .. seat, seat)) end
  local game = Game.new(session, 1)
  game.guestBoonSeed = 7931
  game:OnMap(room.Name)
  game.guestInputs = {}
  for seat, actor in pairs(units) do
    game.guestInputs[seat] = { hero = host, room = room, load = 1, actor = actor, id = actor.ObjectId }
  end
  return game, session
end

if arg[2] == "grant" or arg[2] == "unit-grant" then
  local name = "PoseidonWeaponBoon"
  stock.TraitSetData = {}
  stock.LootData.TrialUpgrade = { PermanentTraits = {} }
  stock.ToLookup = function(names)
    local keys = {}
    for _, key in ipairs(names) do keys[key] = true end
    return keys
  end
  stock.WeaponSets = { HeroPrimaryWeapons = { "WeaponStaffSwing" }, HeroAllWeaponsAndSprint = {} }
  assert(loadfile(scripts .. "/TraitData.lua", "t", stock))()
  assert(loadfile(scripts .. "/TraitData_Poseidon.lua", "t", stock))()
  stock.TraitData[name].Name = name
  -- One actual priority entry; deterministic opportunity for the empty third Unit.
  source.PriorityUpgrades = { name }
  stock.ScreenData.UpgradeChoice.MaxChoices = 1
  stock.HeroData.BoonData.RarityChances.Rare = 1
  local game = makeGame()
  game:ReadActors()
  stock.HeroData.BoonData.RarityChances.Rare = 0
  local token, item = game:SelectBoon(1, 1, 3, name)
  assert(token and item.Type == "Trait" and item.ItemName == name and item.Rarity == "Rare")
  item.Rarity = "Epic"
  local repeated, retained = game:SelectBoon(1, 1, 3, name)
  assert(token == repeated and retained.Rarity == "Rare" and game:BoundGuestUnit(3) == other)

  if arg[2] == "unit-grant" then
    local reward = game.roomLoad.boonOffer.reward
    local entry = reward.seats[3]
    stock.GameState = { TraitsTaken = {} }
    local hostTrait = { Name = name, Slot = "Melee", Rarity = "Common", StackNum = 2, Id = "host-owned" }
    host.Traits[1], host.TraitDictionary[name] = hostTrait, { hostTrait }
    local function commit()
      return game:GrantGuestBoon(1, 1, 3, token)
    end
    assert(not game:GrantGuestBoon(1, 1, 2, token))
    units[3] = guest
    assert(not commit() and entry.pending == token and #other.Traits == 0)
    units[3] = other

    -- Refuse at the real receipt boundary after insertion. Retry must see a
    -- completely unoccupied Unit, even if SlottedTraits did not exist before.
    local oldSlots = other.SlottedTraits
    reward.seats[2].instanceId = "h2t/1/1/3/" .. other.ObjectId
    local failed, reason = commit()
    assert(not failed and reason == "grant not confirmed" and entry.pending == token and not entry.consumed)
    assert(#other.Traits == 0 and not other.TraitDictionary[name] and other.SlottedTraits == oldSlots)
    reward.seats[2].instanceId = nil

    local id = assert(commit())
    local added = assert(other.Traits[1])
    assert(added.Name == name and added.Rarity == "Rare" and added.Id == id and added ~= hostTrait)
    assert(added.RarityMultiplier == 1.25 and added.OnEnemyDamagedAction.Args.DamageMultiplier == 1.25)
    assert(other.TraitDictionary[name][1] == added and other.SlottedTraits.Melee == name)
    assert(stock.GetTraitCount(other, { TraitData = added }) == 1 and stock.GetTotalTraitCount(other) == 1)
    assert(commit() == id and #other.Traits == 1 and #other.TraitDictionary[name] == 1)
    assert(not game:GrantGuestBoon(1, 1, 3, { seat = 3 }))
    assert(host.Traits[1] == hostTrait and #host.Traits == 1 and host.TraitDictionary[name][1] == hostTrait
      and hostTrait.Rarity == "Common" and hostTrait.StackNum == 2 and not stock.GameState.TraitsTaken[name])
    assert(entry.consumed == name and entry.rarity == added.Rarity and entry.instanceId == added.Id)
    local claims = game:ReadActors().room.rewards[1].claims
    for _, claim in ipairs(claims) do
      assert((claim.state == "consumed") == (claim.playerId == 3))
    end
    assert(claims[#claims].playerId == 3 and claims[#claims].choice == name)
    print("bound guest " .. other.ObjectId .. " granted " .. name .. " Rare x1, id=" .. id
      .. "; stale binding refused, failed confirmation rolled back, retry returned the same ID")
    return
  end

  -- The engine supplies base damage for the tooltip and a random suffix for
  -- the stock instance ID. Neither leaf supplies the trait or its rarity.
  stock.GameState, stock.ActiveScreens = { TraitsTaken = {} }, {}
  stock.GetBaseDataValue = function(args)
    assert(args.Name == "PoseidonSplashSplinter" and args.Property == "Damage")
    return 1
  end
  stock._worldTime = 10
  stock.RandomFloat = function(low, high) assert(low == 0 and high == 1); return 0.5 end
  stock.DebugAssert = function(args) assert(args.Condition, args.Text) end
  assert(#host.Traits == 0 and #other.Traits == 0 and not stock.GameState.TraitsTaken[name])
  local ok, reason = pcall(stock.AddTrait, game:BoundGuestUnit(3), retained.ItemName, retained.Rarity,
    { SkipQuestStatusCheck = true })
  assert(not ok and tostring(reason):find("Cannot run GetTraitCount on non-hero units", 1, true), tostring(reason))
  assert(stock.GameState.TraitsTaken[name] == true and #host.Traits == 0)
  assert(#other.Traits == 1 and other.Traits[1].Name == name and other.Traits[1].Rarity == "Rare"
    and other.Traits[1].RarityMultiplier == stock.TraitData[name].RarityLevels.Rare.Multiplier)
  local reward = game.roomLoad.boonOffer.reward
  assert(reward.seats[3].pending == token and not reward.seats[3].consumed)
  reward.guests[3].rolls[1].rarities = nil -- retained pre-upgrade opportunity
  local prior, unknown = game:SelectBoon(1, 1, 3, name)
  assert(prior == token and unknown == nil)
  print("seat 3 retained " .. name .. " Rare; original AddTraitData marked shared TraitsTaken before non-hero count assertion; no confirmed receipt")
  return
end

local function sample(first, second)
  local game, session = makeGame()
  local function options(seat)
    local view = game:ReadActors().room
    assert(env.import("protocol/room.lua").valid(view))
    local claim = view.rewards[1].claims[seat]
    assert(claim.playerId == seat and claim.state == "eligible")
    return table.concat(claim.options, ",")
  end
  local a, b = options(2), options(3)
  local members = game.roomLoad.boonOffer.reward.guests
  assert(members[2].rolls[1].chances.Rare == 0.35 and members[3].rolls[1].chances.Rare == 0.1)
  assert(options(1):find(owned.Name, 1, true))
  assert(not a:find(owned.Name, 1, true) and select(2, a:gsub(",", "")) == 1)
  assert(select(2, b:gsub(",", "")) == 2)
  if first == 2 then print("first roll: host=" .. options(1) .. " guest2=" .. a .. " guest3=" .. b) end
  assert(Session.release(session, 2))
  assert(options(2) == a and Session.join(session, "player2") == 2)
  source.UpgradeOptions = { { Type = "Trait", ItemName = "PoseidonCastBoon" } }
  assert(options(2) == a and options(3) == b)
  local function reroll(seat, round)
    return Adapter.onGuestReroll(game, stock, game.roomLoad, 1, seat, units[seat], round)
  end
  assert(not reroll(first, 3) and reroll(first, 2))
  assert(options(second) == (second == 2 and a or b))
  local drawn = options(first)
  assert(reroll(first, 2) and options(first) == drawn and reroll(second, 2))
  local seat2, seat3 = options(2), options(3)
  -- The next certified round has a rule that cannot be evaluated for the
  -- guest. Keep its result unknown without publishing the previous round.
  stock.TraitData.PoseidonManaBoon.GameStateRequirements = { { PathTrue = { "CurrentRun", "Hero", "IsDead" } } }
  assert(reroll(2, 3))
  stock.TraitData.PoseidonManaBoon.GameStateRequirements = nil
  local claims = game:ReadActors().room.rewards[1].claims
  assert(#claims == 2 and claims[1].playerId == 1 and claims[2].playerId == 3)
  assert(table.concat(claims[2].options, ",") == seat3)
  return seat2, seat3
end
local a, b = sample(2, 3)
local c, d = sample(3, 2)
assert(a == c and b == d and globalRngCalls == 0)
print("guest candidates reached room claims; occupied melee, restriction, reconnect and independent roll order passed")
