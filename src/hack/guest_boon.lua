-- Ordinary new Poseidon traits. All actor-dependent reads use the attached
-- beneficiary. Only deterministic world-only requirements go back to retail.
local Guest = {}

local function randomStream(salt, room, offer, seat, round)
  local seed = 1
  for _, n in ipairs({ salt, room, offer, seat, round }) do
    for c in (tostring(n) .. "/"):gmatch(".") do seed = (seed * 131 + c:byte()) % 2147483647 end
  end
  seed = math.max(seed, 1)
  return function()
    seed = (seed * 48271) % 2147483647
    return (seed - 1) / 2147483646
  end
end

local function pick(list, random)
  return 1 + math.floor(random() * #list)
end

local function worldEligible(g, source, req)
  if not req then return true end
  for i, row in pairs(req) do
    assert(type(i) == "number" and type(row) == "table", "unsupported requirement")
    for k, value in pairs(row) do
      if k == "Path" or k == "PathTrue" or k == "PathFalse" then
        assert(value[1] == "GameState" or (value[1] == "CurrentRun" and value[2] == "CurrentRoom"),
          "requirement needs actor context")
      else
        assert(k == "Comparison" or k == "Value" or k == "HasNone" or k == "IsNone", "unsupported requirement")
      end
    end
    assert(not next(row) or row.Path or row.PathTrue or row.PathFalse, "missing requirement path")
  end
  local valid = g.IsGameStateEligible(source, req)
  assert(type(valid) == "boolean", "unknown world requirement")
  return valid
end

-- Same additive-then-multiplicative order as GetRarityChances. Its stock
-- trait helper uses the primary Hero's cache even when passed another Unit.
local function rarityChances(g, room, unit, source, previous)
  local config = assert(g.LootData[source.Name])
  local base = g.HeroData.BoonData.RarityChances or {}
  local overrides = previous and previous.chances or
    (not config.IgnoreRoomRarityBonus and room.BoonRaritiesOverride) or config.BoonRaritiesOverride or {}
  local chances = {}
  for rarity in pairs(g.TraitRarityData.RarityValues) do chances[rarity] = overrides[rarity] or base[rarity] or 0 end
  -- Retail rerolls carry the previous roll's chances and skip new bonuses.
  if previous or config.IgnoreAllRarityBonus then return chances end
  for _, key in ipairs({ "RarityBonus", "MultiplicativeRarityBonus" }) do
    for _, trait in ipairs(unit.Traits) do
      local bonus = trait[key]
      if bonus and (not config.IgnoreTempRarityBonus or trait.RemainingUses == nil)
        and (not bonus.RequiredGod or bonus.RequiredGod == source.Name)
        and (not bonus.GodLootOnly or source.GodLoot or source.TreatAsGodLootByShops) then
        for rarity, value in pairs(chances) do
          if bonus[rarity] then
            if key == "RarityBonus" then chances[rarity] = value + bonus[rarity]
            else chances[rarity] = value * bonus[rarity] end
          end
        end
      end
    end
  end
  return chances
end

local function hasDependencies(owned, req)
  if not req then return true end
  for key in pairs(req) do
    assert(key == "OneOf" or key == "TwoOf" or key == "OneFromEachSet" or key == "PriorityChance",
      "unsupported trait dependency")
  end
  local function matches(names)
    local n = 0
    for _, name in ipairs(names) do if owned[name] then n = n + 1 end end
    return n
  end
  if req.OneOf and matches(req.OneOf) > 0 or req.TwoOf and matches(req.TwoOf) >= 2 then return true end
  if not req.OneFromEachSet then return false end
  for _, set in ipairs(req.OneFromEachSet) do if matches(set) == 0 then return false end end
  return true
end

local function rarityPool(definitions, names, rarity)
  local indices = {}
  for i, name in ipairs(names) do
    local levels = definitions[name].RarityLevels
    if levels and levels[rarity] or not levels and rarity == "Common" then indices[#indices + 1] = i end
  end
  return indices
end

local function draw(g, run, source, unit, random, previous)
  local room, owned = run.CurrentRoom, unit.TraitDictionary
  assert(type(owned) == "table" and type(unit.Traits) == "table" and type(unit.BoonData) == "table",
    "missing beneficiary data")
  local firstRun = (room.ForceLootTableFirstRun or room.ForceCommonLootFirstRun)
    and g.TableLength(assert(g.GameState.RunHistory)) == 0
  assert(source.Name == "PoseidonUpgrade" and not source.StackOnly and not source.UpgradeOnPick
    and not source.TransformingTraits and not (room.ForcedReward and room.ForcedReward.ForcedUpgradeOptions)
    and not (room.ForceLootTableFirstRun and firstRun), "special loot")
  local maximum = g.GetTotalLootChoices()
  assert(type(maximum) == "number" and maximum > 0 and maximum % 1 == 0, "unknown choice count")
  local occupied, restricted = {}, false
  for _, trait in ipairs(unit.Traits) do
    if trait.Slot then occupied[trait.Slot] = true end
    if trait.RestrictBoonChoices ~= nil then restricted = true end
    assert(not (trait.ForceSwaps ~= nil and trait.Uses > 0), "forced swap")
  end
  local function eligible(name)
    local data = assert(g.TraitData[name], "unknown trait")
    if source.StripRequirements then return true end
    if run.BannedTraits[name] or data.BlockOfferIfPreviouslyPicked and run.PickedTraits[name] then return false end
    if data.MaxAmount and (owned[name] and (owned[name][1].StackNum or 1) or 0) >= data.MaxAmount then return false end
    if data.IsLegacyTrait and not worldEligible(g, data, g.TraitRarityData.LegacyGameStateRequirements) then return false end
    if data.IsElementalTrait and not worldEligible(g, data, g.TraitRarityData.ElementalGameStateRequirements) then return false end
    return worldEligible(g, data, data.GameStateRequirements)
  end
  local free, guaranteed, conflict = {}, {}, false
  local priority = assert(source.PriorityUpgrades, "missing priority pool")
  for _, name in ipairs(priority) do
    if eligible(name) then
      local slot = assert(g.TraitData[name].Slot, "unknown priority slot")
      if owned[name] or occupied[slot] then
        conflict = true
      else
        free[#free + 1] = name
        if slot == "Melee" or slot == "Secondary" then guaranteed[#guaranteed + 1] = name end
      end
    end
  end
  local common = unit.BoonData.ForceCommon or owned.ChaosCommonCurse
    and (source.GodLoot or source.TreatAsGodLootByShops) and not source.BlockForceCommon
  if room.BoonRaritiesOverride and unit.BoonData.AllowRarityOverride then common = false end
  if room.ForceCommonLootFirstRun and firstRun then common = true end
  local chances = common and {} or rarityChances(g, room, unit, source, previous)
  if conflict and not common and worldEligible(g, source, unit.BoonData.GameStateRequirements)
    and random() < unit.BoonData.ReplaceChance then error("exchange roll outside ordinary additions") end
  local chosen = free
  if conflict then
    chosen = #free > 0 and { free[pick(free, random)] } or {}
  else
    while #chosen > maximum do table.remove(chosen, pick(chosen, random)) end
    local needGuaranteed = #guaranteed > 0
    for _, name in ipairs(chosen) do
      local slot = g.TraitData[name].Slot
      if slot == "Melee" or slot == "Secondary" then needGuaranteed = false end
    end
    if needGuaranteed then chosen[1] = guaranteed[pick(guaranteed, random)] end
  end

  local traits = assert(source.Traits, "missing ordinary trait pool")
  local deps = assert(g.TraitRequirements, "missing trait dependencies")
  for _, name in ipairs(traits) do
    local data = assert(g.TraitData[name], "unknown trait")
    assert(not data.PriorityRequirements, "special priority trait")
    local req = deps[name]
    if #chosen < maximum and req and req.PriorityChance and not owned[name] and eligible(name)
      and hasDependencies(owned, req) and random() < req.PriorityChance then chosen[#chosen + 1] = name end
  end
  local excluded
  if previous and #previous.all > 0 then
    excluded = previous.all[pick(previous.all, random)]
    for i = #chosen, 1, -1 do if chosen[i] == excluded then table.remove(chosen, i) end end
  end
  local rarities = {}
  local order = source.RarityRollOrder or g.TraitRarityData.BoonRarityRollOrder
  for _, name in ipairs(chosen) do
    rarities[name] = "Common"
    local levels = g.TraitData[name].RarityLevels
    if not common and levels then
      for _, rarity in ipairs(order) do
        if levels[rarity] and chances[rarity] and random() < chances[rarity] then
          rarities[name] = rarity
        end
      end
    end
  end
  if #chosen < maximum then
    local pool, used = {}, {}
    for _, name in ipairs(chosen) do used[name] = true end
    local function add(name)
      if not used[name] and name ~= excluded and not owned[name] and eligible(name) then
        pool[#pool + 1], used[name] = name, true
      end
    end
    for _, name in ipairs(source.WeaponUpgrades) do
      if not occupied[g.TraitData[name].Slot] then add(name) end
    end
    for _, name in ipairs(traits) do if hasDependencies(owned, deps[name]) then add(name) end end
    while #chosen < maximum do
      local available = rarityPool(g.TraitData, pool, "Common")
      local chosenRarity = "Common"
      if not common then
        for _, rarity in ipairs(order) do
          local candidates = rarityPool(g.TraitData, pool, rarity)
          local chance = chances[rarity] or 0
          if #candidates > 0 and random() < chance then available, chosenRarity = candidates, rarity end
        end
      end
      assert(#available > 0, "exchange or rare-only refill")
      local name = table.remove(pool, available[pick(available, random)])
      chosen[#chosen + 1], rarities[name] = name, chosenRarity
    end
  end
  local options = { table.unpack(chosen) }
  if restricted and (source.GodLoot or source.TreatAsGodLootByShops) and not source.IgnoreRestrictBoonChoices then
    table.remove(options, pick(options, random))
  end
  return { options = options, all = chosen, chances = chances, rarities = rarities }
end

function Guest.roll(g, run, offer, unit, salt, room, seat, round, previous)
  local random = randomStream(salt, room, offer.id, seat, round)
  local ok, result = pcall(draw, g, run, offer.source, unit, random, previous)
  if ok then return result end
  return { reason = tostring(result) }
end

return Guest
