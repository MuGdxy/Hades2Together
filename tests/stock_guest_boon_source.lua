-- Standalone retail candidate-source probe. No menu, session or grant.
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
assert(stock.GetTotalTraitCount(guest) == 1 and stock.GetTotalTraitCount(host) == 0)
local countAssertion
stock.DebugAssert = function(args) countAssertion = args.Condition end
assert(stock.GetTraitCount(guest, { Name = owned.Name }) == 0 and countAssertion == false)

-- Three priority entries avoid random trimming and isolate the beneficiary
-- lookup. The same trait is already owned and its slot occupied on the guest.
local loot = { Name = "PoseidonUpgrade", GodLoot = true,
  PriorityUpgrades = { owned.Name, "PoseidonSpecialBoon", "PoseidonCastBoon" } }
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
local function sample(first, second)
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
