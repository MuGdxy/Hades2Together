local Input = import("client/input.lua")
local Messages = import("protocol/messages.lua")
local Room = import("protocol/room.lua")
local Session = import("protocol/session.lua")
local Tcp = import("net/tcp.lua")

local Client = {}
Client.__index = Client

function Client.connect(socket, port, name, address, background)
  local hello = Messages.hello(name)
  if not Messages.validHello(hello) then
    return nil, "invalid name"
  end
  local stream, err = Tcp.connect(socket, port, address, background)
  if not stream then
    return nil, err
  end
  stream:send("hello", hello)
  if not stream.connectBy then stream:flush() end
  if stream.closed then
    return nil, stream.closed
  end
  return setmetatable({ transport = stream, socket = socket, seq = 0, tick = 0 }, Client)
end

local function records(value, key, fieldType)
  if type(value) ~= "table" then
    return false
  end
  local length = #value
  for index, record in pairs(value) do
    if type(index) ~= "number" or index < 1 or index > length
      or type(record) ~= "table" or type(record[key]) ~= fieldType then
      return false
    end
  end
  for index = 1, length do
    if not value[index] then
      return false
    end
  end
  return true
end

local function validHeroes(heroes, capacity)
  if not records(heroes, "id", "number") then return false end
  for _, hero in ipairs(heroes) do
    if hero.playerId ~= nil and not Session.validSeat(hero.playerId, capacity) then return false end
    if hero.connected ~= nil and type(hero.connected) ~= "boolean" then return false end
    if hero.heldBoons ~= nil then
      if not records(hero.heldBoons, "name", "string") then return false end
      for _, boon in ipairs(hero.heldBoons) do
        if not boon.name:match("^[%w_]+$") or type(boon.rarity) ~= "string" or not boon.rarity:match("^[%w_]+$")
          or not Messages.validTick(boon.stacks) or boon.stacks < 1 then return false end
      end
    end
  end
  return true
end

function Client:accept(msg)
  if msg.t == "error" then
    return type(msg.reason) == "string"
  end
  if not self.playerId then
    local id = msg.playerId
    local maxPlayers = msg.maxPlayers
    if maxPlayers == nil then
      maxPlayers = Session.MAX_PLAYERS
    end
    if msg.t == "welcome" and Messages.accepts(msg.protocol)
      and Session.validSeat(maxPlayers) and Session.validSeat(id, maxPlayers) then
      self.playerId, self.maxPlayers = id, maxPlayers
      return true
    end
    return false
  end
  if msg.t == "snap" and Messages.validTick(msg.tick)
    and validHeroes(msg.heroes, self.maxPlayers) and records(msg.enemies, "id", "number")
    and (msg.room == nil or Room.valid(msg.room, self.maxPlayers)) then
    if self.snapshot and msg.tick <= self.tick then
      return nil
    end
    if msg.room then
      if self.roomId and msg.room.id < self.roomId then
        return nil
      end
      self.roomId = msg.room.id
    end
    -- One complete view replaces the previous one, including absent actors.
    self.tick, self.snapshot = msg.tick, msg
    return true
  end
  return msg.t == "ev" and msg.e == "decisions" and msg.tick == self.tick
    and self.snapshot ~= nil and records(msg.commands, "type", "string")
end

function Client:poll()
  local stream = self.transport
  if stream.connectBy and not stream.closed then
    local _, writable = self.socket.select({}, { stream.socket }, 0)
    if #writable > 0 and stream.socket:getpeername() then
      stream.connectBy = nil
    elseif #writable > 0 or self.socket.gettime() >= stream.connectBy then
      stream:close("connection failed or timed out")
    else
      return {}
    end
  end
  self.transport:flush()
  local accepted = {}
  local batch = self.transport:drain()
  for _, item in ipairs(batch) do
    local applied = self:accept(item.msg)
    if applied == false then
      self.transport:close("invalid server message")
      return nil, "invalid server message"
    elseif applied then
      accepted[#accepted + 1] = item
    end
  end
  return accepted, self.transport.closed, #batch
end

function Client:sendInput(state)
  if not self.playerId then
    return nil, "seat not assigned"
  end
  local frame = Input.frame(self.tick, self.playerId, state, self.seq + 1)
  if not Messages.validInput(frame, Session.capacity(self)) then
    return nil, "invalid input"
  end
  local ok, err = self.transport:send("in", frame)
  if not ok then
    return nil, err
  end
  self.seq = frame.seq
  self.transport:flush()
  if self.transport.closed then
    return nil, self.transport.closed
  end
  return true
end

function Client:close()
  self.transport:close()
end

local function offersGrant(claim, option)
  if not claim.grantOptions then return claim.grantOption == option end
  for _, name in ipairs(claim.grantOptions) do
    if name == option then return true end
  end
  return false
end

function Client:chooseBoon(opportunity, option)
  local request = { t = "boon", opportunity = opportunity, option = option }
  if not Messages.validBoon(request) then return nil, "invalid boon request" end
  local room = self.snapshot and self.snapshot.room
  if not self.playerId or not room or room.leaving then return nil, "no current room offer" end
  for _, reward in ipairs(room.rewards or {}) do
    for _, claim in ipairs(reward.claims or {}) do
      if claim.playerId == self.playerId and claim.opportunity == opportunity and offersGrant(claim, option) then
        local ok, err = self.transport:send("boon", request)
        if not ok then return nil, err end
        self.transport:flush()
        if self.transport.closed then return nil, self.transport.closed end
        return true
      end
    end
  end
  return nil, "option unavailable in this seat's snapshot"
end

return Client
