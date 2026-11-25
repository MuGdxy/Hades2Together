-- Startup control. The shell main menu is a native screen and does not
-- accept a new sjson button, so this draws the multiplayer button itself.
-- The dev socket only changes the roster. Spawning a unit stays in game.lua.

local Console = import("dev/console.lua")

local Menu = {}

local server
local client
local console
local loggedPump = false

local function logOnce(text)
  if loggedPump then
    return
  end
  loggedPump = true
  print("[Hades2Together] " .. text)
end

local function pump()
  if not server or not console then
    return
  end
  if not client then
    local accepted, err = server:accept()
    if not accepted then
      if err ~= "timeout" then
        logOnce("dev accept failed: " .. tostring(err))
      end
      return
    end
    accepted:settimeout(0)
    client = accepted
    return
  end

  local line, err = client:receive("*l")
  if line then
    local response = Console.execute(console, line)
    client:send(response .. "\n")
    return
  end
  if err ~= "timeout" then
    client:close()
    client = nil
  end
end

local function render()
  local ImGui = rom.ImGui
  local flags = 0
  local windowFlags = rom.ImGuiWindowFlags
  local cond = rom.ImGuiCond
  if windowFlags then
    flags = (windowFlags.NoSavedSettings or 0)
      + (windowFlags.AlwaysAutoResize or 0)
      + (windowFlags.NoFocusOnAppearing or 0)
  end
  if cond then
    ImGui.SetNextWindowPos(48, 48, cond.FirstUseEver)
  end
  if ImGui.Begin("Hades2Together", flags) then
    if ImGui.Button("多人游戏") then
      Menu.open = not Menu.open
    end
    if Menu.open and console then
      ImGui.Separator()
      ImGui.Text("席位  " .. Console.roster(console))
      if ImGui.Button("加入假玩家") then
        Console.execute(console, "player add")
      end
      ImGui.Text("命令行端口 " .. tostring(Menu.port))
    end
  end
  ImGui.End()
  pump()
end

function Menu.install(session, port)
  console = Console.new(session)
  Menu.open = false
  Menu.port = port or 27779

  local okSocket, socketLib = pcall(require, "socket")
  if not okSocket then
    logOnce("dev socket unavailable: " .. tostring(socketLib))
  else
    local listener, bindErr = socketLib.bind("127.0.0.1", Menu.port)
    if not listener then
      logOnce("dev port " .. tostring(Menu.port) .. " failed: " .. tostring(bindErr))
    else
      listener:settimeout(0)
      server = listener
    end
  end

  rom.gui.add_always_draw_imgui(function()
    local ok, err = pcall(render)
    if not ok then
      logOnce("menu draw failed: " .. tostring(err))
    end
  end)

  return server ~= nil
end

return Menu
