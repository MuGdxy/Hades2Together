-- Phase 0 tests. Run from the repository root:
--   lua tests/run.lua

local arg0 = arg and arg[0] or "tests/run.lua"
local root = arg0:match("^(.*)[/\\]tests[/\\]run%.lua$")
if not root or root == "" then
  root = "."
end

package.path = root .. "/src/?.lua;" .. root .. "\\src\\?.lua;" .. package.path

import = function(path)
  local name = path:gsub("%.lua$", ""):gsub("[/\\]", ".")
  return require(name)
end

local failures = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name)
    print(tostring(err))
  end
end

local function eq(actual, expected, label)
  if actual ~= expected then
    error((label or "assert") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

local function deepEqual(a, b)
  if type(a) ~= type(b) then
    return false
  end
  if type(a) ~= "table" then
    return a == b
  end
  for key, value in pairs(a) do
    if not deepEqual(value, b[key]) then
      return false
    end
  end
  for key in pairs(b) do
    if a[key] == nil then
      return false
    end
  end
  return true
end

local Party = import("gameplay/party.lua")
local Death = import("gameplay/death.lua")
local Scaling = import("gameplay/scaling.lua")
local Loot = import("gameplay/loot.lua")
local Session = import("protocol/session.lua")
local Messages = import("protocol/messages.lua")
local Codec = import("protocol/codec.lua")
local Engine = import("hack/engine.lua")
local Fake = import("hack/fake.lua")
local Game = import("hack/game.lua")
local Authority = import("authority/loop.lua")
local Loopback = import("net/loopback.lua")
local Transport = import("net/transport.lua")
local Input = import("client/input.lua")
local Console = import("dev/console.lua")
local Bridge = import("dev/bridge.lua")

test("party holds four and refuses a fifth", function()
  local party = Party.new()
  for id = 1, 4 do
    local ok = Party.add(party, id)
    eq(ok, true)
  end
  local ok, err = Party.add(party, 5)
  eq(ok, false)
  eq(err, "party full")
  eq(Party.aliveCount(party), 4)
end)

test("one hero down continues, a wipe ends the run", function()
  local party = Party.new()
  Party.add(party, 1)
  Party.add(party, 2)
  local commands = Death.onHeroDown(party, 2)
  eq(commands[1].type, "HeroDown")
  eq(Party.aliveCount(party), 1)
  commands = Death.onHeroDown(party, 1)
  eq(commands[1].type, "EndRun")
  eq(commands[1].reason, "wipe")
  eq(#Death.onHeroDown(party, 1), 0)
end)

test("enemy health scales once per extra player", function()
  eq(Scaling.hpMultiplier(1), 1)
  eq(Scaling.hpMultiplier(2), 1.75)
  eq(Scaling.hpMultiplier(4), 3.25)
  eq(Scaling.hitPoints(100, 3), 250)
end)

test("loot policies skip dead players", function()
  local party = Party.new()
  Party.add(party, 1)
  Party.add(party, 2)
  Party.add(party, 3)
  Party.kill(party, 1)

  local context = { killerId = 1 }
  eq(Loot.assign(party, "host", context), 2)
  eq(Loot.assign(party, "killer", context), 2)

  context = { cursor = 1 }
  eq(Loot.assign(party, "round_robin", context), 2)
  eq(Loot.assign(party, "round_robin", context), 3)
  eq(Loot.assign(party, "round_robin", context), 2)
end)

test("session seats stick to a name", function()
  local session = Session.new("serve+play")
  eq(Session.isAuthority(session), true)
  eq(Session.loadsClient(session), true)
  eq(Session.isAuthority(Session.new("play")), false)
  eq(Session.loadsClient(Session.new("serve")), false)

  local slot = Session.join(session, "mel")
  eq(slot, 1)
  eq(Session.join(session, "nem"), 2)
  Session.release(session, 2)
  eq(Session.join(session, "nem"), 2)
  Session.join(session, "hec")
  Session.join(session, "chronos")
  local full, reason = Session.join(session, "typhon")
  eq(full, nil)
  eq(reason, "full")
end)

test("codec roundtrips a snapshot", function()
  local snapshot = Messages.snapshot(3, {
    { id = 1, hp = 40, name = "a;b=c" },
  }, {
    { id = 9, hp = 0, kind = "Guard" },
  })
  local encoded = Codec.encode(snapshot)
  local decoded, err = Codec.decode(encoded)
  if not decoded then
    error(err)
  end
  if not deepEqual(decoded, snapshot) then
    error("snapshot changed across the codec")
  end
  eq(Messages.accepts(1), true)
  eq(Messages.accepts(2), false)
end)

test("loopback delivers an input to the authority side", function()
  local client, server = Loopback.pair()
  eq(#Transport.check(client), 0)
  local frame = Input.frame(4, 2, { moveX = -1, moveY = 1, buttons = 8 })
  client:send("in", frame)
  local inbox = server:drain()
  eq(#inbox, 1)
  eq(inbox[1].kind, "in")
  eq(inbox[1].msg.playerId, 2)
  eq(inbox[1].msg.moveX, -1)
  eq(#client:drain(), 0)
end)

test("two attackers share one enemy health bar", function()
  local engine = Fake.new()
  local auth = Authority.start(engine, { lootPolicy = "round_robin" })
  eq(Authority.addPlayer(auth, 1), true)
  eq(Authority.addPlayer(auth, 2), true)
  local enemyId = engine:spawnEnemy("Guard", 100)

  local first = Authority.step(auth, {
    Input.frame(1, 1, { moveX = 1 }),
    Input.frame(1, 2, { moveX = -1 }),
  })
  eq(engine.enemies[enemyId].maxHp, 175)
  eq(#first.snapshot.enemies, 1)
  eq(engine.inputs[1].moveX, 1)
  eq(engine.inputs[2].moveX, -1)

  engine:damageEnemy(enemyId, 25, 1)
  engine:damageEnemy(enemyId, 50, 2)
  local mid = Authority.step(auth, {})
  eq(engine.enemies[enemyId].hp, 100)
  eq(mid.snapshot.enemies[1].hp, 100)
  eq(engine.lastLoot, nil)

  engine:damageEnemy(enemyId, 100, 2)
  Authority.step(auth, {})
  eq(engine.enemies[enemyId].hp, 0)
  -- round_robin starts at the lowest living id, whoever landed the kill
  eq(engine.lastLoot.playerId, 1)
  eq(engine.lastLoot.reward.source, enemyId)
end)

test("a wipe is decided by gameplay and applied by the engine", function()
  local engine = Fake.new()
  local auth = Authority.start(engine, {})
  Authority.addPlayer(auth, 1)
  Authority.addPlayer(auth, 2)
  Authority.step(auth, {})

  engine:damageHero(2, 100)
  local down = Authority.step(auth, {})
  eq(auth.ended, false)
  eq(down.commands[1].type, "HeroDown")
  eq(Party.aliveCount(auth.party), 1)

  engine:damageHero(1, 100)
  local wipe = Authority.step(auth, {})
  eq(wipe.commands[1].type, "EndRun")
  eq(auth.ended, true)
  eq(engine.ended, "wipe")
end)

test("binding a seat outside the live game does not spawn", function()
  eq(#Engine.check(Game), 0)
  eq(#Engine.check(Fake.new()), 0)
  eq(Game:BindHero(2, { name = "Fake1" }), nil)
  eq(Game.pending[2].name, "Fake1")
  local ok, err = pcall(function()
    Game:SetCamera({})
  end)
  eq(ok, false)
  if not tostring(err):find("phase 1", 1, true) then
    error("expected phase 1 refusal, got " .. tostring(err))
  end
end)

test("dev console adds and drops fake players", function()
  local session = Session.new("serve+play")
  eq(Session.join(session, "Mel"), 1)
  local console = Console.new(session)
  eq(Console.execute(console, "player add"), "OK joined 2 Fake1")
  eq(Console.execute(console, "player add Second Mel"), "OK joined 3 Second Mel")
  eq(Console.execute(console, "players"), "OK 1:Mel:up 2:Fake1:up 3:Second Mel:up")
  eq(Console.execute(console, "player remove Fake1"), "OK dropped 2 Fake1")
  eq(Console.execute(console, "player add"), "OK joined 2 Fake2")
  eq(Console.execute(console, "player remove 9"), "ERR not found")
  eq(Console.execute(console, "enter"), "OK enter F_Test")
  eq(console.enterMap, "F_Test")
  eq(Console.execute(console, "enter F_Combat01"), "OK enter F_Combat01")
  eq(Console.execute(console, "enter Bad-Map"), "ERR bad map")
  eq(Console.execute(console, "nope"), "ERR unknown command")
  local status = Console.execute(console, "status")
  eq(status:find("role=serve+play", 1, true) ~= nil, true)
  eq(status:find("players=3", 1, true) ~= nil, true)
end)

test("queued commands add a fake player", function()
  local session = Session.new("serve+play")
  Session.join(session, "Mel")
  local console = Console.new(session)
  local results = Bridge.applyLines(console, { "player add Second Mel", "" })
  eq(results[1], "OK joined 2 Second Mel")
  eq(Bridge.statusText(console):find("2:Second Mel:up", 1, true) ~= nil, true)
end)

test("rules modules do not touch the game", function()
  local allowed = {
    ["hack/game.lua"] = true,
    ["main.lua"] = true,
    ["ready.lua"] = true,
    ["reload.lua"] = true,
    ["def.lua"] = true,
    ["config.lua"] = true,
  }
  local banned = { "CurrentRun", "Path.Wrap", "Path.Override", "modutil", "rom.game", "rom%.log" }
  local command
  if package.config:sub(1, 1) == "\\" then
    command = 'dir /s /b "' .. root .. '\\src\\*.lua"'
  else
    command = 'find "' .. root .. '/src" -name "*.lua"'
  end
  local pipe = io.popen(command)
  if not pipe then
    error("cannot list src")
  end
  local listed = pipe:read("*a")
  pipe:close()
  local seen = 0
  for path in listed:gmatch("[^\r\n]+") do
    seen = seen + 1
    local relative = path:gsub("\\", "/"):match("src/(.+)$")
    local file = io.open(path, "rb")
    local source = file:read("*a")
    file:close()
    if not allowed[relative] then
      for _, token in ipairs(banned) do
        local plain = token:gsub("%%", "")
        if source:find(plain, 1, true) then
          error(relative .. " contains " .. plain)
        end
      end
    end
  end
  if seen < 10 then
    error("expected to scan the src tree, saw " .. tostring(seen))
  end
end)

if failures > 0 then
  print(failures .. " failed")
  os.exit(1)
end

print("all passed")
