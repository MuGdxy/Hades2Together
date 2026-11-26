-- Lifecycle of the checked Hell2Modding single-owner sampler. All native
-- operations run from the original game update. Input receipts live in C++.
local Host = {}

local required = {
  "h2t_sampler_install", "h2t_sampler_observe", "h2t_sampler_arm",
  "h2t_active_bind", "h2t_active_connect", "h2t_active_clear",
  "h2t_active_submit", "h2t_active_audit", "h2t_active_revoke",
}

function Host.revoke(game, reason)
  local state = game.hostInput
  if state and not state.failure then
    state.failure = reason
    state.applied = nil
    if state.bound and not state.native.h2t_active_revoke(state.load) then
      state.failure = reason .. " (native revoke unconfirmed)"
    end
  end
end

-- Connection changes can occur entirely inside one CLI pump. Synchronize before
-- each submit and again after draining the queue, even if no input was sent.
local function syncConnection(state, slot)
  local generation = slot.connectionGeneration or 1
  if state.bound and state.connectionGeneration == nil then
    -- A game object retained across a plugin refresh may have an old binding
    -- whose first connection used MapLoads as its native token.
    state.token, state.lastToken = state.load, state.load
    state.connectionGeneration = 1
  end
  if state.token and (not slot.connected or generation ~= state.connectionGeneration) then
    local disconnect = state.native.h2t_active_disconnect
    if not disconnect or not disconnect(state.token) then return false end
    state.token, state.applied = nil, nil
  end
  state.connectionGeneration = generation
  if not state.bound then return true end
  if not slot.connected then
    state.phase = "offline"
  elseif not state.token then
    -- Native tokens never repeat for this owner, including legacy bindings.
    local token = math.max(generation, (state.lastToken or 0) + 1)
    if not state.native.h2t_active_connect(token) then return false end
    state.token, state.lastToken = token, token
    state.phase = "waiting for neutral batch"
  end
  return true
end

function Host.checkOwner(game)
  local state = game.hostInput
  if not state or state.failure then return false end
  local slot, room, hero, load = game:InputOwner()
  if slot == state.slot and room == state.room and hero == state.hero
      and hero.ObjectId == state.id and load == state.load then
    if syncConnection(state, slot) then return true end
    Host.revoke(game, "native connection change refused")
    return false
  end
  Host.revoke(game, "host owner changed")
  return false
end

function Host.update(game, native)
  local state = game.hostInput
  if state and state.failure and native and native.h2t_sampler_resume then
    local slot, room, hero, load = game:InputOwner()
    if slot and (load ~= state.load or room ~= state.room or hero ~= state.hero) then
      game.hostLastToken = state.lastToken or game.hostLastToken
      game.hostInput, state = nil, nil
    end
  end
  if not state then
    if not native or not native.h2t_active_submit then return end
    for _, key in ipairs(required) do
      if type(native[key]) ~= "function" then
        game.hostInput = { failure = "missing native binding " .. key }
        return
      end
    end
    local slot, room, hero, load = game:InputOwner()
    if not slot or (not slot.connected and not native.h2t_guest_owner) then return end
    state = { native = native, phase = "waiting for empty pad lane", slot = slot,
      room = room, hero = hero, id = hero.ObjectId, load = load, lastToken = game.hostLastToken }
    game.hostInput = state
    local installed = native.h2t_sampler_install()
    if installed ~= "ready" then
      Host.revoke(game, "sampler install " .. tostring(installed))
      return
    end
  end
  if not Host.checkOwner(game) then return end
  native = state.native
  if state.bound then
    local audit = native.h2t_active_audit()
    if audit.reset or audit.valid ~= true or ((audit.batch or 0) > 0 and not audit.complete) then
      Host.revoke(game, "original sampler lost its owner or complete batch")
      return
    elseif state.phase == "waiting for neutral batch" and native.h2t_active_clear(state.token) then
      state.phase = "ready"
    end
    state.applied = state.phase == "ready" and audit.complete and audit.sequence or nil
    return
  end

  local trace = native.h2t_sampler_observe(state.id)
  if state.phase == "waiting for empty pad lane" and trace.outcome == "zero_pads" then
    local armed = native.h2t_sampler_arm(state.id)
    if armed ~= "attached" then
      Host.revoke(game, "virtual pad " .. tostring(armed))
      return
    end
    state.phase = "waiting for stock pad recognition"
  elseif state.phase == "waiting for empty pad lane" and trace.outcome == "complete"
      and native.h2t_sampler_resume and native.h2t_sampler_resume(state.id) then
    state.phase = "waiting for stock pad recognition"
  elseif state.phase == "waiting for stock pad recognition" and trace.outcome == "complete"
      and trace.owner_same and trace.stock_same and trace.direct_neutral
      and trace.sample_neutral and trace.handler_neutral and game:InputAllowed() then
    state.bound = native.h2t_active_bind(state.id, state.load)
    if not state.bound or not syncConnection(state, state.slot) then
      Host.revoke(game, "native host bind or connect refused")
      return
    end
    if not state.token then state.phase = "offline" end
  end
end

function Host.submit(game, frame)
  local state = game.hostInput
  if not state then return false, "host sampler is waiting for a save-disabled room and hero" end
  if not Host.checkOwner(game) then return false, state.failure end
  if state.phase ~= "ready" then return false, state.phase end
  if frame.aimX ~= 0 or frame.aimY ~= 0 or frame.buttons > 3 then
    return false, "host sampler supports movement, Attack1 and Attack2"
  end
  if (frame.buttons ~= 0 or frame.moveX ~= 0 or frame.moveY ~= 0) and not game:InputAllowed() then
    return false, "stock input blocked"
  end
  if not state.native.h2t_active_submit(state.token, frame.seq, frame.moveX, frame.moveY,
      frame.aimX, frame.aimY, frame.buttons) then
    return false, "native owner, sequence or sample refused"
  end
  return true
end

return Host
