local environment = setmetatable({}, { __index = _G })
local modules = {}

function environment.import(path)
  if not modules[path] then
    modules[path] = assert(loadfile("src/" .. path, "t", environment))()
  end
  return modules[path]
end

local function unit(id, hp, maxHp)
  return { ObjectId = id, Health = hp, MaxHealth = maxHp }
end

local hero = unit(40000, 30, 40)
local brawler = unit(12, 6, 255)
local guard = unit(21, 60, 60)
local team = { 21, 12, 21, 40000, 30, 31, 32, 33, 34, 35, 36, 37 }
local names = { [40000] = "_PlayerUnit", [12] = "Brawler", [21] = "Guard",
  [31] = "RemovedGuard", [32] = "Guard", [33] = "Guard", [34] = "Guard", [36] = "Guard", [37] = "Guard" }
local alive = { [40000] = true, [12] = true, [21] = true, [31] = false,
  [32] = true, [33] = true, [34] = true, [35] = true, [36] = true, [37] = true }
local game = {
  CurrentRun = { CurrentRoom = { Name = "F_Combat01" }, Hero = hero },
  ActiveEnemies = {
    [21] = guard, [12] = brawler, [40000] = hero,
    [30] = unit(30, 0, 0), -- Props can be registered by stock SetupUnit.
    [31] = unit(31, 60, 60), -- The engine has stopped reporting it alive.
    [32] = { ObjectId = 32, Health = 0, MaxHealth = 60, IsDead = true },
    [33] = unit(999, 60, 60), -- Stale table under a different engine ID.
    [34] = unit(34, math.huge, 60),
    [35] = unit(35, 60, 60), -- Location can default even if the ID no longer exists.
    [36] = unit(36, 60, 60), -- Invalid position.
    [37] = unit(37, -1, 60),
    [99] = unit(99, 15, 15), -- Tracked but outside EnemyTeam.
  },
  GetIds = function(args)
    assert(args.Name == "EnemyTeam")
    return team
  end,
  GetName = function(args) return names[args.Id] end,
  IsAlive = function(args) return alive[args.Id] end,
  GetLocation = function(args)
    return { X = args.Id == 36 and math.huge or args.Id + 0.5, Y = -2 }
  end,
  GetAngle = function(args)
    return args.Id == 21 and math.huge or 0
  end,
}
environment.rom = { game = game }
local capture = environment.import("hack/game.lua").new({ slots = { [2] = { connected = true } } })
local Codec = environment.import("protocol/codec.lua")
local Messages = environment.import("protocol/messages.lua")

local first = capture:ReadActors()
assert(#first.heroes == 1 and #first.enemies == 2)
assert(first.heroes[1].id == 40000 and first.heroes[1].hp == 30 and first.heroes[1].maxHp == 40)
assert(first.heroes[1].facing == 0 and first.heroes[1].alive)
assert(first.enemies[1].id == 12 and first.enemies[1].kind == "Brawler")
assert(first.enemies[1].x == 12.5 and first.enemies[1].y == -2 and first.enemies[1].hp == 6)
assert(first.enemies[2].id == 21 and first.enemies[2].facing == nil)
assert(first.enemies[1].action == nil and first.enemies[1].phase == nil and first.enemies[1].actionInstance == nil)
-- A reserved guest remains a stock world actor while its connection is down.
local guest = unit(1000002, 24, 30)
names[guest.ObjectId], alive[guest.ObjectId] = "_PlayerUnit", true
game.SessionState = { MapLoads = 1 }
environment.rom.data = { h2t_guest_actor = function() return { id = guest.ObjectId, load = 1, actor = guest } end }
capture.session.slots[2].connected = false
local offline = capture:ReadActors()
assert(offline.heroes[2].id == guest.ObjectId and offline.heroes[2].hp == 24)
guest.Health = 19
local oldLocation = game.GetLocation
game.GetLocation = function(args)
  if args.Id == guest.ObjectId then return { X = 11, Y = 22 } end
  return oldLocation(args)
end
local later = capture:ReadActors()
local received = assert(Codec.decode(Codec.encode(Messages.snapshot(2, later.heroes, later.enemies))))
assert(received.heroes[2].id == guest.ObjectId and received.heroes[2].hp == 19 and received.heroes[2].x == 11)
hero.Health = nil
local onlyGuest = capture:ReadActors()
local dense = assert(Codec.decode(Codec.encode(Messages.snapshot(3, onlyGuest.heroes, onlyGuest.enemies))))
assert(#dense.heroes == 1 and dense.heroes[1].id == guest.ObjectId)
hero.Health = 30
capture.session.slots[2].connected = true
assert(capture:ReadActors().heroes[2].y == 22)
game.SessionState.MapLoads = 2
assert(capture:ReadActors().heroes[2] == nil)
environment.rom.data, game.SessionState, game.GetLocation = nil, nil, oldLocation

-- Drive the normal Game API over a modeled published owner; the native callback
-- replay separately exercises the original reader boundary and receipt latch.
do
  local Session = environment.import("protocol/session.lua")
  local session = Session.new("serve+play")
  Session.join(session, "host")
  Session.join(session, "guest")
  local controller = environment.import("hack/game.lua").new(session)
  local calls, actor, clear, lastSeq = {}, nil, false, 0
  game.SessionState = { MapLoads = 7 }
  game.GetConfigOptionValue = function() return false end
  game.IsInputAllowed = function() return true end
  game.HeroData = { DefaultWeapon = "staff" }
  game.CreateNewHero = function() return {} end
  game.AttachLua = function(args) assert(args.Id == 900) actor = args.Table end
  environment.rom.data = {
    h2t_active_submit = function() error("unexpected primary sample") end,
    h2t_guest_owner = function(id, load, _, retain)
      assert(id == hero.ObjectId and load == 7 and retain)
      return { id = 900, epoch = load, publication = 12, inputBound = true, sequence = lastSeq }
    end,
    h2t_guest_actor = function() return { id = 900, load = 7, empty = actor == nil, actor = actor } end,
    h2t_guest_connection = function(load, pub, token, online)
      assert(load == 7 and pub == 12)
      calls[#calls+1] = (online and "+" or "-") .. token
      clear = false
      return true
    end,
    h2t_guest_clear = function() return clear end,
    h2t_guest_submit = function(load, pub, token, seq)
      assert(load == 7 and pub == 12 and token == session.slots[2].connectionGeneration)
      lastSeq = seq
      return true
    end,
  }
  local Guest = environment.import("hack/guest_input.lua")
  local function update() Guest.update(controller, environment.rom.data) end
  local function send() return controller:SubmitInput(1, 2, { moveX = 0.5 }) end
  update()
  assert(not send())
  clear = true
  update()
  assert(send())
  Session.release(session, 2)
  controller:Step(0, 1)
  update()
  assert(controller:BindHero(2) == 900 and controller.guestInput.sequence == nil and not send())
  Session.join(session, "guest")
  assert(not send())
  clear = true
  update()
  assert(send())
  Session.release(session, 2)
  Session.join(session, "guest")
  assert(not send())
  clear = true
  update()
  hero.IsDead = true
  local hostDisconnects = 0
  controller.hostInput = { slot=session.slots[1], room=game.CurrentRun.CurrentRoom,
    hero=hero, id=hero.ObjectId, load=7, bound=true, connectionGeneration=1, lastToken=1, token=1,
    native={ h2t_active_disconnect=function() hostDisconnects=hostDisconnects+1 return true end } }
  controller:Step(0, 2)
  assert(hostDisconnects == 1 and controller.hostInput.phase == "host actor unavailable"
    and controller.hostInput.bound and not controller.hostInput.failure)
  assert(send() and controller:BindHero(2) == 900)
  hero.IsDead = nil
  assert(table.concat(calls, ",") == "+1,-1,+2,-2,+3")

  -- A normal LeaveRoom changes CurrentRoom before OnPreThingCreation increments
  -- MapLoads. The engine can issue the same numeric ObjectId in the next World.
  local native = environment.rom.data
  local slot = session.slots[2]
  Session.release(session, 2)
  Guest.check(controller)
  local generation, oldRoom, oldActor = slot.connectionGeneration, game.CurrentRun.CurrentRoom, actor
  local oldHost = controller.hostInput
  local closed, reclaimed, published = false, false, false
  oldHost.native.h2t_active_revoke = function(load) assert(load == 7) return closed end
  native.h2t_guest_owner = function(id, load, point, retain)
    if not retain then
      assert(load == 7 and not published)
      return { epoch = reclaimed and 0 or 7, status = reclaimed and "empty" or "retiring" }
    end
    if point ~= 0 then
      assert(reclaimed and load == 8 and point == 77 and controller.hostInput.bound)
      published = true
    end
    if published then return { epoch=8, id=900, publication=13, inputBound=true } end
    return { epoch=0, status="empty" }
  end
  native.h2t_guest_actor = function()
    if not reclaimed then return { load=7, id=900, actor=oldActor } end
    if published then return { load=8, id=900, actor=actor, empty=actor == nil } end
    return {}
  end
  native.h2t_sampler_install = function() assert(closed and game.SessionState.MapLoads == 8) return "ready" end
  native.h2t_sampler_observe = function()
    return { outcome="complete", owner_same=true, stock_same=true, direct_neutral=true, sample_neutral=true, handler_neutral=true }
  end
  native.h2t_sampler_arm = function() error("existing pads should be reused") end
  native.h2t_sampler_resume = function() return true end
  native.h2t_active_bind = function(id, load) assert(id == hero.ObjectId and load == 8) return true end
  native.h2t_active_connect = function() return true end
  native.h2t_active_clear = function() return true end
  native.h2t_active_audit = function() return { valid=true, complete=true, batch=1 } end
  native.h2t_active_revoke = oldHost.native.h2t_active_revoke
  controller.guestResource = true -- registered when the first room owner was created
  controller.GuestSpawnPoint = function() return 77 end
  game.SessionMapState = { DeferredObstacleInitializationFinished=true }
  controller:OnMap(oldRoom.Name)
  oldActor.Health, oldActor.MaxHealth = 21, 30
  names[900], alive[900] = "_PlayerUnit", true
  assert(controller:ReadActors().heroes[2].hp == 21)
  game.CurrentRun.CurrentRoom = { Name=oldRoom.Name }
  assert(not controller:BindHero(2) and not controller:ReadActors().heroes[2])
  controller:UpdateInputOwner()
  assert(oldHost.revokePending and controller.guestInput.reason == "retiring")
  closed = true
  controller:UpdateInputOwner()
  assert(controller.hostInput == oldHost and not oldHost.revokePending)
  game.SessionState.MapLoads = 8
  game.SessionMapState = {}
  controller:OnMap(oldRoom.Name)
  controller:UpdateInputOwner()
  assert(controller.hostInput == oldHost and not published)
  reclaimed, actor = true, nil
  controller:UpdateInputOwner()
  assert(controller.guestInput == nil)
  game.SessionMapState.DeferredObstacleInitializationFinished = true
  controller:UpdateInputOwner()
  controller:UpdateInputOwner()
  assert(published and actor ~= oldActor and controller:BindHero(2) == 900)
  actor.Health, actor.MaxHealth = 30, 30
  assert(controller:ReadActors().heroes[2].hp == 30)
  assert(controller:BodyReport():find("load=8 publication=13", 1, true))
  assert(session.slots[2] == slot and not slot.connected and slot.connectionGeneration == generation)
  assert(controller.guestInput.reason == "offline" and not send())
  native.h2t_guest_connection = function(load, pub, token, online)
    assert(load == 8 and pub == 13 and token == generation + 1 and online)
    return true
  end
  native.h2t_guest_submit = function(load, pub, token)
    assert(load == 8 and pub == 13 and token == slot.connectionGeneration)
    return true
  end
  Session.join(session, "guest")
  clear = false
  update()
  assert(not send())
  clear = true
  update()
  assert(send())
  game.CurrentRun.CurrentRoom = oldRoom
  names[900], alive[900] = nil, nil
  environment.rom.data, game.SessionState, game.SessionMapState = nil, nil, nil
end

local encoded = Codec.encode(Messages.snapshot(1, first.heroes, first.enemies))
local restored = assert(Codec.decode(encoded))
assert(restored.heroes[1].id == 40000 and restored.enemies[2].id == 21)

team[1], team[2] = team[2], team[1]
local reordered = capture:ReadActors()
assert(Codec.encode(Messages.snapshot(1, reordered.heroes, reordered.enemies)) == encoded)

hero.Health = 0
hero.IsDead = true
game.ActiveEnemies[12] = nil
team = { 21, 12 }
local nextView = capture:ReadActors()
assert(#nextView.enemies == 1 and nextView.enemies[1].id == 21)
assert(nextView.heroes[1].hp == 0 and nextView.heroes[1].alive == false)
assert(first.heroes[1].hp == 30 and first.heroes[1].alive and #first.enemies == 2)

team = {}
assert(#capture:ReadActors().enemies == 0)
names[40000] = nil
assert(#capture:ReadActors().heroes == 0)
game.CurrentRun = nil
local empty = capture:ReadActors()
assert(#empty.heroes == 0 and #empty.enemies == 0)

local combat = { Name = "FIntroFight", Completed = false }
local omitted = { ObjectId = 40, ReadyToUse = true, InUse = true }
local locked = { ObjectId = 42 }
local ready = { ObjectId = 41, ReadyToUse = true, InUse = true, Room = { Name = "F_Combat02" } }
local room = { Name = "F_Combat01", Encounter = combat }
game.CurrentRun = { CurrentRoom = room, Hero = hero }
game.SessionState = { MapLoads = 1 }
game.SessionMapState = {}
game.MapState = {
  OfferedExitDoors = { [42] = locked, [41] = ready, [40] = omitted, [99] = locked },
  RoomRequiredObjects = { [43] = { ObjectId = 43 } },
}
game.IdExists = function(args) return args.Id ~= 40 end
assert(capture:ReadActors().room == nil)
capture:OnMap("F_Combat01")
assert(capture:ReadActors().room == nil)
game.SessionMapState.DeferredObstacleInitializationFinished = true
local opened = assert(capture:ReadActors().room)
assert(opened.id == 1 and opened.name == "F_Combat01" and not opened.leaving and not opened.exitsUnlocked)
assert(opened.encounter.id == 1 and not opened.encounter.completed and opened.encounter.name == "FIntroFight")
assert(#opened.exits == 2 and opened.exits[1].id == 41 and opened.exits[2].id == 42)
assert(opened.exits[1].readyToUse and opened.exits[1].inUse and opened.exits[1].destination == "F_Combat02")
assert(not opened.exits[2].readyToUse and not opened.exits[2].inUse and opened.exits[2].destination == nil)
assert(opened.participants == nil and opened.rewards == nil)
assert(environment.import("protocol/room.lua").valid(opened))

combat.Completed = true
room.ExitsUnlocked = true
room.Leaving = true
capture:OnMap("F_Combat01") -- duplicate notification for the same load
local leaving = assert(capture:ReadActors().room)
assert(leaving.id == opened.id and leaving.encounter.id == opened.encounter.id)
assert(leaving.encounter.completed and leaving.leaving and leaving.exitsUnlocked)
assert(not opened.encounter.completed and not opened.leaving)
room.Encounter = { Name = "FIntroFight", Completed = false }
assert(capture:ReadActors().room.encounter.id == 2)
room.Encounter.Completed = nil
assert(capture:ReadActors().room.encounter == nil)

-- Stock can assign a new entry to the same map before unloading the old map.
local revisit = { Name = room.Name, Encounter = { Name = combat.Name, Completed = false } }
game.CurrentRun.CurrentRoom = revisit
assert(capture:ReadActors().room == nil)
game.SessionState.MapLoads = 2
game.SessionMapState = {}
game.MapState = { OfferedExitDoors = {} }
capture:OnMap("F_Combat01")
assert(capture:ReadActors().room == nil)
game.SessionMapState.DeferredObstacleInitializationFinished = true
local afterLoad = assert(capture:ReadActors().room)
assert(afterLoad.id == 2 and afterLoad.name == room.Name and #afterLoad.exits == 0)
assert(afterLoad.encounter.id == 1 and not afterLoad.encounter.completed)

-- Native can also reload with the same room object. The load still has a new ID.
game.SessionState.MapLoads = 3
assert(capture:ReadActors().room == nil)
game.SessionMapState = { DeferredObstacleInitializationFinished = true }
game.MapState = { OfferedExitDoors = { [42] = locked } }
game.IdExists = nil
capture:OnMap("F_Combat02")
assert(capture:ReadActors().room == nil)
capture:OnMap("F_Combat01")
local unavailableExits = assert(capture:ReadActors().room)
assert(unavailableExits.id == 3 and unavailableExits.exits == nil)
assert(environment.import("protocol/room.lua").valid(unavailableExits))

local rewardEncounter = { Name = "HealthRestore" }
local rewardRoom = {
  Name = "F_Reprieve01", Encounter = rewardEncounter, SpawnRewardOnId = 40055,
  OfferedRewards = { [42] = { Type = "Boon", ForceLootName = "ZeusUpgrade" } },
}
local offer = { ObjectId = 2000032, Name = "PoseidonUpgrade" }
game.CurrentRun.CurrentRoom = rewardRoom
game.SessionState.MapLoads = 4
game.SessionMapState = { DeferredObstacleInitializationFinished = true }
game.MapState = { OfferedExitDoors = {}, RewardPointsUsed = {}, RoomRequiredObjects = {} }
game.LootObjects = { [offer.ObjectId] = offer }
local exists, useable, nativeName = true, true, offer.Name
game.IdExists = function(args) assert(args.Id == offer.ObjectId); return exists end
game.IsUseable = function(args) assert(args.Id == offer.ObjectId); return useable end
game.GetName = function(args)
  if args.Id == offer.ObjectId then return nativeName end
  return names[args.Id]
end
capture:OnMap("F_Reprieve01")
assert(capture:ReadActors().room.rewards == nil) -- door preview alone
game.MapState.RewardPointsUsed[40055] = offer.ObjectId
game.MapState.RoomRequiredObjects[offer.ObjectId] = { ObjectId = offer.ObjectId }
assert(capture:ReadActors().room.rewards == nil) -- unrelated identity
game.MapState.RoomRequiredObjects[offer.ObjectId] = offer
offer.SpawnPointId = 40055
assert(capture:ReadActors().room.rewards == nil) -- shop marker
offer.SpawnPointId = nil
nativeName = "DifferentObject"
assert(capture:ReadActors().room.rewards == nil)
nativeName = offer.Name
exists = false
assert(capture:ReadActors().room.rewards == nil)
exists = true
local beforeCompletion = capture:ReadActors().room
local spawned = assert(beforeCompletion.rewards[1])
assert(beforeCompletion.encounter == nil and spawned.encounterId == 1 and spawned.id == 1)
assert(spawned.kind == "PoseidonUpgrade" and spawned.objectId == offer.ObjectId)
assert(spawned.claims == nil and beforeCompletion.participants == nil)
assert(environment.import("protocol/room.lua").valid(beforeCompletion))
rewardEncounter.Completed = true
local afterCompletion = capture:ReadActors().room
assert(afterCompletion.encounter.completed and afterCompletion.encounter.id == spawned.encounterId)
assert(afterCompletion.rewards[1].id == spawned.id)
useable = false
game.CurrentLootData = offer
assert(capture:ReadActors().room.rewards == nil) -- no claim inferred from a pickup
useable = true
assert(capture:ReadActors().room.rewards[1].id == spawned.id)
local replacement = { ObjectId = offer.ObjectId, Name = offer.Name }
game.MapState.RoomRequiredObjects[offer.ObjectId], game.LootObjects[offer.ObjectId] = replacement, replacement
assert(capture:ReadActors().room.rewards[1].id == 2) -- reused engine ID, different original object
local consumable = { ObjectId = offer.ObjectId, Name = "MaxHealthDrop" }
game.MapState.RoomRequiredObjects[offer.ObjectId] = consumable
game.LootObjects[offer.ObjectId] = nil
game.MapState.ActiveObstacles = { [offer.ObjectId] = consumable }
nativeName = consumable.Name
assert(capture:ReadActors().room.rewards == nil) -- room-required obstacle alone
consumable.IgnorePurchase = true
consumable.PurchaseRequirements = {}
assert(capture:ReadActors().room.rewards == nil)
game.LootObjects[offer.ObjectId] = consumable
assert(capture:ReadActors().room.rewards == nil, "dual registration survives failed purchase gating")
consumable.PurchaseRequirements = nil
assert(capture:ReadActors().room.rewards == nil) -- ambiguous registration
game.LootObjects[offer.ObjectId] = nil
local observedConsumable = assert(capture:ReadActors().room.rewards[1])
assert(observedConsumable.id == 3 and observedConsumable.encounterId == spawned.encounterId)
assert(observedConsumable.kind == "MaxHealthDrop" and observedConsumable.objectId == offer.ObjectId)
assert(observedConsumable.claims == nil)

print("live actor projection passed")
