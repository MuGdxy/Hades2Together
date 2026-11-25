local Input = import("client/input.lua")
local Messages = import("protocol/messages.lua")
local Room = import("protocol/room.lua")
local Session = import("protocol/session.lua")
local Tcp = import("net/tcp.lua")

local Client = {}
Client.__index = Client

function Client.connect(socket, port, name)
  local hello = Messages.hello(name)
  if not Messages.validHello(hello) then
    return nil, "invalid name"
  end
  local stream, err = Tcp.connect(socket, port)
  if not stream then
    return nil, err
  end
  stream:send("hello", hello)
  stream:flush()
  if stream.closed then
    return nil, stream.closed
  end
  return setmetatable({ transport = stream, seq = 0, tick = 0 }, Client)
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

function Client:accept(msg)
  if msg.t == "error" then
    return type(msg.reason) == "string"
  end
  if not self.playerId then
    local id = msg.playerId
    if msg.t == "welcome" and Messages.accepts(msg.protocol)
      and Messages.validTick(id) and id >= 1 and id <= Session.MAX_PLAYERS then
      self.playerId = id
      return true
    end
    return false
  end
  if msg.t == "snap" and Messages.validTick(msg.tick)
    and records(msg.heroes, "id", "number") and records(msg.enemies, "id", "number")
    and (msg.room == nil or Room.valid(msg.room)) then
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
  self.transport:flush()
  local accepted = {}
  for _, item in ipairs(self.transport:drain()) do
    local applied = self:accept(item.msg)
    if applied == false then
      self.transport:close("invalid server message")
      return nil, "invalid server message"
    elseif applied then
      accepted[#accepted + 1] = item
    end
  end
  return accepted, self.transport.closed
end

function Client:sendInput(state)
  if not self.playerId then
    return nil, "seat not assigned"
  end
  local frame = Input.frame(self.tick, self.playerId, state, self.seq + 1)
  if not Messages.validInput(frame, Session.MAX_PLAYERS) then
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

return Client
