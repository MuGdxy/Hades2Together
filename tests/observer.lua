local socket = require("socket")
local environment = setmetatable({}, { __index = _G })
local modules = {
  ["authority/loop.lua"] = setmetatable({}, {
    __index = function(_, name) error("observer used legacy authority: " .. name) end,
  }),
}

function environment.import(path)
  if not modules[path] then
    modules[path] = assert(loadfile("src/" .. path, "t", environment))()
  end
  return modules[path]
end

local Server = environment.import("authority/server.lua")
local Client = environment.import("client/connection.lua")
local Codec = environment.import("protocol/codec.lua")
local reads = 0
local server = assert(Server.observe(socket, 0, function()
  reads = reads + 1
  return {
    heroes = { { id = 40000, hp = 30 - reads } }, enemies = {},
    room = {
      id = 1, name = "F_Combat01", leaving = false, exitsUnlocked = false,
      encounter = { id = 1, name = "FIntroFight", completed = false },
      exits = { { id = 42, readyToUse = false, inUse = false } },
    },
  }
end))
local client = assert(Client.connect(socket, server:port(), "Observer"))

local function waitForSnapshot(earlierTick, expectedError)
  local rejection
  for _ = 1, 100 do
    local result = assert(server:step())
    assert(result.snapshot.tick == reads and #result.commands == 0)
    local items = assert(client:poll())
    for _, item in ipairs(items) do
      assert(item.kind == "welcome" or item.kind == "snap" or item.kind == "error")
      if item.kind == "error" then
        rejection = item.msg.reason
      end
    end
    if client.snapshot and client.tick > earlierTick and rejection == expectedError then
      assert(client.tick == result.snapshot.tick)
      assert(Codec.encode(client.snapshot) == Codec.encode(result.snapshot))
      assert(client.snapshot.room.name == "F_Combat01" and client.snapshot.room.id == 1)
      assert(client.snapshot.room.encounter.name == "FIntroFight" and not client.snapshot.room.exits[1].readyToUse)
      return
    end
    socket.sleep(0.005)
  end
  error("observer did not receive a fresh full snapshot")
end

waitForSnapshot(0)
local seat, tick = client.playerId, client.tick
assert(seat == 1)
assert(client:sendInput({ moveX = 1, buttons = 1 }))
waitForSnapshot(tick, "observer connection is read-only")
tick = client.tick
client:close()
assert(server:poll())
client = assert(Client.connect(socket, server:port(), "Observer"))
waitForSnapshot(tick)
assert(client.playerId == seat)
client:close()
server:close()
local result, failure = server:step()
assert(result == nil and failure == "closed")
print("read-only TCP snapshots passed")

modules["authority/loop.lua"] = nil
modules["authority/server.lua"] = nil
Server = environment.import("authority/server.lua")
local Session = environment.import("protocol/session.lua")
local Console = environment.import("dev/console.lua")
local Inputs = environment.import("dev/inputs.lua")
local engine = environment.import("hack/fake.lua").new()
local readActors = engine.ReadActors
function engine:ReadActors()
  local actors = readActors(self)
  actors.room = {
    id = 1, name = "F_Combat01", leaving = false, exitsUnlocked = false,
    participants = { 1, 5 },
    rewards = { { id = 1, encounterId = 1, kind = "Boon",
      claims = { { playerId = 5, state = "eligible" } } } },
  }
  return actors
end
server = assert(Server.listen(socket, 0, engine, { maxPlayers = 5, stockRules = true }))

local session = Session.new("serve+play", server.session.maxPlayers)
assert(Session.join(session, "Host") == 1)
local script = Inputs.parse("name 5 Guest\n5 0.5 0 1\n6 1 0 1", session.maxPlayers)
assert(script.steps[6] == nil and Session.join(session, script.names[5], 5) == 5)
assert(select(2, Session.join(session, "Another", 5)) == "seat occupied")
assert(select(2, Session.join(session, "Guest", 2)) == "name reserved at another seat")
local console = Console.new(session)
assert(Console.roster(console) == "1:Host:up 5:Guest:up")
assert(Console.execute(console, "player remove 5") == "OK offline 5 Guest")
assert(Console.execute(console, "player add Guest") == "OK rejoined 5 Guest")
assert(session.slots[5].connectionGeneration == 2)
for seat = 2, 4 do
  assert(session.slots[seat] == nil)
end

local peers = {}
for seat = 1, 5 do
  peers[seat] = assert(Client.connect(socket, server:port(), "Player" .. seat))
end
local overflow = assert(Client.connect(socket, server:port(), "Overflow"))
local function advanceUntil(condition)
  for _ = 1, 100 do
    assert(server:step())
    for _, peer in ipairs(peers) do
      assert(peer:poll())
    end
    if condition() then return end
    socket.sleep(0.005)
  end
  error("configured TCP session did not advance")
end
local rejection
advanceUntil(function()
  for _, item in ipairs(assert(overflow:poll())) do
    if item.kind == "error" then
      rejection = item.msg.reason
    end
  end
  for seat, peer in ipairs(peers) do
    if not peer.snapshot then return false end
    assert(peer.playerId == seat and peer.maxPlayers == 5)
    assert(#peer.snapshot.heroes == 5 and peer.snapshot.heroes[5].id == 5)
    assert(peer.snapshot.room.rewards[1].claims[1].playerId == 5)
  end
  return rejection == "full"
end)
overflow:close()
peers[2]:close()
assert(server:poll())
assert(not server.session.slots[2].connected)
local x, y, active = Inputs.stick(script, 5, 0)
assert(active)
assert(Console.execute(console, ("input 5 %s %s Attack2"):format(x, y), function(seat, sample)
  assert(seat == 5)
  return peers[seat]:sendInput(sample)
end) == "OK input 5")
peers[2] = assert(Client.connect(socket, server:port(), "Player2"))
advanceUntil(function() return engine.inputs[5] and peers[2].snapshot end)
assert(engine.inputs[5].playerId == 5 and engine.inputs[5].moveX == 0.5 and engine.inputs[5].buttons == 2)
assert(peers[2].playerId == 2 and server.session.slots[2].connectionGeneration == 2)
for _, peer in ipairs(peers) do
  peer:close()
end
server:close()
print("configured five-seat TCP, sparse script and CLI passed")
