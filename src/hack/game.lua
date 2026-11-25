-- Live game binding. Extra players are visible bodies beside the real hero.
-- Slots 3 and 4 are not engine player slots. They are obstacles wearing Melinoe's mesh.

local Engine = import("hack/engine.lua")

local Game = {
  bodies = {},
  pending = {},
  installed = false,
}

local OFFSETS = {
  [2] = { 180, 40 },
  [3] = { -180, 40 },
  [4] = { 0, 170 },
}

local COLORS = {
  [2] = { 0.45, 0.75, 1.0, 1 },
  [3] = { 0.45, 0.95, 0.55, 1 },
  [4] = { 1.0, 0.55, 0.75, 1 },
}

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
    self:PlaceBody(existing, heroId)
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
  pcall(SetScale, { Id = id, Fraction = 0.7 })
  pcall(SetAnimation, { Name = "MelinoeIdle", DestinationId = id })
  local color = COLORS[playerId]
  if color then
    pcall(SetColor, { Id = id, Color = color })
  end

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
      Color = color or { 1, 1, 1, 1 },
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
  if type(Destroy) == "function" then
    pcall(Destroy, { Id = body.id })
    if body.labelId then
      pcall(Destroy, { Id = body.labelId })
    end
  end
  self.bodies[playerId] = nil
end

function Game:Enter(mapName)
  if type(LoadMap) ~= "function" then
    self.enterResult = "waiting"
    return false
  end
  local ok, err = pcall(function()
    if type(thread) == "function" then
      thread(function()
        LoadMap({ Name = mapName })
      end)
    else
      LoadMap({ Name = mapName })
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
        parts[#parts + 1] = playerId .. ":" .. tostring(slot.name) .. ":spawned=" .. tostring(body.id)
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
