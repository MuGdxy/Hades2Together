---@meta _
---@diagnostic disable: lowercase-global

local Reload = {}

local envyImport = import
local pluginEnv = _ENV
local active
local control
local gameState
local frameError
local observerError
local observer
local nextSnapshot = 0
local nextObserverStatus = 0

local function candidateRuntime()
  local env = setmetatable({}, { __index = pluginEnv })
  env._G = env
  local loaded = {}
  env.import = function(path)
    if loaded[path] == nil then
      local module = envyImport(path, env)
      assert(type(module) == "table", path .. " must return a table")
      loaded[path] = module
    end
    return loaded[path]
  end

  local candidate = env.import("ready.lua")
  local required = {
    ["hack/menu.lua"] = { "new", "pump", "publish" },
    ["hack/game.lua"] = { "new", "Install", "OnMap", "CheckEnter",
      "Enter", "BeginPlayback", "PushInput", "UpdateInputOwner", "Step", "BodyReport" },
    ["dev/bridge.lua"] = { "controlRoot", "sync", "statusText" },
    ["dev/console.lua"] = { "new", "execute" },
    ["dev/inputs.lua"] = { "parse", "stick" },
    ["protocol/session.lua"] = { "new", "join", "count", "drop", "isAuthority" },
  }
  for path, methods in pairs(required) do
    local module = env.import(path)
    for _, method in ipairs(methods) do
      assert(type(module[method]) == "function", path .. " is missing " .. method)
    end
  end
  assert(candidate.Game == loaded["hack/game.lua"]
    and candidate.Menu == loaded["hack/menu.lua"]
    and candidate.Session == loaded["protocol/session.lua"], "ready.lua must return Game, Menu and Session")
  if config.observerSnapshots or config.cliSnapshots then
    assert(type(candidate.Game.ReadActors) == "function", "hack/game.lua is missing ReadActors")
  end
  if config.observerSnapshots then
    local ok, status = pcall(envyImport, "dev/observer_status.lua", env)
    if ok and type(status) == "table" and type(status.publish) == "function" then
      candidate.ObserverStatus = status
    elseif active then
      candidate.ObserverStatus = active.ObserverStatus
    end
  end
  return candidate
end

local function publishObserverStatus(snapshot)
  -- Status is optional. Send the network snapshot first and tolerate a missing
  -- control directory or a file that another process is reading.
  if active.ObserverStatus then
    pcall(active.ObserverStatus.publish, snapshot)
  end
end

local function stepObserver()
  local now = observer.clock()
  if now < nextSnapshot then
    return
  end
  nextSnapshot = now + 0.05
  local result, failure = observer:step()
  assert(result, failure)
  if not control and now >= nextObserverStatus then
    nextObserverStatus = now + 0.25
    publishObserverStatus(result.snapshot)
  end
end

local function frame()
  if control then
    local ok, err = pcall(active.Menu.pump, control, gameState)
    if not ok and not frameError then
      frameError = true
      rom.log.warning("[Hades2Together] control sync failed: " .. tostring(err))
    end
  end
  if observer then
    local ok, err = pcall(stepObserver)
    if not ok and not observerError then
      observerError = true
      rom.log.warning("[Hades2Together] snapshot sync failed: " .. tostring(err))
    end
  end
end

local function prepare()
  local candidate = candidateRuntime()
  if gameState then
    return candidate
  end

  if config.observerSnapshots then
    return candidate, nil, candidate.Game.new()
  end
  local session = candidate.Session.new(config.role)
  local slot = candidate.Session.join(session, config.playerName or "Player")
  local newControl = candidate.Menu.new(session)
  local newGame = candidate.Game.new(session)
  return candidate, newControl, newGame, slot
end

local function startObserver()
  local Server = envyImport("authority/server.lua")
  observer = assert(Server.observe(require("socket"), config.port, function()
    return gameState:ReadActors()
  end))
  rom.log.info("[Hades2Together] observing on 127.0.0.1:" .. observer:port())
end

function Reload.load()
  local ok, candidate, newControl, newGame, slot = pcall(prepare)
  if ok then
    if gameState then
      -- OnAnyLoad still owns a callback with this instance as its receiver.
      setmetatable(gameState, { __index = candidate.Game })
    else
      control, gameState = newControl, newGame
    end
    active = candidate
    frameError, observerError = nil, nil
  else
    rom.log.warning("[Hades2Together] Lua load failed: " .. tostring(candidate))
  end

  if active then
    -- The loader cleared these even when the candidate could not load.
    rom.gui.add_always_draw_imgui(frame)
  end
  if newGame then
    gameState:Install()
    if config.observerSnapshots or (config.cliSnapshots and active.Session.isAuthority(gameState.session)) then
      local started, err = pcall(startObserver)
      if not started then
        rom.log.warning("[Hades2Together] observer startup failed: " .. tostring(err))
      end
    end
    if not control then
      publishObserverStatus()
      return
    end
    active.Menu.publish(control, gameState, "waiting for first game update")
    print("[Hades2Together] status " .. control.statusPath)
    rom.log.info(string.format(
      "[Hades2Together] control queue ready, role=%s slot=%s page=http://127.0.0.1:%s/",
      gameState.session.role, tostring(slot), tostring(config.devPort)
    ))
  elseif ok then
    rom.log.info("[Hades2Together] Lua reloaded")
  end
end

return Reload
