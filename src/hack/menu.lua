-- Polls the queue on game updates. The control page runs in its own process.

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

function Menu.publish(control, game, state)
  local report = io.open(control.statusPath, "wb")
  if report then
    report:write(Bridge.statusText(control.console))
    report:write("control=" .. state .. "\n")
    if control.results then
      report:write(table.concat(control.results, "\n") .. "\n")
    end
    report:write(game:BodyReport() .. "\n")
    report:close()
  end
end

function Menu.pump(control, game)
  local console = control.console
  local tick = (control.inputTick or 0) + 1
  control.inputTick = tick
  local results = Bridge.sync(console, control.commandsPath, function(playerId, state)
    return game:SubmitInput(tick, playerId, state)
  end)
  if #results > 0 then
    control.results = results
  end
  local now = os.clock()
  game:CheckEnter(now)
  if console.enterMap then
    if game:Enter(console.enterMap, now) then
      console.enterMap = nil
    end
  end
  if console.play then
    console.play = false
    local text = readAll(control.inputsPath)
    if not text then
      game.playResult = "failed missing inputs.txt; run h2t.ps1 play"
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
  local dt = 0
  if control.lastClock then
    dt = now - control.lastClock
  end
  control.lastClock = now
  game:Install()
  game:Step(dt, tick)
  Menu.publish(control, game, "polling")
end

return Menu
