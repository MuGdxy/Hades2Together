-- The room owns the actor. Only the input connection follows roster changes.
local Guest = {}
local Actions = import("protocol/actions.lua")

function Guest.states(game)
  if not game.guestInputs then
    game.guestInputs = {}
    if game.guestInput then -- Reload an existing two-seat plugin.
      game.guestInput.seatId = 2
      game.guestInputs[2], game.guestInput = game.guestInput, nil
    end
  end
  return game.guestInputs
end

function Guest.supports(native, seat)
  return native and native.h2t_guest_owner and (native.h2t_guest_capacity or seat == 2)
end

-- The previous DLL exposed a single guest and expects the old argument count.
local function call(native, seat, name, ...)
  if not native.h2t_guest_capacity then return native[name](...) end
  local args = table.pack(...)
  args[args.n + 1] = seat
  return native[name](table.unpack(args, 1, args.n + 1))
end

function Guest.actor(native, seat)
  if native and native.h2t_guest_actor and (native.h2t_guest_capacity or seat == 2) then
    return call(native, seat, "h2t_guest_actor")
  end
end

function Guest.seats(hostSeat, slots, retained)
  local ids = {}
  for id in pairs(slots or {}) do
    if id ~= hostSeat then ids[#ids + 1] = id end
  end
  for id in pairs(retained or {}) do
    if not slots or not slots[id] then ids[#ids + 1] = id end
  end
  table.sort(ids)
  return ids
end

local function checkStaff(game, state)
  local ok, result = pcall(game.EquipGuestStaff, game, state)
  state.staffStatus = ok and result or ("guest staff setup failed: " .. tostring(result))
  state.staffPublication = state.publication
  return state.staffStatus == "equipped"
end

local function sync(state, slot)
  local generation = slot and (slot.connectionGeneration or 1)
  local eligible = slot and slot.connected and state.actor and not state.actor.IsDead
  if state.token and (not eligible or generation ~= state.connectionGeneration) then
    if not call(state.native, state.seatId, "h2t_guest_connection", state.load, state.publication, state.token, false) then
      state.reason = "secondary disconnect pending"
      return false
    end
    state.token, state.sequence, state.ready = nil, nil, false
  end
  if not eligible then
    state.reason = slot and slot.connected and "secondary actor unavailable" or "offline"
    return false
  end
  if not state.token then
    local token = math.max(generation, (state.lastToken or 0) + 1)
    if not call(state.native, state.seatId, "h2t_guest_connection", state.load, state.publication, token, true) then
      state.reason = "secondary connection refused"
      return false
    end
    state.token, state.lastToken, state.connectionGeneration, state.ready = token, token, generation, false
  end
  if not state.ready then state.reason = "waiting for secondary neutral batch" end
  return true
end

local function updateSeat(game, native, seat)
  if not native or not native.h2t_guest_owner then return end
  local state = Guest.states(game)[seat]
  local slot = game.session and game.session.slots[seat]
  local _, room, hero, load = game:InputOwner()
  if state and state.betweenRooms then
    if state.session == game.session and state.slot == slot then
      if not load then return end
      state = nil
    end
    if not state then game.guestInputs[seat] = nil end
  end
  if state and (state.session ~= game.session or not slot or slot ~= state.slot or load ~= state.load or room ~= state.room or hero ~= state.hero) then
    local keep = state.session == game.session and slot ~= nil and state.slot == slot
    local result
    if native.h2t_guest_capacity then
      result = native.h2t_guest_owner(0, state.load, 0, false, 0, seat, keep)
    else
      result = native.h2t_guest_owner(0, state.load, 0, false, 0)
    end
    state.ready, state.sequence, state.id = false, nil, nil
    state.actor, state.token, state.offlineBatch = nil, nil, nil
    state.reason = result.status or "retirement pending"
    if result.epoch == 0 then
      if keep and native.h2t_guest_capacity then
        game.guestInputs[seat] = { betweenRooms=true, seatId=seat, session=game.session,
          slot=slot, load=state.load, reason="waiting for room" }
      else
        game.guestInputs[seat] = nil
      end
    end
    return
  end
  if not slot or not load then return end
  if not state then
    state = { seatId = seat, session = game.session, slot = slot, load = load, room = room, hero = hero, native = native }
    game.guestInputs[seat] = state
  end
  local point
  if not state.sawOwner and not state.pendingSpawn and game:LoadedRoom(room) and game.hostInput
      and game.hostInput.load == load and game.hostInput.bound and not game.hostInput.failure then
    if not game.guestResource then
      native.register_file_redirect("Maps/bin/H2TGuest.thing_bin", _PLUGIN.plugins_mod_folder_path .. "/hack/H2TGuest.bin")
      game.guestResource = true
    end
    point = game:GuestSpawnPoint(hero.ObjectId, state)
  end
  local result = call(native, seat, "h2t_guest_owner", hero.ObjectId, load, point or 0, true, slot.connectionGeneration or 1)
  state.pendingSpawn = result.status == "waiting for original input return" and (state.pendingSpawn or point) or nil
  if not result.id then
    state.id, state.sequence, state.token, state.ready, state.actor = nil, nil, nil, false, nil
    if result.status == "empty" then
      state.reason = state.sawOwner and "original guest retired" or "waiting for a clear room spawn point"
    else
      state.reason = result.status
    end
    return
  end
  state.id, state.sawOwner, state.publication = result.id, true, result.publication
  local attached, reason = game:EnsureGuestActor(state)
  if not attached then
    state.ready, state.reason = false, reason or "waiting for original attached hero table"
    return
  end
  if state.staffPublication ~= state.publication or not state.staffStatus then checkStaff(game, state) end
  if not result.inputBound then
    state.token, state.ready, state.sequence = nil, false, nil
    state.reason = "waiting for original handler"
    return
  end
  state.offlineBatch = nil
  if not sync(state, slot) then
    if not slot.connected and not state.token then state.offlineBatch = result.idleBatch end
    return
  end
  if not state.ready then state.ready = call(native, seat, "h2t_guest_clear", state.publication, state.token) end
  if state.ready then state.reason, state.sequence = "ready", result.sequence end
end

function Guest.update(game, native)
  local slots = game.session and game.session.slots
  for _, seat in ipairs(Guest.seats(game.hostSeat, slots, Guest.states(game))) do
    if Guest.supports(native, seat) then updateSeat(game, native, seat) end
  end
end

function Guest.check(game)
  for seat, state in pairs(Guest.states(game)) do
    local slot = game.session and game.session.slots[seat]
    if state.id and state.token then
      sync(state, game.session == state.session and slot == state.slot and slot or nil)
    end
  end
end

function Guest.submit(game, frame)
  local seat = frame.playerId
  local state = Guest.states(game)[seat]
  local slot = game.session and game.session.slots[seat]
  local _, room, hero, load = game:InputOwner()
  if not state or not state.id or not slot or slot ~= state.slot or load ~= state.load
      or room ~= state.room or hero ~= state.hero then return false, state and state.reason or "guest owner unavailable" end
  if not sync(state, slot) or not state.ready then return false, state.reason end
  if frame.aimX ~= 0 or frame.aimY ~= 0 or frame.buttons > 3 then return false, "unsupported secondary input" end
  if (frame.buttons ~= 0 or frame.moveX ~= 0 or frame.moveY ~= 0) and not game:InputAllowed() then
    return false, "stock input blocked"
  end
  if frame.buttons >= Actions.bit("Attack2") and state.staffStatus ~= "equipped" and not checkStaff(game, state) then
    return false, state.staffStatus
  end
  if not call(state.native, seat, "h2t_guest_submit", load, state.publication, state.token, frame.seq, frame.moveX, frame.moveY,
      frame.aimX, frame.aimY, frame.buttons) then return false, "secondary sample refused" end
  return true
end

return Guest
