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
