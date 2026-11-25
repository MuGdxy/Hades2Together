-- Watches the control queue. The webpage is a separate local server, because
-- this process stops rendering when its window is in the background.

local Bridge = import("dev/bridge.lua")
local Console = import("dev/console.lua")

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

local function pump()
  if not console then
    return
  end
  Bridge.sync(console, commandsPath, statusPath)
end

function Menu.install(session)
  console = Console.new(session)
  commandsPath, statusPath = controlPaths()
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
