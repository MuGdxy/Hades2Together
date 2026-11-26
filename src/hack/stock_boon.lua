-- Translate the retail single-hero choice and AddTraitData return into
-- authority data. Menu objects never leave this adapter.
local Boon = import("gameplay/boon.lua")
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

function Stock.readOptions(game, g, load)
  local run, offer = g.CurrentRun, Stock.current(g, load)
  if not game.session or not run or not run.Hero or not offer
    or run.CurrentRoom ~= load.room or game:BindHero(game.hostSeat) ~= run.Hero.ObjectId then return end
  local source = offer.source
  local screen = g.ScreenAnchors and g.ScreenAnchors.ChoiceScreen
  if not screen or not g.ActiveScreens or g.ActiveScreens[screen.Name] ~= screen
    or screen.Source ~= source or g.CurrentLootData ~= source or source.StackOnly or source.UpgradeOnPick
    or type(source.UpgradeOptions) ~= "table" or type(screen.BlockedIndexes) ~= "table" then return end
  local blocked, options = {}, {}
  for _, index in ipairs(screen.BlockedIndexes) do blocked[index] = true end
  for i, item in ipairs(source.UpgradeOptions) do
    if item.Type == "Trait" and not blocked[i] and not item.Blocked and not item.TraitToReplace then
      options[#options + 1] = item.ItemName
    end
  end
  if Boon.setOptions(game.session, Stock.reward(load), game.hostSeat, run.Hero.ObjectId, options) then
    return screen, offer
  end
end

local function selected(game, g, unit, data, args)
  local run = g.CurrentRun
  if not run or not unit or unit ~= run.Hero or type(data) ~= "table"
    or args.TraitData ~= data or data.TraitToReplace then return end
  local load = game:LoadedRoom(run.CurrentRoom)
  if not load then return end
  local screen, offer = Stock.readOptions(game, g, load)
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
