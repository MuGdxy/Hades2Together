-- Translate the retail single-hero choice and AddTraitData return into
-- authority data. Menu objects never leave this adapter.
local Boon = import("gameplay/boon.lua")
local GuestBoon = import("hack/guest_boon.lua")
local Session = import("protocol/session.lua")
local Messages = import("protocol/messages.lua")
local Stock = {}
local guestGrantSlots = { PoseidonWeaponBoon = "Melee", PoseidonSpecialBoon = "Secondary" }

function Stock.readHeld(unit)
  if type(unit.Traits) ~= "table" then return end
  local held = {}
  for _, trait in pairs(unit.Traits) do
    if type(trait) ~= "table" then return end
    if guestGrantSlots[trait.Name] then
      -- Retail GetTraitCount(unit, { TraitData = trait }) defaults an unset StackNum to one.
      local stacks = trait.StackNum
      if stacks == nil then stacks = 1 end
      if not Messages.validTick(stacks) or stacks < 1 or type(trait.Rarity) ~= "string"
        or not trait.Rarity:match("^[%w_]+$") then return end
      held[#held + 1] = { name = trait.Name, rarity = trait.Rarity, stacks = stacks }
    end
  end
  table.sort(held, function(a, b) return a.name < b.name end)
  return held
end

function Stock.guestGrantRound(reward, seat, option)
  local member = reward.guests and reward.guests[seat]
  local entry = reward.seats and reward.seats[seat]
  if not guestGrantSlots[option] or not member or not entry or entry.slot ~= member.slot or not member.slot.connected
    or (entry.selected and entry.selected ~= option) or (entry.consumed and entry.consumed ~= option) then return end
  local roll = member.rolls[member.round]
  if roll and roll.rarities and roll.rarities[option] then
    for _, offered in ipairs(entry.options or {}) do
      if offered == option then return member.round end
    end
  end
end

-- Includes an anchored offer retained from a plugin version that stored
-- receipts only after consumption.
function Stock.reward(load, id)
  local offer = load.boonOffer
  if id and (not offer or offer.id ~= id) then
    for _, reward in ipairs(load.boonClaims or {}) do
      if reward.id == id then return reward end
    end
    return
  end
  if not offer then return end
  if offer.reward then return offer.reward end
  load.boonClaims = load.boonClaims or {}
  for _, prior in ipairs(load.boonClaims) do
    if prior.id == offer.id and prior.encounterId == offer.encounterId then
      offer.reward = prior
      return prior
    end
  end
  offer.reward = { id = offer.id, kind = "PoseidonUpgrade", encounterId = offer.encounterId }
  load.boonClaims[#load.boonClaims + 1] = offer.reward
  return offer.reward
end

function Stock.current(g, load)
  local offer = load and load.boonOffer
  if not offer or load.room.Leaving or load.room.Encounter ~= offer.encounter then return end
  local source, map = offer.source, g.MapState
  if source.Name == "PoseidonUpgrade" and source.ObjectId == offer.objectId
    and map and map.RoomRequiredObjects and map.RoomRequiredObjects[offer.objectId] == source
    and map.RewardPointsUsed and map.RewardPointsUsed[load.room.SpawnRewardOnId] == offer.objectId then
    return offer
  end
end

-- After stock pickup the world object is gone. Only the confirmed host
-- receipt can keep the original guests' rolls available in this encounter.
local function available(game, g, load, reward)
  local offer = Stock.current(g, load)
  if offer and offer.reward == reward then return true, offer end
  local host = reward.seats and reward.seats[game.hostSeat]
  return not load.room.Leaving and reward.encounterId ~= nil
    and load.encounters[load.room.Encounter] == reward.encounterId
    and host and host.slot == game.session.slots[game.hostSeat] and host.consumed and host.instanceId ~= nil
end

local function choiceScreen(g, source)
  local screen = g.ScreenAnchors and g.ScreenAnchors.ChoiceScreen
  if screen and g.ActiveScreens and g.ActiveScreens[screen.Name] == screen
    and screen.Source == source and g.CurrentLootData == source then return screen end
end

local function generatedOptions(g, offer)
  local source = offer.source
  local items = source.UpgradeOptions
  if type(items) ~= "table" or source.StackOnly or source.UpgradeOnPick then return end
  local ok, limit = pcall(g.CalcNumLootChoices, source)
  if not ok or type(limit) ~= "number" or limit % 1 ~= 0 or limit < 0 then return end

  local count, marked = 0, 0
  for index, item in pairs(items) do
    if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #items
      or type(item) ~= "table" then return end
    count = count + 1
    if item.Blocked then marked = marked + 1 end
  end
  if count ~= #items then return end

  -- Retail draws blocked indices before sorting, then marks the sorted loot
  -- rows as each button is built. LogUpgradeChoice reads those same rows.
  local screen = choiceScreen(g, source)
  if screen then
    offer.locksObserved = false
    if type(screen.BlockedIndexes) == "table" then
      local lockedCount = 0
      -- RemoveRandomValue removes a key without compacting after its last draw.
      for _, index in pairs(screen.BlockedIndexes) do
        if not items[index] or not items[index].Blocked then return end
        lockedCount = lockedCount + 1
      end
      if lockedCount > 0 and lockedCount >= count - limit then
        offer.locksObserved = true
      end
    end
  end
  if limit == 0 then return {} end
  if count > limit and (not offer.locksObserved or marked < count - limit) then return end
  local options = {}
  for _, item in ipairs(items) do
    if item.Type == "Trait" and not item.Blocked and not item.TraitToReplace then
      options[#options + 1] = item.ItemName
    end
  end
  return options
end

local function rollGuest(game, g, load, offer, seat, member, round)
  local previous = member.rolls[round - 1]
  member.rolls[round] = GuestBoon.roll(g, g.CurrentRun, offer, member.unit,
    game.guestBoonSeed or 1, load.id, seat, round, previous)
  member.round = round
end

function Stock.openGuests(game, g, load)
  if not game.session or not Session.isAuthority(game.session) then return end
  local offer = Stock.current(g, load)
  if not offer then return end
  local reward = Stock.reward(load)
  if reward.guests then return end
  reward.guests = {}
  for seat, slot in pairs(game.session.slots) do
    local unit = game:BoundGuestUnit(seat)
    if unit then
      local member = { slot = slot, unit = unit, actorId = unit.ObjectId, rolls = {} }
      reward.guests[seat] = member
      rollGuest(game, g, load, offer, seat, member, 1)
    end
  end
end

-- Authority event boundary for an already accepted beneficiary-specific
-- reroll. Opening the stock screen or replacing the host list never calls it.
function Stock.onGuestReroll(game, g, load, rewardId, seat, unit, round)
  if not game.session or not Session.isAuthority(game.session) or not g.CurrentRun
    or game:LoadedRoom(g.CurrentRun.CurrentRoom) ~= load then return false end
  local offer = Stock.current(g, load)
  if not offer or offer.id ~= rewardId then return false end
  local reward = offer.reward
  local member = reward and reward.guests and reward.guests[seat]
  if not member or member.slot ~= game.session.slots[seat] or member.unit ~= unit
    or unit.ObjectId ~= member.actorId or game:BoundGuestUnit(seat) ~= unit then return false end
  if member.rolls[round] then return true end
  local entry = reward.seats and reward.seats[seat]
  if round ~= member.round + 1 or not member.rolls[member.round].all or (entry and entry.consumed) then return false end
  Boon.withholdOptions(reward, seat)
  rollGuest(game, g, load, offer, seat, member, round)
  return true
end

function Stock.readOptions(game, g, load, reward)
  if not game.session or not Session.isAuthority(game.session) then return end
  reward = reward or Stock.reward(load)
  if not reward then return end
  local allowed, offer = available(game, g, load, reward)
  if not allowed then return end
  for seat, member in pairs(reward.guests or {}) do
    local options = member.rolls[member.round].options
    if options and member.slot == game.session.slots[seat] and member.unit.ObjectId == member.actorId
      and game:BoundGuestUnit(seat) == member.unit then
      Boon.setOptions(game.session, reward, seat, member.actorId, options)
    else
      Boon.withholdOptions(reward, seat)
    end
  end
  if not offer then return reward end
  local run = g.CurrentRun
  if offer.candidates ~= offer.source.UpgradeOptions then
    if offer.reward then Boon.withholdOptions(offer.reward, game.hostSeat) end
    offer.candidates, offer.locksObserved = offer.source.UpgradeOptions, false
  end
  if run and run.CurrentRoom == load.room and run.Hero and run.Hero.ObjectId
    and game:BindHero(game.hostSeat) == run.Hero.ObjectId then
    local options = generatedOptions(g, offer)
    if options and Boon.setOptions(game.session, reward, game.hostSeat, run.Hero.ObjectId, options) then
      return reward, offer
    end
  end
  if offer.reward then Boon.withholdOptions(offer.reward, game.hostSeat) end
  return reward
end

local function remember(players, slot, trait)
  players[slot] = players[slot] or {}
  table.insert(players[slot], trait)
end

-- An upgrade can still recover confirmed receipts while their old Unit exists.
local function confirmedHolding(game, run, seat, entry, member)
  local state = game.guestInputs and game.guestInputs[seat]
  local name, slot = entry.consumed, guestGrantSlots[entry.consumed]
  if not slot or not member or not state or state.hero ~= run.Hero or state.room ~= game.roomLoad.room
    or state.actor ~= member.unit or entry.actor ~= member.unit.ObjectId
    or entry.slot ~= member.slot or member.slot ~= game.session.slots[seat] then return end
  local unit = member.unit
  local owned = unit.TraitDictionary and unit.TraitDictionary[name]
  if not owned or not unit.SlottedTraits or unit.SlottedTraits[slot] ~= name then return end
  for _, trait in ipairs(unit.Traits or {}) do
    if owned[1] == trait and trait.Id == entry.instanceId and trait.Name == name
      and trait.Rarity == entry.rarity and trait.Slot == slot then return trait end
  end
end

-- LeaveRoom changes CurrentRun.CurrentRoom; StartNewRun creates a new CurrentRun.
-- The reserved roster slot survives disconnects. Neither ObjectId nor the
-- connection generation identifies the owner of a run's inventory.
function Stock.runHoldings(game, run)
  local held = game.guestBoonHoldings
  if held and held.run == run and held.session == game.session then return held.players end
  local players = {}
  if not held and run and game.roomLoad and game.session then
    for _, reward in ipairs(game.roomLoad.boonClaims or {}) do
      for seat, entry in pairs(reward.seats or {}) do
        local trait = confirmedHolding(game, run, seat, entry, reward.guests and reward.guests[seat])
        if trait then remember(players, entry.slot, trait) end
      end
    end
  end
  game.guestBoonHoldings = { run = run, session = game.session, players = players }
  return players
end

local function availableSlot(unit, host, name, slot, id)
  local traits, dictionary, slots = unit.Traits, unit.TraitDictionary, unit.SlottedTraits
  if type(traits) ~= "table" or type(dictionary) ~= "table" or (slots ~= nil and type(slots) ~= "table")
    or traits == host.Traits or dictionary == host.TraitDictionary or (slots and slots == host.SlottedTraits) then
    return nil, "missing private trait storage"
  end
  if dictionary[name] or (slots and slots[slot]) then return nil, slot:lower() .. " slot occupied" end
  for _, owned in pairs(traits) do
    if owned.Slot == slot or owned.Name == name or owned.Id == id then return nil, "trait conflict" end
  end
  return true
end

local function insertTrait(unit, trait)
  local index = #unit.Traits + 1
  rawset(unit.Traits, index, trait)
  rawset(unit.TraitDictionary, trait.Name, { trait })
  if not unit.SlottedTraits then rawset(unit, "SlottedTraits", {}) end
  rawset(unit.SlottedTraits, trait.Slot, trait.Name)
  return index
end

-- Only called on a fresh, still private CreateNewHero result. A conflict
-- discards that candidate before AttachLua can publish a partially filled Unit.
function Stock.restoreGuest(game, g, state, unit, held)
  if state.session ~= game.session or state.slot ~= game.session.slots[state.seatId]
    or state.hero ~= g.CurrentRun.Hero or state.room ~= g.CurrentRun.CurrentRoom then
    return nil, "guest binding changed"
  end
  local restored = {}
  for _, trait in ipairs(held) do
    local ok, reason = availableSlot(unit, state.hero, trait.Name, trait.Slot, trait.Id)
    if not ok then return nil, reason end
    local copy = g.DeepCopyTable(trait)
    insertTrait(unit, copy)
    table.insert(restored, copy)
  end
  return restored
end

-- Authority-only commit of the selection issued by Game:SelectBoon. The
-- caller supplies no actor, rarity or instance data.
function Stock.grantGuest(game, roomId, rewardId, seat, selection)
  local g, session = rom.game, game.session
  if not session or not Session.isAuthority(session) or type(selection) ~= "table"
    or selection.seat ~= seat then return nil, "invalid selection" end
  local load = g.CurrentRun and game:LoadedRoom(g.CurrentRun.CurrentRoom)
  local reward = load and load.id == roomId and Stock.reward(load, rewardId)
  if not reward or reward.id ~= rewardId or load.room.Leaving then return nil, "stale opportunity" end
  local member = reward.guests and reward.guests[seat]
  local entry = reward.seats and reward.seats[seat]
  local function bound()
    return member and entry and reward.guests[seat] == member and reward.seats[seat] == entry
      and member.slot == session.slots[seat] and entry.slot == member.slot
      and member.slot.connected and entry.actor == member.actorId and member.unit.ObjectId == member.actorId
      and game:BoundGuestUnit(seat) == member.unit
  end
  if not bound() then return nil, "guest binding changed" end
  if entry.consumed and entry.grantedSelection == selection then return entry.instanceId end
  local name = entry.selected
  local slot = guestGrantSlots[name]
  local allowed, offer = available(game, g, load, reward)
  if entry.pending ~= selection or not slot or not allowed
    or (offer and (offer.source.StackOnly or offer.source.UpgradeOnPick)) then
    return nil, "no matching ordinary selection"
  end
  local roll = member.rolls[member.round]
  local rarity = roll.rarities and roll.rarities[name]
  if not rarity then return nil, "missing rolled rarity" end
  local definition = g.TraitData and g.TraitData[name]
  local level = definition and definition.RarityLevels and definition.RarityLevels[rarity]
  -- The duration-adjustment branch of ProcessTraitData uses the host cache.
  -- This ordinary boon has no duration and has a fixed multiplier per rarity.
  if not level or type(level.Multiplier) ~= "number" or definition.RemainingUses ~= nil then
    return nil, "unsupported trait definition"
  end
  if entry.preparing then return nil, "grant in progress" end

  local unit = member.unit
  entry.preparing = true
  local ok, trait = pcall(g.GetProcessedTraitData, { Unit = unit, TraitName = name, Rarity = rarity, StackNum = 1 })
  entry.preparing = nil
  if not ok then return nil, tostring(trait) end
  if type(trait) ~= "table" or trait.Name ~= name or trait.Rarity ~= rarity or trait.Slot ~= slot
    or trait.RarityMultiplier ~= level.Multiplier or trait.StackNum ~= 1 or trait.Id ~= nil or trait == definition then
    return nil, "invalid processed trait"
  end
  if game.session ~= session or not Session.isAuthority(session) or not g.CurrentRun
    or game:LoadedRoom(g.CurrentRun.CurrentRoom) ~= load or not available(game, g, load, reward)
    or not bound() or entry.pending ~= selection or entry.selected ~= name or member.rolls[member.round] ~= roll then
    return nil, "selection changed during processing"
  end

  local id = table.concat({ "h2t", roomId, rewardId, seat, unit.ObjectId }, "/")
  local available, reason = availableSlot(unit, g.CurrentRun.Hero, name, slot, id)
  if not available then return nil, reason end
  local players = Stock.runHoldings(game, g.CurrentRun)
  local slots = unit.SlottedTraits
  -- These are the attached Unit's Lua tables. Finish all stock calls before
  -- publishing into them; preserve the table identities used by other readers.
  trait.Id, trait.SourceName = id, reward.kind
  local index = insertTrait(unit, trait)
  local added = unit.Traits[index]
  if added == trait and unit.TraitDictionary[name][1] == added and unit.SlottedTraits[slot] == name
    and added.Name == name and added.Rarity == rarity and added.Id == id and added.StackNum == 1 then
    local checked, confirmed = pcall(Boon.confirm, session, reward, selection, unit.ObjectId, added.Name, added.Id)
    if checked and confirmed then
      entry.grantedSelection, entry.rarity = selection, added.Rarity
      remember(players, member.slot, added)
      return added.Id
    end
  end
  rawset(unit.Traits, index, nil)
  rawset(unit.TraitDictionary, name, nil)
  rawset(unit.SlottedTraits, slot, nil)
  if not slots then rawset(unit, "SlottedTraits", nil) end
  return nil, "grant not confirmed"
end

local function selected(game, g, unit, data, args)
  local run = g.CurrentRun
  if not run or not unit or unit ~= run.Hero or type(data) ~= "table"
    or args.TraitData ~= data or data.TraitToReplace then return end
  local load = game:LoadedRoom(run.CurrentRoom)
  if not load then return end
  local _, offer = Stock.readOptions(game, g, load)
  if not offer then return end
  local screen = choiceScreen(g, offer.source)
  if not screen or screen.ChoiceMade ~= true then return end
  for _, trait in pairs(unit.Traits or {}) do
    if trait.Name == data.Name then return end
  end
  for _, button in ipairs(screen.UpgradeButtons or {}) do
    local item = offer.source.UpgradeOptions[button.Index]
    if button.Type == "Trait" and button.OnPressedFunctionName == "HandleUpgradeChoiceSelection"
      and button.Screen == screen and button.LootData == offer.source and button.Data == data
      and item and item.ItemName == data.Name and not item.Blocked then
      -- This observes the stock beneficiary even if their connection is down.
      -- Network/player intents enter Game:SelectBoon and require an online seat.
      local selection = Boon.select(game.session, offer.reward, game.hostSeat, unit.ObjectId, data.Name)
      if selection then return { load = load, offer = offer, selection = selection, actor = unit.ObjectId } end
    end
  end
end

local function committed(game, g, pending, unit, result)
  local run, offer = g.CurrentRun, pending.offer
  if not run or run.Hero ~= unit or unit.ObjectId ~= pending.actor or not run.CurrentRoom
    or game:LoadedRoom(run.CurrentRoom) ~= pending.load or run.CurrentRoom.Encounter ~= offer.encounter
    or Stock.current(g, pending.load) ~= offer or type(result) ~= "table" then return end
  for _, trait in pairs(unit.Traits or {}) do
    if trait == result then
      return Boon.confirm(game.session, offer.reward, pending.selection, unit.ObjectId, result.Name, result.Id)
    end
  end
end

function Stock.onGrant(game, g, original, ...)
  local unit, data, args = ...
  if type(args) ~= "table" or args.FromLoot ~= true or args.PreProcessedForDisplay ~= true then
    return original(...)
  end
  local ok, pending = pcall(selected, game, g, unit, data, args)
  if not ok or not pending then return original(...) end
  local results = table.pack(pcall(original, ...))
  if results[1] then pcall(committed, game, g, pending, unit, results[2]) end
  Boon.cancel(pending.offer.reward, pending.selection)
  if not results[1] then error(results[2], 0) end
  return table.unpack(results, 2, results.n)
end

return Stock
