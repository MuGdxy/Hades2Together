-- Worker for net_smoke.py. Run from the repository root.
package.path = "./src/?.lua;" .. package.path
function import(path)
  return require((path:gsub("%.lua$", ""):gsub("/", ".")))
end

local socket = require("socket")

local role, directory = arg[1], arg[2]

local function mark(name, value)
  local path = directory .. "/" .. name
  local file = assert(io.open(path .. ".tmp", "w"))
  assert(file:write(tostring(value), "\n"))
  assert(file:close())
  assert(os.rename(path .. ".tmp", path))
end

local function marked(name)
  local file = io.open(directory .. "/" .. name, "r")
  if file then
    file:close()
    return true
  end
end

local function waitFor(label, poll)
  local deadline = socket.gettime() + 10
  repeat
    local value = poll()
    if value then
      return value
    end
    socket.sleep(0.01)
  until socket.gettime() >= deadline
  error("timed out waiting for " .. label)
end

local function equal(actual, expected, label)
  assert(actual == expected, label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function checkAction(actor)
  local action = assert(actor.action, "authoritative action missing")
  equal(action.name, "fixture-attack", "action")
  equal(action.phase, "active", "action phase")
  equal(action.instanceId, 7, "action instance")
end

local function countConnected(session)
  local count = 0
  for _, seat in pairs(session.slots) do
    if seat.connected then
      count = count + 1
    end
  end
  return count
end

local function serve()
  local Server = import("authority/server.lua")
  local Fake = import("hack/fake.lua")
  local engine = Fake.new()
  local received = {}
  local server
  function engine:PushInput(sendingSeat, frame)
    received[#received + 1] = { seat = sendingSeat, frame = frame, tick = server.authority.tick }
    Fake.PushInput(self, sendingSeat, frame)
  end
  function engine:ReadActors()
    local actors = Fake.ReadActors(self)
    -- Explicit fixture projection. It does not infer an action from a button.
    if actors.heroes[1] then
      actors.heroes[1].action = { name = "fixture-attack", phase = "active", instanceId = 7 }
    end
    return actors
  end
  server = assert(Server.listen(socket, 0, engine, { lootPolicy = "killer" }))
  equal(server.session.role, "serve", "role")
  equal(next(server.session.slots), nil, "no local seats")
  local enemy = engine:spawnEnemy("Guard", 100)
  mark("port", server:port())

  waitFor("four seats", function()
    assert(server:poll())
    return countConnected(server.session) == 4
  end)
  for seat = 1, 4 do
    equal(server.session.slots[seat].name, "Player" .. seat, "assigned name")
  end
  local initial = assert(server:step()).snapshot
  equal(initial.tick, 1, "initial authority tick")
  equal(initial.enemies[1].hp, 325, "initial shared HP")

  waitFor("accepted and rejected input evidence", function()
    assert(server:step())
    return #received >= 5 and marked("rejections")
  end)
  equal(#received, 5, "accepted inputs")
  local expected = {
    [1] = { 1, 0, 1 },
    [2] = { 0, 1, 2 },
    [3] = { -1, 0, 4 },
    [4] = { 0, -1, 8 },
  }
  local last = {}
  for _, entry in ipairs(received) do
    local seat, frame = entry.seat, entry.frame
    local state = seat == 1 and frame.seq == 2 and { 0, 0, 0 }
      or assert(expected[seat], "unexpected sender")
    equal(frame.playerId, seat, "input playerId")
    equal(frame.seq, (last[seat] or 0) + 1, "input order")
    last[seat] = frame.seq
    equal(frame.moveX, state[1], "moveX")
    equal(frame.moveY, state[2], "moveY")
    equal(frame.buttons, state[3], "buttons")
    equal(frame.tick, entry.tick, "server tick used at PushInput")
    assert(frame.tick >= 2)
    print(string.format("input seat=%d seq=%d tick=%d move=(%d,%d) buttons=%d",
      seat, frame.seq, frame.tick, frame.moveX, frame.moveY, frame.buttons))
  end
  for seat = 1, 4 do
    equal(last[seat], seat == 1 and 2 or 1, "accepted inputs per seat")
  end

  -- Supply one Fake damage event after all input evidence is present.
  engine:damageEnemy(enemy, initial.enemies[1].hp, 4)
  local result = assert(server:step())
  equal(#result.snapshot.heroes, 4, "heroes")
  equal(#result.snapshot.enemies, 1, "shared enemy count")
  equal(result.snapshot.enemies[1].id, enemy, "shared enemy id")
  equal(result.snapshot.enemies[1].hp, 0, "shared HP")
  equal(#result.commands, 1, "decision count")
  equal(result.commands[1].type, "OfferLoot", "decision")
  equal(engine.lastLoot.playerId, 4, "loot recipient")
  equal(engine.lastLoot.reward.source, enemy, "loot source")
  print(string.format("result tick=%d enemy=%d hp=0 loot=4", result.snapshot.tick, enemy))

  engine.enemies[enemy] = nil
  local afterDespawn = assert(server:step()).snapshot
  equal(#afterDespawn.enemies, 0, "despawn in complete snapshot")
  equal(afterDespawn.tick, result.snapshot.tick + 1, "despawn tick")
  checkAction(afterDespawn.heroes[1])

  local hero = engine.heroes[1]
  waitFor("four clean disconnects", function()
    assert(server:poll())
    return countConnected(server.session) == 0 and #server.peers == 0
  end)
  equal(#received, 5, "no rejected frames delivered")
  mark("rejoin", true)
  waitFor("original seat reconnect", function()
    assert(server:poll())
    return server.session.slots[1].connected
  end)
  equal(engine.heroes[1], hero, "reserved actor retained")
  waitFor("queued input from the new connection", function()
    assert(server:poll())
    return #server.peers == 1 and #server.peers[1].inputs == 1
  end)
  assert(server:step())
  equal(#received, 6, "accepted inputs after reconnect")
  equal(received[6].seat, 1, "rejoined sender")
  equal(received[6].frame.seq, 1, "rejoined sequence")
  equal(received[6].frame.tick, server.authority.tick, "rejoined authority tick")
  waitFor("rejoined socket close", function()
    assert(server:poll())
    return #server.peers == 0
  end)
  equal(countConnected(server.session), 0, "final connected seats")
  server:close()
  equal(select(2, server:poll()), "closed", "listener closed")
  print("four seats disconnected, seat 1 rejoined and disconnected, listener closed")
end

local function expectRejection(Client, port, name, reason)
  local probe = assert(Client.connect(socket, port, name))
  local reported
  waitFor(reason .. " and close", function()
    local items, closed = probe:poll()
    for _, item in ipairs(assert(items, closed)) do
      equal(item.kind, "error", "rejection kind")
      equal(item.msg.reason, reason, "rejection reason")
      reported = item.msg.reason
    end
    return closed
  end)
  equal(reported, reason, "error received before close")
  equal(probe.playerId, nil, "rejected seat")
  print("rejected " .. name .. ": " .. reason)
end

local function play()
  local Client = import("client/connection.lua")
  local Input = import("client/input.lua")
  local port, seat = tonumber(arg[3]), tonumber(arg[4])
  local name = "Player" .. seat
  local state = { moveX = tonumber(arg[5]), moveY = tonumber(arg[6]), buttons = tonumber(arg[7]) }
  local client = assert(Client.connect(socket, port, name))
  waitFor("assigned seat", function()
    local items, err = client:poll()
    assert(items and not err, err)
    return client.playerId
  end)
  equal(client.playerId, seat, "server-assigned seat")
  mark(name, seat)

  waitFor("initial snapshot", function()
    local items, err = client:poll()
    assert(items and not err, err)
    return client.snapshot
  end)
  -- The last client may already have read the initial snapshot with its welcome.
  assert(client.tick >= 1 and client.snapshot.enemies[1].hp == 325)
  if seat == 1 then
    expectRejection(Client, port, "Player5", "full")
    expectRejection(Client, port, name, "name already connected")
  end
  assert(client:sendInput(state))
  if seat == 1 then
    local invalid, reason = client:sendInput({ buttons = 256 })
    equal(invalid, nil, "client rejected unknown button bit")
    equal(reason, "invalid input", "client rejection reason")
    equal(client.seq, 1, "client rejection preserved sequence")
    local function submit(playerId, seq, payload)
      assert(client.transport:send("in", Input.frame(900000, playerId, payload, seq)))
    end
    local forgedState = { moveX = 1, buttons = 99 }
    submit(1, 1, forgedState)  -- duplicate
    submit(1, 2, {})           -- release all actions with a forged tick
    submit(1, 1, forgedState)  -- replay older than the last accepted frame
    submit(2, 3, forgedState)  -- connection does not own seat 2
    submit(1, 3, { moveX = 2 })
    submit(1, 3, { buttons = 257 })
    local extra = Input.frame(900000, 1, {}, 3)
    extra.action = "SpawnObstacle"
    assert(client.transport:send("in", extra))
    local errors = {}
    waitFor("rejected input responses", function()
      local items, err = client:poll()
      assert(items and not err, err)
      for _, item in ipairs(items) do
        if item.kind == "error" then
          errors[#errors + 1] = item.msg.reason
        end
      end
      return #errors >= 6
    end)
    equal(table.concat(errors, ","),
      "stale sequence,stale sequence,wrong seat,invalid input,invalid input,invalid input", "rejected inputs")
    print("rejected frames: " .. table.concat(errors, ", "))
    mark("rejections", true)
  end

  local snapshots = {}
  local decision = waitFor("authoritative decision", function()
    local items, err = client:poll()
    assert(items and not err, err)
    local result
    for _, item in ipairs(items) do
      local msg = item.msg
      if item.kind == "snap" and msg.enemies[1] and msg.enemies[1].hp == 0 then
        snapshots[msg.tick] = msg
      elseif item.kind == "error" then
        error("unexpected rejection: " .. msg.reason)
      elseif item.kind == "ev" and msg.commands[1].type == "OfferLoot" then
        result = msg
      end
    end
    return result
  end)
  local snapshot = assert(snapshots[decision.tick], "missing snapshot for decision tick")
  equal(#snapshot.heroes, 4, "snapshot hero count")
  checkAction(snapshot.heroes[1])
  for id, hero in ipairs(snapshot.heroes) do
    equal(hero.id, id, "snapshot hero ID")
    equal(hero.hp, 100, "snapshot hero HP")
  end
  equal(#snapshot.enemies, 1, "snapshot enemy count")
  equal(snapshot.enemies[1].id, 1, "snapshot enemy ID")
  equal(snapshot.enemies[1].maxHp, 325, "snapshot enemy max HP")
  equal(#decision.commands, 1, "decision count")
  equal(decision.commands[1].playerId, 4, "decision recipient")
  equal(decision.commands[1].reward.source, 1, "decision enemy ID")
  print(string.format("seat=%d result tick=%d enemy=%d hp=%d loot=4", seat, snapshot.tick,
    snapshot.enemies[1].id, snapshot.enemies[1].hp))

  local replacement = waitFor("complete view after despawn", function()
    local items, err = client:poll()
    assert(items and not err, err)
    return client.tick > snapshot.tick and client.snapshot
  end)
  equal(replacement.tick, snapshot.tick + 1, "replacement tick")
  equal(#replacement.heroes, 4, "heroes after replacement")
  equal(#replacement.enemies, 0, "the absent enemy disappeared")
  checkAction(replacement.heroes[1])
  client:close()

  if seat == 1 then
    waitFor("server to observe disconnects", function()
      return marked("rejoin")
    end)
    client = assert(Client.connect(socket, port, name))
    waitFor("reserved seat", function()
      local items, err = client:poll()
      assert(items and not err, err)
      return client.playerId
    end)
    equal(client.playerId, seat, "reserved seat reissued")
    equal(client.snapshot, nil, "no prior view on reconnect")
    assert(client:sendInput(state))
    local fresh = waitFor("first snapshot after rejoin", function()
      local items, err = client:poll()
      assert(items and not err, err)
      if client.snapshot then
        equal(#items, 1, "one snapshot suffices to bootstrap")
        equal(items[1].kind, "snap", "first message after rejoin input")
        return client.snapshot
      end
    end)
    equal(fresh.tick, replacement.tick + 1, "bootstrap tick")
    equal(#fresh.heroes, 4, "fresh heroes")
    equal(#fresh.enemies, 0, "fresh enemies")
    checkAction(fresh.heroes[1])
    print(string.format("rejoined seat=1 bootstrap tick=%d heroes=4 enemies=0 action=fixture-attack/active/7",
      fresh.tick))
    client:close()
  end
end

if role == "serve" then
  serve()
elseif role == "play" then
  play()
else
  error("expected serve or play")
end
