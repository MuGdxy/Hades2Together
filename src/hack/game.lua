-- Live game binding for the real hero and the local control queue.

local Engine = import("hack/engine.lua")
local Actions = import("protocol/actions.lua")
local Input = import("client/input.lua")
local Inputs = import("dev/inputs.lua")
local Messages = import("protocol/messages.lua")
local Session = import("protocol/session.lua")

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

local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function stockName(value)
  return type(value) == "string" and #value > 0 and #value <= 128 and not value:find("%c")
end

local function stockId(value)
  return Messages.validTick(value) and value > 0
end

local function readExits(map)
  if type(map) ~= "table" or type(map.OfferedExitDoors) ~= "table" then
    return nil
  end
  local exits = {}
  for id, door in pairs(map.OfferedExitDoors) do
    if stockId(id) and type(door) == "table" and door.ObjectId == id then
      local ok, exists = gameCall("IdExists", { Id = id })
      if not ok or type(exists) ~= "boolean" then
        return nil
      end
      if exists then
        local destination = type(door.Room) == "table" and door.Room.Name
        exits[#exits + 1] = {
          id = id, readyToUse = door.ReadyToUse == true, inUse = door.InUse == true,
          destination = stockName(destination) and destination or nil,
        }
      end
    end
  end
  table.sort(exits, function(a, b) return a.id < b.id end)
  return exits
end

local function readRoom(self, game, room)
  local load = self.roomLoad
  local mapState = game.SessionMapState
  -- LeaveRoom can assign the next room before the old map stops updating.
  if not load or load.room ~= room or load.name ~= room.Name
    or type(game.SessionState) ~= "table" or load.generation ~= game.SessionState.MapLoads
    or load.mapState ~= mapState or mapState.DeferredObstacleInitializationFinished ~= true then
    return nil
  end
  if not load.id then
    self.roomSerial = (self.roomSerial or 0) + 1
    load.id = self.roomSerial
  end
  local view = {
    id = load.id, name = load.name,
    leaving = room.Leaving == true, exitsUnlocked = room.ExitsUnlocked == true,
    exits = readExits(game.MapState),
  }
  local encounter = room.Encounter
  if type(encounter) == "table" and stockName(encounter.Name) and type(encounter.Completed) == "boolean" then
    local id = load.encounters[encounter]
    if not id then
      load.encounterSerial = load.encounterSerial + 1
      id = load.encounterSerial
      load.encounters[encounter] = id
    end
    view.encounter = { id = id, name = encounter.Name, completed = encounter.Completed }
  end
  return view
end

local function readActor(self, unit)
  if type(unit) ~= "table" then
    return nil
  end
  local id, hp, maxHp = unit.ObjectId, unit.Health, unit.MaxHealth
  if not finite(id) or id <= 0 or id % 1 ~= 0
      or not finite(hp) or hp < 0 or not finite(maxHp) or maxHp <= 0 then
    return nil
  end

  local args = { Id = id }
  local nameRead, kind = gameCall("GetName", args)
  local lifeRead, alive = gameCall("IsAlive", args)
  local x, y = self:location(id)
  if not nameRead or type(kind) ~= "string" or kind == "" or not lifeRead
      or type(alive) ~= "boolean" or not finite(x) or not finite(y) then
    return nil
  end
  local facingRead, facing = gameCall("GetAngle", args)
  return {
    id = id, kind = kind, x = x, y = y, hp = hp, maxHp = maxHp,
    alive = alive and not unit.IsDead,
    facing = facingRead and finite(facing) and facing or nil,
  }
end

function Game:ReadActors()
  local actors = { heroes = {}, enemies = {} }
  local game = rom and rom.game
  local run = game and game.CurrentRun
  if type(run) ~= "table" or type(run.CurrentRoom) ~= "table" then
    return actors
  end
  actors.room = readRoom(self, game, run.CurrentRoom)
  local hero = readActor(self, run.Hero)
  if hero then
    actors.heroes[1] = hero
  end

  local activeEnemies = game.ActiveEnemies
  local teamRead, teamIds = gameCall("GetIds", { Name = "EnemyTeam" })
  if type(activeEnemies) ~= "table" or not teamRead or type(teamIds) ~= "table" then
    return actors
  end
  local seen = {}
  local heroId = self:HeroId()
  for _, id in ipairs(teamIds) do
    if finite(id) and not seen[id] and id ~= heroId then
      seen[id] = true
      local unit = activeEnemies[id]
      if type(unit) == "table" and unit.ObjectId == id and not unit.IsDead then
        local enemy = readActor(self, unit)
        if enemy and enemy.alive then
          actors.enemies[#actors.enemies + 1] = enemy
        end
      end
    end
  end
  table.sort(actors.enemies, function(a, b) return a.id < b.id end)
  return actors
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
    buttons = held(readControl, "Attack1") * Actions.bit("Attack1"),
  }
end

function Game:PushInput(playerId)
  if playerId ~= 1 then
    return false, "seat " .. playerId .. " has no native player input slot"
  end
  -- The retail SendControlInput Lua action returns without dispatching input.
  return false, "the retail Lua API cannot submit native player movement"
end

function Game:SubmitInput(tick, playerId, state)
  local slot = self.session.slots[playerId]
  if not slot or not slot.connected then
    return false, "seat " .. playerId .. " is disconnected"
  end
  self.inputSequences = self.inputSequences or {}
  local seq = (self.inputSequences[playerId] or 0) + 1
  local frame = Input.frame(tick, playerId, state, seq)
  if not Messages.validInput(frame, Session.MAX_PLAYERS) then
    return false, "invalid sample"
  end
  self.inputSequences[playerId] = seq
  local accepted, reason = self:PushInput(playerId, frame)
  if accepted == false then
    return false, "unsupported " .. reason
  end
  return true
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
  self.playResult = nil
end

function Game:Step(dt, tick)
  if not self.playing or not self.script then
    return
  end
  if not self:HeroId() then
    self.playResult = "waiting for hero; run enter"
    return
  end

  self.playTime = (self.playTime or 0) + math.max(0, math.min(dt, 0.05))
  local active = false
  for playerId = 1, Session.MAX_PLAYERS do
    local slot = self.session.slots[playerId]
    local steps = self.script.steps[playerId]
    if slot and slot.connected and steps and #steps > 0 then
      local mx, my, hasStep = Inputs.stick(self.script, playerId, self.playTime)
      local accepted, reason = self:SubmitInput(tick, playerId, { moveX = mx, moveY = my })
      if not accepted then
        self.playing = false
        self.playResult = reason
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
  local game = rom.game
  local run, session, mapState = game.CurrentRun, game.SessionState, game.SessionMapState
  local room = type(run) == "table" and run.CurrentRoom
  local generation = type(session) == "table" and session.MapLoads
  if type(room) ~= "table" or not stockName(name) or room.Name ~= name
    or not stockId(generation) or type(mapState) ~= "table" then
    self.roomLoad = nil
    return
  end
  local load = self.roomLoad
  if not load or load.room ~= room or load.generation ~= generation or load.mapState ~= mapState then
    self.roomLoad = {
      room = room, name = name, generation = generation, mapState = mapState,
      encounters = {}, encounterSerial = 0,
    }
  end
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
