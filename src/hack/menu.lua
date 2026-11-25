-- Watches the control queue. The webpage is a separate local server, because
-- this process stops rendering when its window is in the background.

local Bridge = import("dev/bridge.lua")
local Console = import("dev/console.lua")
local Inputs = import("dev/inputs.lua")

local Menu = {}

function Menu.new(session)
  local home = os.getenv("USERPROFILE") or os.getenv("HOME") or "."
  local root = home .. "\\Hades2Together"
  return {
    console = Console.new(session),
    commandsPath = root .. "\\commands.txt",
    statusPath = root .. "\\status.txt",
    inputsPath = root .. "\\inputs.txt",
  }
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

function Menu.pump(control, game)
  local console = control.console
  Bridge.sync(console, control.commandsPath, control.statusPath)
  if console.enterMap then
    if game:Enter(console.enterMap) then
      console.enterMap = nil
    end
  end
  if console.play then
    console.play = false
    local text = readAll(control.inputsPath)
    if not text then
      game.enterResult = "play missing inputs"
    else
      local script = Inputs.parse(text)
      for slot = 2, 4 do
        if not console.session.slots[slot] then
          Console.execute(console, "player add " .. (script.names[slot] or ("P" .. slot)))
        end
      end
      game:BeginPlayback(script)
    end
  end
  local now = os.clock()
  local dt = 0
  if control.lastClock then
    dt = now - control.lastClock
  end
  control.lastClock = now
  game:Install()
  game:RefreshBodies()
  game:Step(dt)
  local report = io.open(control.statusPath, "ab")
  if report then
    report:write(game:BodyReport() .. "\n")
    report:close()
  end
end

return Menu
