-- Live game binding. Extra players are visible bodies beside the real hero.
-- Slots 3 and 4 are not engine player slots. They are obstacles wearing Melinoe's mesh.

local Engine = import("hack/engine.lua")
local Inputs = import("dev/inputs.lua")

local Game = {
  bodies = {},
  pending = {},
  installed = false,
}

local SPEED = 540
local OFFSETS = {
  [2] = { 180, 40 },
  [3] = { -180, 40 },
  [4] = { 0, 170 },
}

function Game.location(id)
  local fn = Game.gameEnv and Game.gameEnv.GetLocation or GetLocation
  if type(fn) ~= "function" then
    return 0, 0
  end
  local ok, point = pcall(fn, { Id = id })
  if not ok or type(point) ~= "table" then
    return 0, 0
  end
  return point.X or point.x or 0, point.Y or point.y or 0
end

function Game.teleport(id, x, y)
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

function Game:SetSession(session)
  self.session = session
end

function Game:HeroId()
  local env = self.gameEnv
  local run = env and env.CurrentRun or CurrentRun
  if type(run) ~= "table" or type(run.Hero) ~= "table" then
    return nil
  end
  return run.Hero.ObjectId
end

local function gameCall(name, args)
  local env = Game.gameEnv
  local fn = env and env[name] or nil
  if type(fn) ~= "function" then
    fn = _G[name]
  end
  if type(fn) ~= "function" then
    return nil
  end
  return pcall(fn, args)
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
  local spawn = Game.gameEnv and Game.gameEnv.SpawnObstacle or SpawnObstacle
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
  local hx, hy = Game.location(heroId)
  body.x = hx + body.offset[1]
  body.y = hy + body.offset[2]
  Game.teleport(id, body.x, body.y)
  if body.labelId then
    Game.teleport(body.labelId, body.x, body.y)
  end
  print("[Hades2Together] spawned seat " .. tostring(playerId) .. " " .. tostring(spec.name))
  return id
end

function Game:DropBody(playerId)
  local body = self.bodies[playerId]
  self.pending[playerId] = nil
  if not body then
    return
  end
  if type(Destroy) == "function" or (self.gameEnv and type(self.gameEnv.Destroy) == "function") then
    gameCall("Destroy", { Id = body.id })
    if body.labelId then
      gameCall("Destroy", { Id = body.labelId })
    end
  end
  self.bodies[playerId] = nil
end

if type(rom) == "table" and type(rom.on_import) == "table" and type(rom.on_import.pre) == "function" then
  rom.on_import.pre(function(a, b)
    if not Game.loggedHook then
      Game.loggedHook = true
      local g = rawget(_G, "LoadMap")
      print("[Hades2Together] import pre args " .. type(a) .. " " .. type(b)
        .. " _G.LoadMap=" .. type(_G.LoadMap)
        .. " raw=" .. type(g))
    end
    local env = type(a) == "table" and a or (type(b) == "table" and b or nil)
    if type(env) == "table" then
      Game.gameEnv = env
    elseif type(_G.LoadMap) == "function" then
      Game.gameEnv = _G
    end
  end)
end

local function resolveLoadMap()
  local env = Game.gameEnv
  if type(env) == "table" and type(env.LoadMap) == "function" then
    return env.LoadMap
  end
  if type(LoadMap) == "function" then
    return LoadMap
  end
end

function Game:Enter(mapName)
  local loadMap = resolveLoadMap()
  if not loadMap then
    if not self.loggedLoadMap then
      self.loggedLoadMap = true
      print("[Hades2Together] LoadMap missing, gameEnv=" .. type(self.gameEnv))
    end
    self.enterResult = "waiting"
    return false
  end
  local ok, err = pcall(function()
    loadMap({ Name = mapName })
  end)
  if ok then
    self.enterResult = "requested " .. mapName
    print("[Hades2Together] enter " .. mapName)
  else
    self.enterResult = "failed " .. tostring(err)
    print("[Hades2Together] enter failed: " .. tostring(err))
  end
  return true
end

function Game:BeginPlayback(script)
  self.script = script
  self.playing = true
  self.playTime = 0
  self.playOrigin = false
end

function Game:Drive(playerId, mx, my, dt, heroId)
  local moving
  local id
  local body
  if playerId == 1 then
    id = heroId
    body = self.bodies[1]
    if not body then
      local x, y = Game.location(heroId)
      body = { id = heroId, x = x, y = y, real = true, anim = "idle" }
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
    local hx, hy = Game.location(heroId)
    local offset = OFFSETS[playerId] or { 0, 0 }
    body.x = hx + offset[1]
    body.y = hy + offset[2]
  end
  body.x, body.y, moving = Inputs.integrate(body.x, body.y, mx, my, dt, SPEED)
  Game.teleport(id, body.x, body.y)
  if body.labelId then
    Game.teleport(body.labelId, body.x, body.y)
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
    return
  end
  if dt > 0.05 then
    dt = 0.05
  end
  if dt < 0 then
    dt = 0
  end
  self.playTime = (self.playTime or 0) + dt
  for playerId = 1, 4 do
    local mx, my = Inputs.stick(self.script, playerId, self.playTime)
    self:Drive(playerId, mx, my, dt, heroId)
  end
end

function Game:BodyReport()
  local heroId = self:HeroId()
  if not heroId then
    local line = "bodies hero=absent"
    if self.enterResult then
      line = line .. " enter=" .. self.enterResult
    end
    return line
  end
  local parts = { "bodies hero=" .. tostring(heroId) }
  for playerId = 2, 4 do
    local slot = self.session and self.session.slots[playerId]
    if slot and slot.connected then
      local body = self.bodies[playerId]
      if body and body.id then
        parts[#parts + 1] = string.format(
          "%d:%s:spawned=%s:x=%d:y=%d",
          playerId,
          tostring(slot.name),
          tostring(body.id),
          math.floor(body.x or 0),
          math.floor(body.y or 0)
        )
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
  if name ~= self.map then
    self.map = name
    self.bodies = {}
  end
  self:RefreshBodies()
end

function Game:Install()
  if self.installed then
    return
  end
  local onAnyLoad = self.gameEnv and self.gameEnv.OnAnyLoad or OnAnyLoad
  if type(onAnyLoad) ~= "function" then
    return
  end
  self.installed = true
  onAnyLoad({ function(args)
    Game:OnMap(args and args.name)
  end })
end

for _, name in ipairs(Engine.methods) do
  if Game[name] == nil then
    Game[name] = later(name)
  end
end

return Game
