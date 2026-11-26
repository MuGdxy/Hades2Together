-- Stock-observation contract fixture. Run through net_smoke.py --stock-room.
package.path = "./src/?.lua;" .. package.path
function import(path)
  return require((path:gsub("%.lua$", ""):gsub("/", ".")))
end

local socket = require("socket")
local Support = dofile("tests/net_smoke_support.lua")
local mark, marked, waitFor, equal = Support.mark, Support.marked, Support.waitFor, Support.equal

local phases = {
  "combat", "reward offered", "claim in progress", "reward consumed",
  "door ready", "leaving", "next room",
}

-- Each phase comes from the test boundary, never from a network request.
local function fixtureRoom(phase)
  local room = {
    id = phase == 7 and 2 or 1,
    name = "FixtureRoom",
    participants = { 1, 2, 3, 4 },
    encounter = { id = 1, name = "FixtureEncounter", completed = phase >= 4 and phase < 7 },
    exitsUnlocked = phase >= 4 and phase < 7,
    leaving = phase == 6,
    exits = { { id = 42, readyToUse = phase == 5 or phase == 6, inUse = phase == 6 } },
    rewards = {},
  }
  if phase >= 2 and phase < 7 then
    local reward = { id = 1, encounterId = 1, objectId = phase < 4 and 43 or nil, kind = "FixtureBoon", claims = {} }
    for seat = 1, 4 do
      local state = "eligible"
      if phase >= 4 then
        state = "consumed"
      elseif phase == 3 and seat == 2 then
        state = "claiming"
      end
      reward.claims[seat] = {
        playerId = seat, state = state, choice = state == "consumed" and "FixtureChoice" .. seat or nil,
      }
    end
    room.rewards[1] = reward
  end
  if phase == 5 or phase == 6 then
    room.exits[1].destination = "FixtureRoom"
  end
  return room
end

local function serve()
  local Fake = import("hack/fake.lua")
  local Server = import("authority/server.lua")
  local engine = Fake.new()
  local room
  function engine:ReadActors()
    local actors = Fake.ReadActors(self)
    actors.room = room
    return actors
  end

  local server = assert(Server.listen(socket, 0, engine, { stockRules = true }))
  local enemy = engine:spawnEnemy("Guard", 100)
  mark("port", server:port())
  waitFor("assigned seats and their inputs", function()
    assert(server:poll())
    if #server.peers ~= 4 then
      return false
    end
    for _, peer in ipairs(server.peers) do
      if not peer.playerId or #peer.pending ~= 1 then
        return false
      end
    end
    return true
  end)

  for phase, label in ipairs(phases) do
    room = fixtureRoom(phase)
    if phase == 2 then
      engine:damageEnemy(enemy, 100, 4)
    elseif phase == 7 then
      engine.enemies[enemy] = nil
    end
    local result = assert(server:step())
    equal(result.snapshot.tick, phase, "authority tick")
    equal(#result.commands, 0, "stock commands")
    equal(#engine.calls, 0, "unmodified game simulation")
    equal(engine.lastLoot, nil, "no legacy grant")
    for seat = 1, 4 do
      equal(engine.inputs[seat].buttons, 2 ^ (seat - 1), "distinct input for seat " .. seat)
    end
    waitFor(label .. " broadcast", function()
      assert(server:poll())
      for seat = 1, 4 do
        if not marked("phase-" .. phase .. "-" .. seat) then
          return false
        end
      end
      return true
    end)
  end
  waitFor("clean disconnects", function()
    assert(server:poll())
    return #server.peers == 0
  end)
  equal(#engine.calls, 0, "no network-triggered stock operation")
  equal(engine.lastLoot, nil, "no network-triggered grant")
  server:close()
  print("result tick=7 room=2 previous=1 consumed=4")
end

local function play()
  local Client = import("client/connection.lua")
  local port, seat = tonumber(arg[3]), tonumber(arg[4])
  local name = "Player" .. seat
  local client = assert(Client.connect(socket, port, name))
  local function poll()
    local items, err = client:poll()
    assert(items and not err, err)
    return items
  end
  waitFor("assigned seat", function()
    poll()
    return client.playerId
  end)
  equal(client.playerId, seat, "assigned seat")
  assert(client:sendInput({ buttons = tonumber(arg[7]) }))
  mark(name, seat)
  local consumed = 0

  for phase, label in ipairs(phases) do
    local snapshot = waitFor(label, function()
      poll()
      return client.tick == phase and client.snapshot
    end)
    local room = assert(snapshot.room)
    equal(#room.participants, 4, "membership count")
    for index = 1, 4 do
      equal(room.participants[index], index, "participant seat")
    end
    equal(room.encounter.id, 1, "room-scoped encounter")
    equal(room.encounter.completed, phase >= 4 and phase < 7, "stock encounter completed")
    equal(room.exits[1].id, 42, "room-scoped door")
    equal(room.exits[1].readyToUse, phase == 5 or phase == 6, "door readiness")
    equal(room.exits[1].inUse, phase == 6, "door use")
    equal(room.exitsUnlocked, phase >= 4 and phase < 7, "stock unlock has separate timing")
    equal(room.leaving, phase == 6, "confirmed departure")
    equal(room.id, phase == 7 and 2 or 1, "room instance")
    equal(room.name, "FixtureRoom", "repeated room name")

    if phase == 1 then
      equal(snapshot.enemies[1].id, 1, "enemy identity")
      equal(snapshot.enemies[1].hp, 100, "stock HP")
      equal(#room.rewards, 0, "no offer during this combat sample")
    elseif phase == 7 then
      equal(#snapshot.enemies, 0, "previous room enemies removed")
      equal(#room.rewards, 0, "previous room offers removed")
    else
      equal(snapshot.enemies[1].hp, 0, "shared combat result")
      equal(snapshot.enemies[1].maxHp, 100, "HP was never scaled")
      local reward = assert(room.rewards[1])
      equal(reward.id, 1, "same offer")
      equal(reward.encounterId, 1, "offer encounter")
      equal(#reward.claims, 4, "one claim state per eligible seat")
      consumed = 0
      for index, claim in ipairs(reward.claims) do
        equal(claim.playerId, index, "claim ownership")
        if phase >= 4 then
          equal(claim.state, "consumed", "durable receipt")
          equal(claim.choice, "FixtureChoice" .. index, "per-seat outcome")
          consumed = consumed + 1
        else
          equal(claim.state, phase == 3 and index == 2 and "claiming" or "eligible", "claim precondition")
          equal(claim.choice, nil, "uncommitted choice")
        end
      end
    end

    if seat == 1 and phase == 7 then
      local obsolete = { t = "reward_claim", roomId = 1, encounterId = 1, rewardId = 1, playerId = 1 }
      assert(client.transport:send(obsolete.t, obsolete))
      waitFor("obsolete claim rejection", function()
        for _, item in ipairs(poll()) do
          if item.kind == "error" then
            equal(item.msg.reason, "invalid input", "no grant request ingress")
            return true
          end
        end
      end)
    end
    mark("phase-" .. phase .. "-" .. seat, true)
  end
  print(string.format("result tick=%d room=%d previous=1 consumed=%d", client.tick, client.snapshot.room.id, consumed))
  client:close()
end

if arg[1] == "serve" then
  serve()
else
  play()
end
