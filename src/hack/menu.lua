-- Polls the queue on game updates. The control page runs in its own process.

local Bridge = import("dev/bridge.lua")
local Console = import("dev/console.lua")
local Inputs = import("dev/inputs.lua")

local Session = import("protocol/session.lua")

local Menu = {}

function Menu.new(session)
  local root = Bridge.controlRoot()
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

local function preparePlayback(session, text)
  local limit = Session.capacity(session)
  local script = Inputs.parse(text, limit)
  local ids = {}
  for id in pairs(script.names) do ids[#ids + 1] = id end
  for id, steps in pairs(script.steps) do
    if not script.names[id] and #steps > 0 then ids[#ids + 1] = id end
  end
  table.sort(ids)

  -- Resolve all names and reservations before publishing any new member.
  local prospective = { maxPlayers = limit, slots = {} }
  for id, slot in pairs(session.slots) do
    prospective.slots[id] = { name = slot.name, connected = slot.connected }
  end
  for _, id in ipairs(ids) do
    local slot = session.slots[id]
    local name = script.names[id] or (slot and slot.name) or ("P" .. id)
    local joined, reason = Session.join(prospective, name, id)
    if joined ~= id then return nil, "seat " .. id .. ": " .. tostring(reason) end
  end
  for _, id in ipairs(ids) do
    if not session.slots[id] then Session.join(session, prospective.slots[id].name, id) end
  end
  return script
end

function Menu.pump(control, game)
  -- A retained pre-seat-snapshot script cannot identify its original connections.
  if game.playing and not game.playbackSeats then
    game.playing = false
    game.playResult = "legacy playback stopped on reload; run play to restart"
  end
  game:UpdateInputOwner()
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
      local script, reason = preparePlayback(console.session, text)
      if script then
        game:BeginPlayback(script)
      else
        game.playing, game.playResult = false, reason
      end
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
