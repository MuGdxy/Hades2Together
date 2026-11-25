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
