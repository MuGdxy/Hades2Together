---@meta _
---@diagnostic disable: lowercase-global

local Reload = {}

local envyImport = import
local pluginEnv = _ENV
local active
local control
local gameState
local frameError

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
      "Enter", "BeginPlayback", "RefreshBodies", "Step", "BodyReport" },
    ["dev/bridge.lua"] = { "sync", "statusText" },
    ["dev/console.lua"] = { "new", "execute" },
    ["dev/inputs.lua"] = { "parse", "stick", "integrate" },
    ["protocol/session.lua"] = { "new", "join", "count", "drop" },
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
  return candidate
end

local function frame()
  local ok, err = pcall(active.Menu.pump, control, gameState)
  if not ok and not frameError then
    frameError = true
    rom.log.warning("[Hades2Together] control sync failed: " .. tostring(err))
  end
end

local function prepare()
  local candidate = candidateRuntime()
  if gameState then
    return candidate
  end

  local session = candidate.Session.new(config.role)
  local slot = candidate.Session.join(session, config.playerName or "Player")
  local newControl = candidate.Menu.new(session)
  local newGame = candidate.Game.new(session)
  return candidate, newControl, newGame, slot
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
    frameError = nil
  else
    rom.log.warning("[Hades2Together] Lua load failed: " .. tostring(candidate))
  end

  if active then
    -- The loader cleared these even when the candidate could not load.
    rom.gui.add_always_draw_imgui(frame)
  end
  if newGame then
    gameState:Install()
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
