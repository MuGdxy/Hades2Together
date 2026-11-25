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
  if type(GetLocation) ~= "function" then
    return 0, 0
  end
  local point = GetLocation({ Id = id })
  if type(point) ~= "table" then
    return 0, 0
  end
  return point.X or point.x or 0, point.Y or point.y or 0
end

function Game.teleport(id, x, y)
  if not id or type(Teleport) ~= "function" then
    return
  end
  pcall(Teleport, { Id = id, OffsetX = x, OffsetY = y })
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
  if type(CurrentRun) ~= "table" or type(CurrentRun.Hero) ~= "table" then
    return nil
  end
  return CurrentRun.Hero.ObjectId
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
  pcall(Teleport, {
    Id = body.id,
    DestinationId = heroId,
    OffsetX = offset[1],
    OffsetY = offset[2],
  })
  if body.labelId then
    pcall(Teleport, {
      Id = body.labelId,
      DestinationId = heroId,
      OffsetX = offset[1],
      OffsetY = offset[2],
    })
  end
end

function Game:SpawnBody(playerId, spec)
  if type(SpawnObstacle) ~= "function" then
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

  local id = SpawnObstacle({
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
  pcall(SetThingProperty, { Property = "GrannyModel", Value = "Melinoe_Mesh", DestinationId = id })
  pcall(SetThingProperty, { Property = "Graphic", Value = "MelinoeIdle", DestinationId = id })
  pcall(SetThingProperty, { Property = "Material", Value = "Unlit", DestinationId = id })
  pcall(SetScale, { Id = id, Fraction = 0.7 })
  pcall(SetAnimation, { Name = "MelinoeIdle", DestinationId = id })
  body.anim = "idle"

  local labelId = SpawnObstacle({
    Name = "BlankObstacle",
    Group = "Standing",
    DestinationId = heroId,
  })
  body.labelId = labelId
  if labelId then
    pcall(CreateTextBox, {
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
  if type(Destroy) == "function" then
    pcall(Destroy, { Id = body.id })
    if body.labelId then
      pcall(Destroy, { Id = body.labelId })
    end
  end
  self.bodies[playerId] = nil
end

local function resolveLoadMap()
  if type(import_as_fallback) == "function" and type(rom) == "table" and type(rom.game) == "table" then
    pcall(import_as_fallback, rom.game)
  end
  if type(LoadMap) == "function" then
    return LoadMap
  end
  if type(rom) == "table" and type(rom.game) == "table" and type(rom.game.LoadMap) == "function" then
    return rom.game.LoadMap
  end
end

function Game:Enter(mapName)
  local loadMap = resolveLoadMap()
  if not loadMap then
    if not self.loggedLoadMap then
      self.loggedLoadMap = true
      local gameTable = type(rom) == "table" and type(rom.game) or "nil"
      local loadType = "nil"
      if type(rom) == "table" and type(rom.game) == "table" then
        loadType = type(rom.game.LoadMap)
      end
      print("[Hades2Together] LoadMap missing rom.game=" .. gameTable .. " LoadMap=" .. loadType)
    end
    self.enterResult = "waiting"
    return false
  end
  local ok, err = pcall(function()
    if type(thread) == "function" then
      thread(function()
        loadMap({ Name = mapName })
      end)
    else
      loadMap({ Name = mapName })
    end
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
  if body.anim ~= anim and type(SetAnimation) == "function" then
    local clip = moving and "MelinoeRun" or "MelinoeIdle"
    pcall(SetAnimation, { Name = clip, DestinationId = id })
    body.anim = anim
  end
  if moving and type(SetAngle) == "function" then
    local angle = math.atan2(my, mx) * 180 / math.pi
    pcall(SetAngle, { Id = id, Angle = angle })
    if type(SetGoalAngle) == "function" then
      pcall(SetGoalAngle, { Id = id, Angle = angle, CompleteAngle = true })
    end
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
  if self.installed or type(OnAnyLoad) ~= "function" then
    return
  end
  self.installed = true
  OnAnyLoad({ function(args)
    Game:OnMap(args and args.name)
  end })
end

for _, name in ipairs(Engine.methods) do
  if Game[name] == nil then
    Game[name] = later(name)
  end
end

return Game
