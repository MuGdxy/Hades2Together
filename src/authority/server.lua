local Authority = import("authority/loop.lua")
local Messages = import("protocol/messages.lua")
local Room = import("protocol/room.lua")
local Session = import("protocol/session.lua")
local Tcp = import("net/tcp.lua")

local Server = {}
Server.__index = Server

local HANDSHAKE_SECONDS = 2

local function listen(socket, port, session)
  local listener, err = Tcp.listen(socket, port)
  if not listener then
    return nil, err
  end
  return setmetatable({
    listener = listener,
    clock = socket.gettime,
    session = session,
    peers = {},
  }, Server)
end

function Server.listen(socket, port, engine, options)
  local authority = Authority.start(engine, options)
  local server, err = listen(socket, port, Session.new("serve", authority.party.maxPlayers))
  if server then
    server.authority = authority
  end
  return server, err
end

function Server.observe(socket, port, readActors, maxPlayers)
  assert(type(readActors) == "function", "observer requires an actor reader")
  local server, err = listen(socket, port, Session.new("serve", maxPlayers))
  if server then
    server.readActors = readActors
    server.tick = 0
  end
  return server, err
end

function Server:port()
  local _, port = self.listener:getsockname()
  return tonumber(port)
end

local function reply(peer, message)
  local ok, err = peer.stream:send(message.t, message)
  if not ok then
    peer.stream:close(err)
  end
end

local function reject(peer, reason)
  reply(peer, Messages.error(reason))
end

local function refuse(peer, reason, now)
  reject(peer, reason)
  peer.stream:finish(reason, now + HANDSHAKE_SECONDS)
end

function Server:join(peer, message, now)
  if message.t ~= "hello" or not Messages.validHello(message) then
    return refuse(peer, "invalid hello or protocol", now)
  end
  local reserved = Session.findSeat(self.session, message.name)
  if reserved and self.session.slots[reserved].connected then
    return refuse(peer, "name already connected", now)
  end
  local playerId, status = Session.join(self.session, message.name)
  if not playerId then
    return refuse(peer, status, now)
  end
  if self.authority and status == "joined" then
    local ok, err = Authority.addPlayer(self.authority, playerId, { name = message.name })
    if not ok then
      Session.drop(self.session, playerId)
      return refuse(peer, err, now)
    end
  end
  peer.playerId = playerId
  local maxPlayers = Session.capacity(self.session)
  reply(peer, Messages.welcome(playerId, maxPlayers ~= Session.MAX_PLAYERS and maxPlayers or nil))
end

local function acceptInput(peer, msg, maxPlayers)
  if msg.t ~= "in" or not Messages.validInput(msg, maxPlayers) then
    return reject(peer, "invalid input")
  end
  if msg.playerId ~= peer.playerId then
    return reject(peer, "wrong seat")
  end
  if msg.seq <= peer.seq then
    return reject(peer, "stale sequence")
  end
  if #peer.inputs >= Tcp.MAX_MESSAGES then
    return reject(peer, "input queue full")
  end
  peer.seq = msg.seq
  -- Copy only the input fields. The authority assigns the tick in step().
  peer.inputs[#peer.inputs + 1] = Messages.input(
    nil, peer.playerId, msg.moveX, msg.moveY, msg.buttons, msg.aimX, msg.aimY, msg.seq
  )
end

function Server:poll()
  if not self.listener then
    return nil, "closed"
  end
  local now = self.clock()
  local maxPlayers = Session.capacity(self.session)
  -- Keep room for handshakes without allowing an unbounded accept pass.
  local available = 2 * maxPlayers - #self.peers
  for _ = 1, math.min(available, Tcp.MAX_MESSAGES) do
    local raw, err = self.listener:accept()
    if not raw then
      if err ~= "timeout" then
        return nil, err
      end
      break
    end
    local stream = Tcp.attach(raw)
    if stream then
      self.peers[#self.peers + 1] = {
        stream = stream, joinedBy = now + HANDSHAKE_SECONDS, seq = 0, inputs = {},
      }
    end
  end
  local active = {}
  for _, peer in ipairs(self.peers) do
    local stream = peer.stream
    if not peer.playerId and not stream.closing and now >= peer.joinedBy then
      refuse(peer, "hello timeout", now)
    end
    for _, item in ipairs(stream:drain()) do
      if stream.closed or stream.closing then
        break
      end
      if not peer.playerId then
        self:join(peer, item.msg, now)
      elseif self.readActors then
        reject(peer, "observer connection is read-only")
      else
        acceptInput(peer, item.msg, maxPlayers)
      end
    end
    stream:flush()
    if stream.closing and (stream.outgoing == "" or now >= stream.deadline) then
      stream:close(stream.closing)
    end
    if stream.closed then
      -- Unapplied input belongs to the closed connection, not its reserved seat.
      if peer.playerId then
        Session.release(self.session, peer.playerId)
      end
    else
      active[#active + 1] = peer
    end
  end
  self.peers = active
  return true
end

local function solve(server)
  local inputs = {}
  for _, peer in ipairs(server.peers) do
    for _, input in ipairs(peer.inputs) do
      input.tick = server.authority.tick + 1
      inputs[#inputs + 1] = input
    end
    peer.inputs = {}
  end
  return Authority.step(server.authority, inputs)
end

-- Poll alone during setup. Begin stepping when the authority starts the encounter.
function Server:step()
  local ok, err = self:poll()
  if not ok then
    return nil, err
  end
  local result
  if self.readActors then
    local actors = self.readActors()
    assert(actors.room == nil or Room.valid(actors.room, Session.capacity(self.session)),
      "invalid observed room projection")
    self.tick = self.tick + 1
    result = { snapshot = Messages.snapshot(self.tick, actors.heroes, actors.enemies, actors.room), commands = {} }
  else
    result = solve(self)
  end
  local decisions
  if #result.commands > 0 then
    decisions = Messages.event("decisions", { tick = result.snapshot.tick, commands = result.commands })
  end
  for _, peer in ipairs(self.peers) do
    if peer.playerId then
      reply(peer, result.snapshot)
      if decisions then
        reply(peer, decisions)
      end
      peer.stream:flush()
    end
  end
  return result
end

function Server:close()
  if self.listener then
    self.listener:close()
    self.listener = nil
  end
  for _, peer in ipairs(self.peers) do
    peer.stream:close()
    if peer.playerId then
      Session.release(self.session, peer.playerId)
    end
  end
  self.peers = {}
end

return Server
