-- Translate the retail single-hero choice and AddTraitData return into
-- authority data. Menu objects never leave this adapter.
local Boon = import("gameplay/boon.lua")
local GuestBoon = import("hack/guest_boon.lua")
local Session = import("protocol/session.lua")
local Stock = {}

-- Includes an anchored offer retained from a plugin version that stored
-- receipts only after consumption.
function Stock.reward(load)
  local offer = load.boonOffer
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

function Stock.readOptions(game, g, load)
  local run, offer = g.CurrentRun, Stock.current(g, load)
  if not offer or not game.session or not Session.isAuthority(game.session) then return end
  local reward = Stock.reward(load)
  for seat, member in pairs(reward.guests or {}) do
    local options = member.rolls[member.round].options
    if options and member.slot == game.session.slots[seat] and member.unit.ObjectId == member.actorId
      and game:BoundGuestUnit(seat) == member.unit then
      Boon.setOptions(game.session, reward, seat, member.actorId, options)
    else
      Boon.withholdOptions(reward, seat)
    end
  end
  if offer.candidates ~= offer.source.UpgradeOptions then
    if offer.reward then Boon.withholdOptions(offer.reward, game.hostSeat) end
    offer.candidates, offer.locksObserved = offer.source.UpgradeOptions, false
  end
  if run and run.CurrentRoom == load.room and run.Hero and run.Hero.ObjectId
    and game:BindHero(game.hostSeat) == run.Hero.ObjectId then
    local options = generatedOptions(g, offer)
    if options and Boon.setOptions(game.session, Stock.reward(load), game.hostSeat, run.Hero.ObjectId, options) then
      return offer, true
    end
  end
  if offer.reward then Boon.withholdOptions(offer.reward, game.hostSeat) end
  return offer, false
end

local function selected(game, g, unit, data, args)
  local run = g.CurrentRun
  if not run or not unit or unit ~= run.Hero or type(data) ~= "table"
    or args.TraitData ~= data or data.TraitToReplace then return end
  local load = game:LoadedRoom(run.CurrentRoom)
  if not load then return end
  local offer, resolved = Stock.readOptions(game, g, load)
  if not resolved then return end
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
