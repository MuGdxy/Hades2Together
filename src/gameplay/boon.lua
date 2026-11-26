-- Trusted authority inputs. An opportunity is scoped to one room instance;
-- the engine adapter supplies its options and independently observes grants.
local Session = import("protocol/session.lua")
local Boon = {}

local function validName(name)
  return type(name) == "string" and #name > 0 and #name <= 128 and not name:find("%c")
end

local function contains(options, choice)
  for _, option in ipairs(options) do
    if choice == option then return true end
  end
  return false
end

function Boon.setOptions(session, reward, seat, actor, options)
  local slot = session.slots[seat]
  if not Session.isAuthority(session) or not slot or not Session.validSeat(seat, Session.capacity(session))
    or not Session.validSeat(actor) or type(options) ~= "table" then return false end
  -- A hot-reloaded room may already contain a confirmed single-seat receipt.
  if reward.claim and reward.claim.playerId == seat then return false end
  local entry = reward.seats and reward.seats[seat]
  if entry and (entry.slot ~= slot or entry.actor ~= actor or entry.consumed) then return false end
  if not entry then
    for _, existing in pairs(reward.seats or {}) do
      if existing.actor == actor then return false end
    end
  end
  local copy = {}
  for index in pairs(options) do
    if not Session.validSeat(index, #options) then return false end
  end
  for i, name in ipairs(options) do
    if not validName(name) or contains(copy, name) then return false end
    copy[i] = name
  end
  if #copy ~= #options then return false end
  reward.seats = reward.seats or {}
  entry = entry or { slot = slot, actor = actor }
  entry.options = copy
  if entry.pending and not contains(copy, entry.selected) then entry.pending, entry.selected = nil, nil end
  reward.seats[seat] = entry
  return true
end

function Boon.select(session, reward, seat, actor, choice)
  local entry = reward.seats and reward.seats[seat]
  if not entry or entry.slot ~= session.slots[seat] or entry.actor ~= actor or entry.consumed
    or not entry.options or not contains(entry.options, choice) then return nil end
  if entry.pending then return entry.selected == choice and entry.pending or nil end
  entry.pending, entry.selected = { seat = seat }, choice
  return entry.pending
end

-- A replacement roll may exist before its valid subset is known. Retain
-- the slot/actor binding and any completed receipt across that interval.
function Boon.withholdOptions(reward, seat)
  local entry = reward.seats and reward.seats[seat]
  if entry and not entry.consumed then entry.options, entry.pending, entry.selected = nil, nil, nil end
end

function Boon.cancel(reward, selection)
  if type(selection) ~= "table" then return end
  local entry = reward.seats and reward.seats[selection.seat]
  if entry and entry.pending == selection then entry.pending, entry.selected = nil, nil end
end

function Boon.confirm(session, reward, selection, beneficiary, name, instanceId)
  if type(selection) ~= "table" then return false end
  local entry = reward.seats and reward.seats[selection.seat]
  if not entry or entry.pending ~= selection or entry.slot ~= session.slots[selection.seat]
    or entry.actor ~= beneficiary or entry.selected ~= name or type(instanceId) ~= "string"
    or instanceId == "" then return false end
  for _, prior in pairs(reward.seats) do
    if prior.instanceId == instanceId then return false end
  end
  entry.consumed, entry.instanceId = name, instanceId
  entry.pending, entry.selected = nil, nil
  return true
end

function Boon.claims(reward, consumedOnly)
  local claims = {}
  if reward.claim then
    claims[1] = { playerId = reward.claim.playerId, state = reward.claim.state, choice = reward.claim.choice }
  end
  for seat, entry in pairs(reward.seats or {}) do
    if entry.consumed or (entry.options and not consumedOnly) then
      local state = entry.consumed and "consumed" or entry.pending and "claiming" or "eligible"
      claims[#claims + 1] = { playerId = seat, state = state, choice = entry.consumed,
        selected = entry.selected, options = { table.unpack(entry.options) } }
    end
  end
  table.sort(claims, function(a, b) return a.playerId < b.playerId end)
  return claims
end

return Boon
