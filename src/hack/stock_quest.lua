local Session = import("protocol/session.lua")
local StockQuest = {}

local questName, resource, amount = "QuestUnlockMoros", "GiftPoints", 1

local function authoritySession(game)
  return game.session and Session.isAuthority(game.session) and game.session or nil
end

local function entryFor(session)
  return session and session.stockQuestCashouts and session.stockQuestCashouts[questName]
end

local function isMorosButton(g, screen, button)
  local definition = g.QuestData and g.QuestData[questName]
  return definition and definition.Name == questName and definition.RewardResourceName == resource
    and definition.RewardResourceAmount == amount and button and button.Data == definition
    and button.Screen == screen
end

local function balances(state, run)
  return state.Resources[resource] or 0, state.LifetimeResourcesGained[resource] or 0,
    run.ResourcesGained[resource] or 0
end

local function sameContext(g, pending)
  return g.GameState == pending.state and g.CurrentRun == pending.run
    and g.CurrentHubRoom == pending.hub and g.CurrentHubRoom.Name == "Hub_Main"
    and g.SessionState and g.SessionState.MapLoads == pending.mapLoad
end

local function activeCashout(game)
  local entry = entryFor(authoritySession(game))
  local pending = entry and entry.pending
  if pending and pending.coroutine == coroutine.running() then return pending, entry end
end

local function captureRoster(game, session, run)
  local members = {}
  local primarySeat = game.hostSeat
  local primaryActor = run.Hero and run.Hero.ObjectId
  local primary = session.slots[primarySeat]
  if primary and (not primaryActor or game:BindHero(primarySeat) ~= primaryActor) then primary = nil end
  for seat, slot in pairs(session.slots) do
    members[slot] = {
      quest = questName,
      seat = seat,
      resource = resource,
      amount = amount,
      status = slot == primary and "stock-credited" or "entitled",
    }
  end
  return members
end

-- The original checks quest completion, performs the stock grant and marks the
-- status. Snapshot the reserved roster before any of that work can yield.
function StockQuest.onCashOut(game, g, original, screen, button, ...)
  local session = authoritySession(game)
  if not session or not isMorosButton(g, screen, button) then return original(screen, button, ...) end

  local state, run = g.GameState, g.CurrentRun
  local status = state.QuestStatus[questName]
  local entry = entryFor(session)
  if entry and entry.pending then return end
  if status == "CashedOut" then return original(screen, button, ...) end
  if entry then return end

  local hub, mapLoad = g.CurrentHubRoom, g.SessionState and g.SessionState.MapLoads
  if not hub or hub.Name ~= "Hub_Main" or type(mapLoad) ~= "number" then
    return original(screen, button, ...)
  end
  local pending = {
    state = state, run = run, hub = hub, mapLoad = mapLoad, coroutine = coroutine.running(),
    screen = screen, button = button, members = captureRoster(game, session, run),
  }
  entry = { pending = pending }
  session.stockQuestCashouts = session.stockQuestCashouts or {}
  session.stockQuestCashouts[questName] = entry

  local results = table.pack(pcall(original, screen, button, ...))
  entry.pending = nil
  -- A rejected or failed attempt with no stock mutation can be retried. If
  -- stock partially credited before failing, keep the entry to block replay.
  local grant = pending.grant
  if not entry.receipts and (not grant or not (grant.observed or grant.changed))
    and sameContext(g, pending) and state.QuestStatus[questName] == status then
    session.stockQuestCashouts[questName] = nil
  end
  if not results[1] then error(results[2], 0) end
  return table.unpack(results, 2, results.n)
end

-- The canonical cashout disables its button and calls AddResource directly on
-- the same coroutine with this source, amount and options.
function StockQuest.onAddResource(game, g, original, ...)
  local name, count, source, args = ...
  local pending = activeCashout(game)
  if not pending or pending.grant or name ~= resource or count ~= amount or source ~= "Quest"
    or type(args) ~= "table" or args.SkipVoiceLines ~= true or args.NoLifetimeEffect
    or pending.button.OnPressedFunctionName ~= nil or not sameContext(g, pending) then
    return original(...)
  end

  local wallet, lifetime, gained = balances(pending.state, pending.run)
  local grant = { args = args, wallet = wallet, lifetime = lifetime, gained = gained }
  pending.grant = grant
  local results = table.pack(pcall(original, ...))
  grant.args, grant.returned = nil, results[1]
  if not grant.observed and sameContext(g, pending) then
    local current, total, runGained = balances(pending.state, pending.run)
    grant.changed = current ~= wallet or total ~= lifetime or runGained ~= gained
  end
  if not results[1] then error(results[2], 0) end
  return table.unpack(results, 2, results.n)
end

-- Stock AddResource writes all three counters before dispatching this callback
-- with the original args table. On the valid retail path, the early bookkeeping
-- has no yield. The callback and later objectives can yield or touch resources.
function StockQuest.onGiftPointsAdded(game, g, original, ...)
  local name, count, source, args = ...
  local pending = activeCashout(game)
  local grant = pending and pending.grant
  if grant and grant.args and grant.args == args and grant.observed == nil
    and name == resource and count == amount and source == "Quest" and sameContext(g, pending) then
    local wallet, lifetime, gained = balances(pending.state, pending.run)
    grant.observed = wallet == grant.wallet + amount and lifetime == grant.lifetime + amount
      and gained == grant.gained + amount
  end
  return original(...)
end

-- Stock CashOutQuest calls this synchronously after the resource grant and
-- CashedOut transition. Record the result before presentation starts.
function StockQuest.onPresentation(game, g, original, screen, button, ...)
  local pending, entry = activeCashout(game)
  local grant = pending and pending.grant
  if grant and grant.observed and grant.returned and not entry.receipts
    and pending.screen == screen and pending.button == button
    and sameContext(g, pending) and pending.state.QuestStatus[questName] == "CashedOut" then
    entry.receipts = pending.members
  end
  return original(screen, button, ...)
end

-- The reservation object is the beneficiary key. It survives reconnects but
-- cannot be inherited by a later occupant of the same numeric seat.
function StockQuest.receipt(game, seat)
  local session = authoritySession(game)
  local entry = entryFor(session)
  local receipt = entry and entry.receipts and entry.receipts[session.slots[seat]]
  if not receipt then return end
  return { quest = receipt.quest, seat = receipt.seat, resource = receipt.resource,
    amount = receipt.amount, status = receipt.status }
end

return StockQuest
