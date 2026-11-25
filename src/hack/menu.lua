-- Watches the control queue. The webpage is a separate local server, because
-- this process stops rendering when its window is in the background.

local Bridge = import("dev/bridge.lua")
local Console = import("dev/console.lua")
local Inputs = import("dev/inputs.lua")
local Game = import("hack/game.lua")

local Menu = {}

local console
local commandsPath
local statusPath
local logged = false

local function logOnce(text)
  if logged then
    return
  end
  logged = true
  print("[Hades2Together] " .. text)
end

local function controlPaths()
  local home = os.getenv("USERPROFILE") or os.getenv("HOME") or "."
  local root = home .. "\\Hades2Together"
  return root .. "\\commands.txt", root .. "\\status.txt"
end

local function inputsPath()
  local home = os.getenv("USERPROFILE") or os.getenv("HOME") or "."
  return home .. "\\Hades2Together\\inputs.txt"
end

local function readAll(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  return text
end

local function pump()
  if not console then
    return
  end
  Bridge.sync(console, commandsPath, statusPath)
  if console.enterMap then
    if Game:Enter(console.enterMap) then
      console.enterMap = nil
    end
  end
  if console.play then
    console.play = false
    local text = readAll(inputsPath())
    if not text then
      Game.enterResult = "play missing inputs"
    else
      local script = Inputs.parse(text)
      for slot = 2, 4 do
        if not console.session.slots[slot] then
          Console.execute(console, "player add " .. (script.names[slot] or ("P" .. slot)))
        end
      end
      Game:BeginPlayback(script)
    end
  end
  local now = os.clock()
  local dt = 0
  if Menu.lastClock then
    dt = now - Menu.lastClock
  end
  Menu.lastClock = now
  Game:Install()
  Game:RefreshBodies()
  Game:Step(dt)
  local report = io.open(statusPath, "ab")
  if report then
    report:write(Game:BodyReport() .. "\n")
    report:close()
  end
end

function Menu.install(session)
  console = Console.new(session)
  commandsPath, statusPath = controlPaths()
  Game:SetSession(session)
  Game:Install()
  print("[Hades2Together] status " .. statusPath)
  pump()

  rom.gui.add_always_draw_imgui(function()
    local ok, err = pcall(pump)
    if not ok then
      logOnce("control sync failed: " .. tostring(err))
    end
  end)

  return true
end

return Menu
