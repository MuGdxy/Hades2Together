-- Observe the ordinary new-trait branch of the stock upgrade choice.
local Boon = {}

local function selected(game, g, unit, data, args)
  local run = g.CurrentRun
  if not run or unit ~= run.Hero or not unit or type(data) ~= "table"
    or args.TraitData ~= data or data.TraitToReplace or type(data.Name) ~= "string"
    or #data.Name == 0 or #data.Name > 128 or data.Name:find("%c") then return end
  local load = game:LoadedRoom(run.CurrentRoom)
  local offer = load and load.boonOffer
  local slot = game.session.slots[game.hostSeat]
  if not offer or not slot or type(unit.ObjectId) ~= "number" or unit.ObjectId <= 0
    or game:BindHero(game.hostSeat) ~= unit.ObjectId or run.CurrentRoom.Leaving
    or run.CurrentRoom.Encounter ~= offer.encounter then return end
  local source = offer.source
  local screen = g.ScreenAnchors and g.ScreenAnchors.ChoiceScreen
  local map = g.MapState
  if not screen or not g.ActiveScreens or g.ActiveScreens[screen.Name] ~= screen
    or screen.ChoiceMade ~= true or screen.Source ~= source or g.CurrentLootData ~= source
    or source.Name ~= "PoseidonUpgrade" or source.ObjectId ~= offer.objectId
    or source.StackOnly or source.UpgradeOnPick or not map or not map.RoomRequiredObjects
    or map.RoomRequiredObjects[source.ObjectId] ~= source or not map.RewardPointsUsed
    or map.RewardPointsUsed[run.CurrentRoom.SpawnRewardOnId] ~= source.ObjectId then return end
  for _, trait in pairs(unit.Traits or {}) do
    if trait.Name == data.Name then return end
  end
  for _, button in ipairs(screen.UpgradeButtons or {}) do
    if button.Type == "Trait" and button.OnPressedFunctionName == "HandleUpgradeChoiceSelection"
      and button.Screen == screen and button.LootData == source and button.Data == data then
      return { load = load, offer = offer, slot = slot, actor = unit.ObjectId, name = data.Name }
    end
  end
end

local function committed(game, g, pending, unit, result)
  local offer = pending.offer
  local run = g.CurrentRun
  if not run or run.Hero ~= unit or unit.ObjectId ~= pending.actor or not run.CurrentRoom
    or game:LoadedRoom(run.CurrentRoom) ~= pending.load or run.CurrentRoom.Encounter ~= offer.encounter
    or pending.load.boonOffer ~= offer or game.session.slots[game.hostSeat] ~= pending.slot
    or type(result) ~= "table" or result.Name ~= pending.name or type(result.Id) ~= "string"
    or result.Id == "" then return end
  for _, trait in pairs(unit.Traits or {}) do
    if trait == result then
      local receipts = pending.load.boonClaims or {}
      for _, receipt in ipairs(receipts) do
        if receipt.id == offer.id then return end
      end
      receipts[#receipts + 1] = { id = offer.id, encounterId = offer.encounterId, kind = "PoseidonUpgrade",
        claim = { playerId = game.hostSeat, state = "consumed", choice = pending.name } }
      pending.load.boonClaims = receipts
      return
    end
  end
end

function Boon.onGrant(game, g, original, ...)
  local unit, data, args = ...
  if type(args) ~= "table" or args.FromLoot ~= true or args.PreProcessedForDisplay ~= true then
    return original(...)
  end
  local ok, pending = pcall(selected, game, g, unit, data, args)
  if not ok or not pending then return original(...) end
  local results = table.pack(original(...))
  pcall(committed, game, g, pending, unit, results[1])
  return table.unpack(results, 1, results.n)
end

return Boon
