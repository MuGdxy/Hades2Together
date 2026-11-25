-- Live game binding for the real hero and the local control queue.

local Engine = import("hack/engine.lua")
local Inputs = import("dev/inputs.lua")
local Messages = import("protocol/messages.lua")

local Game = {}

function Game.new(session)
  return setmetatable({
    session = session,
    installed = false,
  }, { __index = Game })
end

local TEST_MAPS = { F_Test = true, F_Combat01 = true }
local ENTER_TIMEOUT = 20

local function gameCall(name, args)
  local fn = rom and rom.game[name]
  if type(fn) ~= "function" then
    return nil
  end
  return pcall(fn, args)
end

function Game:location(id)
  local ok, point = gameCall("GetLocation", { Id = id })
  if ok and type(point) == "table" then
    local x, y = point.X or point.x, point.Y or point.y
    if type(x) == "number" and type(y) == "number" then
      return x, y
    end
  end
end

local function later(name)
  return function()
    error("hack.game." .. name .. " is not implemented (phase 1)", 0)
  end
end

function Game:HeroId()
  local run = rom and rom.game.CurrentRun
  if type(run) ~= "table" or type(run.Hero) ~= "table" then
    return nil
  end
  return run.Hero.ObjectId
end

function Game:BindHero(playerId)
  if playerId == 1 then
    return self:HeroId()
  end
end

local function held(readControl, name)
  return readControl({ Name = name }) and 1 or 0
end

function Game:ReadLocalInput()
  local game = rom and rom.game
  local readControl = game and game.IsControlDown
  if type(readControl) ~= "function" then
    return nil, "native control readback is unavailable"
  end
  if not self:HeroId() then
    return nil, "local hero is unavailable"
  end

  return {
    moveX = held(readControl, "Right") - held(readControl, "Left"),
    moveY = held(readControl, "Down") - held(readControl, "Up"),
    buttons = held(readControl, "Attack1"),
  }
end

function Game:PushInput(playerId)
  if playerId ~= 1 then
    return false, "seat " .. playerId .. " has no native player input slot"
  end
  -- The retail SendControlInput Lua action returns without dispatching input.
  return false, "the retail Lua API cannot submit native player movement"
end

function Game:FinishEnter(result)
  self.enterRequest = nil
  self.enterResult = result
end

function Game:CheckEnter(now)
  local request = self.enterRequest
  if not request then
    return
  end
  if request.error then
    self:FinishEnter("failed " .. request.error .. "; restart the game if the room did not finish loading")
  elseif request.done and self:IsRoomReady(request.map) then
    self:FinishEnter("ready " .. request.map)
  elseif now >= request.deadline and not request.timedOut then
    -- The engine may still own a suspended LoadMap coroutine.
    request.timedOut = true
    self.enterResult = "failed " .. request.map .. " did not finish loading; restart with /AllowSaveLoad=false"
  end
end

function Game:IsRoomReady(mapName)
  local run = rom.game.CurrentRun
  local hero = self:HeroId()
  return run and run.CurrentRoom and run.CurrentRoom.Name == mapName
    and hero and self:location(hero) ~= nil
end

function Game:Enter(mapName, now)
  if not TEST_MAPS[mapName] then
    self.enterResult = "failed unsupported map " .. tostring(mapName) .. "; use enter F_Test or enter F_Combat01"
    return true
  end
  if self.enterRequest then
    return true
  end
  local g = rom.game
  if type(g.LoadMap) ~= "function" or type(g.thread) ~= "function"
      or type(g.StartNewGame) ~= "function" or type(g.RoomData) ~= "table" then
    self.enterResult = "waiting for game scripts"
    return false
  end
  local room = g.RoomData[mapName]
  local saveOptionRead, allowSave = gameCall("GetConfigOptionValue", { Name = "AllowSaveLoad" })
  local mapPath = rom.paths.Content() .. "/Maps/" .. mapName .. ".map_text"
  local mapFile = io.open(mapPath, "rb")
  if mapFile then
    mapFile:close()
  end
  if not room or room.GameStart or not mapFile then
    self.enterResult = "failed " .. mapName .. " is unavailable for direct load; use packaged F_Combat01"
  elseif not saveOptionRead or allowSave ~= false then
    self.enterResult = "failed restart with /AllowSaveLoad=false"
  elseif self:IsRoomReady(mapName) then
    self.enterResult = "ready " .. mapName
  elseif g.GameState ~= nil or g.CurrentRun ~= nil then
    self.enterResult = "failed a run is already active; restart with /AllowSaveLoad=false"
  else
    local request = { map = mapName, deadline = now + ENTER_TIMEOUT }
    self.enterRequest = request
    self.enterResult = "loading " .. mapName
    local ok, err = pcall(g.thread, function()
      -- RoomLogic's direct-load path creates a fresh run during PreThingCreation.
      -- LoadMap yields twice, so use the game's coroutine scheduler.
      local loaded, loadError = pcall(g.LoadMap, { Name = mapName })
      if not loaded then
        request.error = tostring(loadError)
        gameCall("RemoveInputBlock", { Name = "LoadMap" })
      end
      request.done = loaded
    end)
    if not ok then
      request.error = tostring(err)
    end
    self:CheckEnter(now)
  end
  return true
end

function Game:BeginPlayback(script)
  self.script = script
  self.playing = true
  self.playTime = 0
  self.playFrame = 0
  self.playResult = nil
end

function Game:Step(dt)
  if not self.playing or not self.script then
    return
  end
  if not self:HeroId() then
    self.playResult = "waiting for hero; run enter"
    return
  end

  self.playTime = (self.playTime or 0) + math.max(0, math.min(dt, 0.05))
  self.playFrame = (self.playFrame or 0) + 1
  local active = false
  for playerId = 1, 4 do
    local slot = self.session.slots[playerId]
    local steps = self.script.steps[playerId]
    if slot and slot.connected and steps and #steps > 0 then
      local mx, my, hasStep = Inputs.stick(self.script, playerId, self.playTime)
      local accepted, reason = self:PushInput(playerId, Messages.input(self.playFrame, playerId, mx, my))
      if accepted == false then
        self.playing = false
        self.playResult = "unsupported " .. reason
        return
      end
      active = active or hasStep
    end
  end
  self.playing = active == true
  self.playResult = self.playing and "running" or "finished"
end

local function positionText(self, id)
  local x, y = self:location(id)
  if x == nil then
    return ":location=unavailable"
  end
  return string.format(":x=%d:y=%d", math.floor(x), math.floor(y))
end

function Game:BodyReport()
  local heroId = self:HeroId()
  local parts = { "bodies hero=" .. (heroId and tostring(heroId) .. positionText(self, heroId) or "absent") }
  if self.enterResult then
    parts[#parts + 1] = "enter=" .. self.enterResult:gsub("[\r\n]+", " ")
  end
  if self.playResult then
    parts[#parts + 1] = "play=" .. self.playResult
  end
  local run = rom.game.CurrentRun
  local map = run and run.CurrentRoom and run.CurrentRoom.Name or self.map
  if map then
    parts[#parts + 1] = "map=" .. map
  end
  for playerId = 2, 4 do
    local slot = self.session and self.session.slots[playerId]
    if slot and slot.connected then
      parts[#parts + 1] = playerId .. ":" .. slot.name .. ":unsupported"
    end
  end
  return table.concat(parts, " ")
end

function Game:OnMap(name)
  self.map = name
end

function Game:Install()
  if self.installed then
    return
  end
  local onAnyLoad = rom.game.OnAnyLoad
  if type(onAnyLoad) ~= "function" then
    return
  end
  self.installed = true
  onAnyLoad({ function(args)
    self:OnMap(args and args.name)
  end })
end

for _, name in ipairs(Engine.methods) do
  if Game[name] == nil then
    Game[name] = later(name)
  end
end

return Game
