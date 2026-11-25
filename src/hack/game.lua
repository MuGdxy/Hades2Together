-- Live game binding. Extra players are visible bodies beside the real hero.
-- Slots 3 and 4 are not engine player slots. They are obstacles wearing Melinoe's mesh.

local Engine = import("hack/engine.lua")
local Inputs = import("dev/inputs.lua")

local Game = {}

function Game.new(session)
  return setmetatable({
    session = session,
    bodies = {},
    pending = {},
    installed = false,
  }, { __index = Game })
end

local SPEED = 540
local TEST_MAPS = { F_Test = true, F_Combat01 = true }
local ENTER_TIMEOUT = 20
local OFFSETS = {
  [2] = { 180, 40 },
  [3] = { -180, 40 },
  [4] = { 0, 170 },
}

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

function Game:teleport(id, x, y)
  if not id then
    return
  end
  gameCall("Teleport", { Id = id, OffsetX = x, OffsetY = y })
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

function Game:BindHero(playerId, spec)
  spec = spec or {}
  self.pending[playerId] = spec
  if playerId == 1 then
    return self:HeroId()
  end
  return self:SpawnBody(playerId, spec)
end

function Game:PlaceBody(body, heroId)
  local offset = body.offset or { 0, 0 }
  gameCall("Teleport", {
    Id = body.id,
    DestinationId = heroId,
    OffsetX = offset[1],
    OffsetY = offset[2],
  })
  if body.labelId then
    gameCall("Teleport", {
      Id = body.labelId,
      DestinationId = heroId,
      OffsetX = offset[1],
      OffsetY = offset[2],
    })
  end
end

function Game:SpawnBody(playerId, spec)
  local spawn = rom and rom.game.SpawnObstacle
  if type(spawn) ~= "function" then
    return nil
  end
  local heroId = self:HeroId()
  if not heroId then
    return nil
  end
  local existing = self.bodies[playerId]
  if existing and existing.id then
    return existing.id
  end

  local id = spawn({
    Name = "BlankObstacle3D",
    Group = "Standing",
    DestinationId = heroId,
  })
  if not id then
    return nil
  end

  local body = {
    id = id,
    name = spec.name,
    offset = OFFSETS[playerId] or { 180, 0 },
  }
  self.bodies[playerId] = body
  gameCall("SetThingProperty", { Property = "GrannyModel", Value = "Melinoe_Mesh", DestinationId = id })
  gameCall("SetThingProperty", { Property = "Graphic", Value = "MelinoeIdle", DestinationId = id })
  gameCall("SetThingProperty", { Property = "Material", Value = "Unlit", DestinationId = id })
  gameCall("SetScale", { Id = id, Fraction = 0.7 })
  gameCall("SetAnimation", { Name = "MelinoeIdle", DestinationId = id })
  body.anim = "idle"

  local labelId = spawn({
    Name = "BlankObstacle",
    Group = "Standing",
    DestinationId = heroId,
  })
  body.labelId = labelId
  if labelId then
    gameCall("CreateTextBox", {
      Id = labelId,
      Text = spec.name or ("P" .. tostring(playerId)),
      OffsetY = -180,
      FontSize = 22,
      Color = { 1, 1, 1, 1 },
      Font = "LatoMedium",
      Justification = "Center",
    })
  end
  self:PlaceBody(body, heroId)
  print("[Hades2Together] spawned seat " .. tostring(playerId) .. " " .. tostring(spec.name))
  return id
end

function Game:DropBody(playerId)
  local body = self.bodies[playerId]
  self.pending[playerId] = nil
  if not body then
    return
  end
  gameCall("Destroy", { Id = body.id })
  if body.labelId then
    gameCall("Destroy", { Id = body.labelId })
  end
  self.bodies[playerId] = nil
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
  for _, body in pairs(self.bodies) do
    body.x, body.y = nil, nil
  end
end

function Game:Drive(playerId, mx, my, dt, heroId)
  local moving
  local id
  local body
  if playerId == 1 then
    id = heroId
    body = self.bodies[1]
    if not body then
      body = { id = heroId, anim = "idle" }
      self.bodies[1] = body
    end
  else
    local slot = self.session and self.session.slots[playerId]
    local name = slot and slot.name or ("P" .. tostring(playerId))
    id = self:BindHero(playerId, { name = name })
    body = self.bodies[playerId]
  end
  if not body or not id then
    return
  end
  if body.x == nil then
    body.x, body.y = self:location(id)
    if body.x == nil then
      return
    end
  end
  body.x, body.y, moving = Inputs.integrate(body.x, body.y, mx, my, dt, SPEED)
  self:teleport(id, body.x, body.y)
  if body.labelId then
    self:teleport(body.labelId, body.x, body.y)
  end
  local anim = moving and "run" or "idle"
  if body.anim ~= anim then
    local clip = moving and "MelinoeRun" or "MelinoeIdle"
    gameCall("SetAnimation", { Name = clip, DestinationId = id })
    body.anim = anim
  end
  if moving then
    local angle = math.atan2(my, mx) * 180 / math.pi
    gameCall("SetAngle", { Id = id, Angle = angle })
    gameCall("SetGoalAngle", { Id = id, Angle = angle, CompleteAngle = true })
  end
end

function Game:Step(dt)
  if not self.playing or not self.script then
    return
  end
  local heroId = self:HeroId()
  if not heroId then
    self.playResult = "waiting for hero; run enter"
    return
  end
  if dt > 0.05 then
    dt = 0.05
  end
  if dt < 0 then
    dt = 0
  end
  self.playTime = (self.playTime or 0) + dt
  local active = false
  for playerId = 1, 4 do
    local slot = self.session.slots[playerId]
    if slot and slot.connected then
      local mx, my, hasStep = Inputs.stick(self.script, playerId, self.playTime)
      active = active or hasStep
      self:Drive(playerId, mx, my, dt, heroId)
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
  if run and run.CurrentRoom and run.CurrentRoom.Name then
    parts[#parts + 1] = "map=" .. run.CurrentRoom.Name
  end
  for playerId = 2, 4 do
    local slot = self.session and self.session.slots[playerId]
    if slot and slot.connected then
      local body = self.bodies[playerId]
      if body and body.id then
        parts[#parts + 1] = string.format("%d:%s:spawned=%s", playerId, slot.name, body.id)
          .. positionText(self, body.id)
      else
        parts[#parts + 1] = playerId .. ":" .. tostring(slot.name) .. ":waiting"
      end
    end
  end
  return table.concat(parts, " ")
end

function Game:RefreshBodies()
  if not self.session then
    return
  end
  for playerId = 2, 4 do
    local slot = self.session.slots[playerId]
    if slot and slot.connected then
      self:BindHero(playerId, { name = slot.name })
    else
      self:DropBody(playerId)
    end
  end
end

function Game:OnMap(name)
  self.map = name
  self.bodies = {}
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
