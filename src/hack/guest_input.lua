-- The room owns the actor. Only the input connection follows roster changes.
local Guest = {}

local function sync(state, slot)
  local generation = slot.connectionGeneration or 1
  if state.token and (not slot.connected or generation ~= state.token) then
    if not state.native.h2t_guest_connection(state.load, state.publication, state.token, false) then
      state.reason = "secondary disconnect pending"
      return false
    end
    state.token, state.sequence, state.ready = nil, nil, false
  end
  if not slot.connected then state.reason = "offline" return false end
  if not state.token then
    if not state.native.h2t_guest_connection(state.load, state.publication, generation, true) then
      state.reason = "secondary connection refused"
      return false
    end
    state.token, state.ready = generation, false
  end
  if not state.ready then state.reason = "waiting for secondary neutral batch" end
  return true
end

function Guest.update(game, native)
  if not native or not native.h2t_guest_owner then return end
  local state = game.guestInput
  local slot = game.session and game.session.slots[2]
  local _, room, hero, load = game:InputOwner(true)
  if state and (state.session ~= game.session or not slot or slot ~= state.slot or load ~= state.load or room ~= state.room or hero ~= state.hero) then
    local result = native.h2t_guest_owner(0, state.load, 0, false, 0)
    state.ready, state.sequence, state.id = false, nil, nil
    state.reason = result.status or "retirement pending"
    if result.epoch == 0 then game.guestInput = nil end
    return
  end
  if not slot or not load then return end
  if not state then
    state = { session = game.session, slot = slot, load = load, room = room, hero = hero, native = native }
    game.guestInput = state
  end
  local point
  if not state.sawOwner and game.roomLoad and game.roomLoad.room == room and game.roomLoad.generation == load
      and game.roomLoad.mapState.DeferredObstacleInitializationFinished == true and game.hostInput
      and game.hostInput.bound and not game.hostInput.failure then
    if not game.guestResource then
      native.register_file_redirect("Maps/bin/H2TGuest.thing_bin", _PLUGIN.plugins_mod_folder_path .. "/hack/H2TGuest.bin")
      game.guestResource = true
    end
    point = game:GuestSpawnPoint(hero.ObjectId)
  end
  local result = native.h2t_guest_owner(hero.ObjectId, load, point or 0, true, slot.connectionGeneration or 1)
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
  if not game:EnsureGuestActor(state) then
    state.ready, state.reason = false, "waiting for original attached hero table"
    return
  end
  if not result.inputBound then
    state.token, state.ready, state.sequence = nil, false, nil
    state.reason = "waiting for original handler"
    return
  end
  if not sync(state, slot) then return end
  if not state.ready then state.ready = native.h2t_guest_clear(state.publication, state.token) end
  if state.ready then state.reason, state.sequence = "ready", result.sequence end
end

function Guest.check(game)
  local state = game.guestInput
  if not state or not state.id or not state.token then return end
  local slot = game.session.slots[2]
  if slot == state.slot then sync(state, slot) end
end

function Guest.submit(game, frame)
  local state = game.guestInput
  local slot = game.session and game.session.slots[2]
  local _, room, hero, load = game:InputOwner()
  if not state or not state.id or not slot or slot ~= state.slot or load ~= state.load
      or room ~= state.room or hero ~= state.hero then return false, "secondary owner unavailable" end
  if not sync(state, slot) or not state.ready then return false, state.reason end
  if frame.aimX ~= 0 or frame.aimY ~= 0 or frame.buttons > 3 then return false, "unsupported secondary input" end
  if (frame.buttons ~= 0 or frame.moveX ~= 0 or frame.moveY ~= 0) and not game:InputAllowed() then
    return false, "stock input blocked"
  end
  if not state.native.h2t_guest_submit(load, state.publication, state.token, frame.seq, frame.moveX, frame.moveY,
      frame.aimX, frame.aimY, frame.buttons) then return false, "secondary sample refused" end
  return true
end

return Guest
