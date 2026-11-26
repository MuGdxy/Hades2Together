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
  game.HeroData = { DefaultWeapon = "WeaponStaffSwing" }
  game.WeaponSets = { HeroWeaponSets = { WeaponStaffSwing = {
    "WeaponStaffSwing2", "WeaponStaffSwing3", "WeaponStaffSwing5", "WeaponStaffBall", "WeaponStaffDash" } } }
  game.CreateNewHero = function(_, args) return { Weapons={ [args.WeaponName]=true } } end
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
  local equips, capacity = {}, false
  environment.rom.data.h2t_guest_equip_staff = function(seat, load, publication, id, linked)
    local unit = assert(controller:BoundGuestUnit(seat))
    assert(unit.ObjectId == id and load == game.SessionState.MapLoads and publication == controller.guestInputs[seat].publication)
    assert(linked == game.WeaponSets.HeroWeaponSets.WeaponStaffSwing)
    if not capacity then return "insufficient stock gun capacity" end
    assert(not equips[unit], "equipped the same publication twice")
    equips[unit] = true
    return "equipped"
  end
  local function update() Guest.update(controller, environment.rom.data) end
  local function send() return controller:SubmitInput(1, 2, { moveX = 0.5 }) end
  update()
  assert(not send())
  clear = true
  update()
  assert(send())
  local accepted, detail = controller:SubmitInput(1, 2, { buttons=2 })
  assert(not accepted and detail:find("insufficient stock gun capacity", 1, true))
  assert(controller:SubmitInput(1, 2, { buttons=0 }))
  capacity = true
  assert(controller:SubmitInput(1, 2, { buttons=2 }) and equips[actor])
  Session.release(session, 2)
  controller:Step(0, 1)
  update()
  assert(controller:BindHero(2) == 900 and controller.guestInputs[2].sequence == nil and not send())
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
  assert(oldHost.revokePending and controller.guestInputs[2].reason == "retiring")
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
  assert(controller.guestInputs[2] == nil)
  game.SessionMapState.DeferredObstacleInitializationFinished = true
  controller:UpdateInputOwner()
  controller:UpdateInputOwner()
  assert(published and actor ~= oldActor and controller:BindHero(2) == 900)
  assert(equips[actor] and equips[oldActor])
  actor.Health, actor.MaxHealth = 30, 30
  assert(controller:ReadActors().heroes[2].hp == 30)
  assert(controller:BodyReport():find("load=8 publication=13", 1, true))
  assert(session.slots[2] == slot and not slot.connected and slot.connectionGeneration == generation)
  assert(controller.guestInputs[2].reason == "offline" and not send())
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
  -- The same guest ABI routes a sparse logical ID independently of the other
  -- published guest. The model supplies stock observations, not a game run.
  session.maxPlayers = 5
  assert(Session.join(session, "Fifth", 5) == 5)
  native.h2t_guest_capacity = function() return 4 end
  local fifth
  game.AttachLua = function(args)
    assert(args.Id == 905)
    fifth = args.Table
    fifth.Health, fifth.MaxHealth = 24, 30
  end
  names[905], alive[905] = "_PlayerUnit", true
  native.h2t_guest_actor = function(seat)
    if seat == 5 and not fifth then return { load=8, id=905, empty=true } end
    local body = seat == 5 and fifth or actor
    return { load=8, id=body.ObjectId, actor=body }
  end
  native.h2t_guest_owner = function(_, load, _, retain, _, seat)
    assert(retain and load==8)
    return {id=seat==5 and 905 or 900, epoch=8, publication=seat==5 and 14 or 13, inputBound=true}
  end
  native.h2t_guest_connection = function(_, pub, token, online, seat)
    assert(seat==5 and pub==14 and token==1 and online)
    return true
  end
  native.h2t_guest_clear = function(pub, token, seat) return pub==14 and token==1 and seat==5 end
  local samples = {}
  local masks = {}
  native.h2t_guest_submit = function(load, pub, token, seq, x, _, _, _, buttons, seat)
    assert(load==8 and pub==14 and token==1 and seat==5 and seq==#samples+1)
    samples[seq] = x
    masks[seq] = buttons
    return true
  end
  local script = environment.import("dev/inputs.lua").parse("5 0.5 0 0.001", Session.capacity(session))
  controller:BeginPlayback(script)
  controller:Step(0.05, 1)
  assert(controller.playing and controller.playTime==0 and #samples==0)
  update()
  controller:Step(0.05, 2)
  assert(controller:BindHero(5)==905 and samples[1]==0.5 and controller.playStarted and controller.playTime==0)
  controller:Step(0.05, 3)
  assert(not controller.playing and samples[2]==0)
  assert(controller:BindHero(2)==900 and controller:ReadActors().heroes[3].id==905)
  assert(equips[fifth] and controller:SubmitInput(4, 5, { buttons=2 }) and controller:SubmitInput(5, 5, { buttons=0 }))
  assert(masks[3]==2 and masks[4]==0)
  names[905], alive[905] = nil,nil
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

-- Replay the ordinary stock choice argument/return contract on the archived
-- Poseidon offer. The grant and actor are the game boundary in this fixture.
do
  capture.session.role = "serve+play"
  capture.session.slots[1] = { name = "Mel", connected = true }
  game.LootObjects[offer.ObjectId], game.MapState.RoomRequiredObjects[offer.ObjectId] = offer, offer
  game.MapState.ActiveObstacles[offer.ObjectId] = nil
  nativeName = offer.Name
  local data = { Name = "PoseidonWeaponBoon" }
  hero.Traits, hero.TraitDictionary, hero.BoonData = {}, {}, {}
  offer.GodLoot = true
  game.ScreenData = { UpgradeChoice = { MaxChoices = 3 } }
  local function trait(name) return { Type = "Trait", ItemName = name } end
  local stock = setmetatable({
    CurrentRun = game.CurrentRun, ScreenData = game.ScreenData, Import = function() end,
    LootData = { PoseidonUpgrade = offer }, GameState = { Flags = {} },
    TraitData = { PoseidonCastBoon = { Slot = "Ranged" }, [data.Name] = { Slot = "Melee" },
      PoseidonSpecialBoon = { Slot = "Secondary" } },
    IsFateValid = function() return false end,
  }, { __index = _G })
  if arg[1] then
    for _, name in ipairs({ "UtilityLogic", "TraitLogic", "UpgradeChoiceLogic" }) do
      assert(loadfile(arg[1] .. "/" .. name .. ".lua", "t", stock))()
    end
    offer.PriorityUpgrades = { "PoseidonCastBoon", data.Name, "PoseidonSpecialBoon" }
    stock.TraitRarityData = { BoonRarityRollOrder = {}, RarityValues = { Common = 1 } }
    stock.MetaUpgradeData = { BanUnpickedBoonsShrineUpgrade = { ChangeValue = 0 } }
    stock.IsRarityForcedCommon = function() return true end
    stock.IsGameStateEligible = function() return false end
    stock.IsTraitEligible = function() return true end
    stock.SetTraitsOnLoot(offer)
    game.CalcNumLootChoices = stock.CalcNumLootChoices
  else
    offer.UpgradeOptions = { trait("PoseidonCastBoon"), trait(data.Name), trait("PoseidonSpecialBoon") }
    game.CalcNumLootChoices = function() return hero.Traits[1] and 2 or 3 end
  end
  local roomId = capture.roomLoad.id
  local first = capture:RoomRewards()[1]
  assert(first.id == spawned.id and #first.claims == 1 and #first.claims[1].options == 3)
  assert(not capture:SelectBoon(roomId, spawned.id, 2, data.Name))
  assert(capture:SelectBoon(roomId, spawned.id, 1, data.Name))
  hero.Traits[1] = { RestrictBoonChoices = true }
  assert(not capture:SelectBoon(roomId, spawned.id, 1, data.Name))
  assert(capture:RoomRewards()[1].claims == nil)
  local screen = { Name = "UpgradeChoice", Source = offer, ChoiceMade = true }
  game.ActiveScreens, game.ScreenAnchors = { UpgradeChoice = screen }, { ChoiceScreen = screen }
  game.CurrentLootData = offer
  if arg[1] then
    stock.GetGlobalRng = function() return { Random = function() return 1 end } end
    stock.CreateUpgradeChoiceButton = function() coroutine.yield("after stock draw and sort") end
    local ok, boundary = coroutine.resume(coroutine.create(stock.CreateBoonLootButtons), screen, offer)
    assert(ok and boundary == "after stock draw and sort", tostring(boundary))
    assert(offer.UpgradeOptions[3].ItemName == "PoseidonCastBoon")
    assert(screen.BlockedIndexes[1] == nil and screen.BlockedIndexes[2] == 3)
  else
    screen.BlockedIndexes = { [2] = 3 }
  end
  assert(capture:RoomRewards()[1].claims == nil) -- indexed row still awaiting its stock lock
  offer.UpgradeOptions[3].Blocked = true -- CreateUpgradeChoiceButton's write to the sorted row
  assert(#capture:RoomRewards()[1].claims[1].options == 2)
  assert(not capture:SelectBoon(roomId, spawned.id, 1, offer.UpgradeOptions[3].ItemName))
  game.ScreenAnchors, game.ActiveScreens = {}, {}
  assert(capture:SelectBoon(roomId, spawned.id, 1, data.Name))
  offer.UpgradeOptions = { trait(data.Name), trait("PoseidonSpecialBoon"), trait("PoseidonCastBoon") }
  assert(not capture:SelectBoon(roomId, spawned.id, 1, data.Name)) -- reroll, before next snapshot
  assert(capture:RoomRewards()[1].claims == nil)
  hero.Traits, screen.BlockedIndexes = {}, {}
  local previousRoll = assert(capture:SelectBoon(roomId, spawned.id, 1, data.Name))
  offer.UpgradeOptions = { { Type = "Trait", ItemName = data.Name } }
  assert(capture:RoomRewards()[1].claims[1].state == "eligible")
  assert(assert(capture:SelectBoon(roomId, spawned.id, 1, data.Name)) ~= previousRoll)
  local button = { Index = 1, Screen = screen, LootData = offer, Data = data, Type = "Trait",
    OnPressedFunctionName = "HandleUpgradeChoiceSelection" }
  screen.UpgradeButtons = { button }
  game.ActiveScreens, game.ScreenAnchors = { UpgradeChoice = screen }, { ChoiceScreen = screen }
  game.CurrentLootData, useable = offer, false
  local args = { FromLoot = true, PreProcessedForDisplay = true, TraitData = data }
  local insert, stockGrant = false, nil
  function game.AddTraitData(recipient, selected, callArgs)
    if stockGrant then return stockGrant(recipient, selected, callArgs) end
    local trait = { Id = "original-trait-id", Name = selected.Name }
    if insert then table.insert(recipient.Traits, trait) end
    return trait, nil, "stock return"
  end
  hero.Traits = {}
  capture:Install()
  local wrapped = game.AddTraitData
  capture:Install()
  assert(game.AddTraitData == wrapped)
  local oldMeta = getmetatable(capture)
  local reloadCalls = 0
  local updated = setmetatable({ ObserveTraitGrant = function(...)
    reloadCalls = reloadCalls + 1
    return oldMeta.__index.ObserveTraitGrant(...)
  end }, oldMeta)
  setmetatable(capture, { __index = updated })
  game.AddTraitData(hero, data, args)
  assert(reloadCalls == 1 and game.AddTraitData == wrapped)
  setmetatable(capture, oldMeta)
  assert(capture:RoomRewards()[1].claims[1].state == "eligible") -- grant returned without an owned instance
  insert = true
  game.AddTraitData({ ObjectId = 123, Traits = {} }, data, args)
  button.LootData = replacement -- same ID and name, different original object
  game.AddTraitData(hero, data, args)
  assert(capture:RoomRewards()[1].claims[1].state == "eligible")
  hero.Traits, button.LootData = {}, offer
  -- Reuse the authority catalogue after removing the presentation objects.
  game.ScreenAnchors, game.ActiveScreens = {}, {}
  assert(not capture:SelectBoon(roomId + 1, spawned.id, 1, data.Name))
  assert(not capture:SelectBoon(roomId, spawned.id, 1, "NotOffered"))
  capture.session.slots[1].connected = false
  assert(not capture:SelectBoon(roomId, spawned.id, 1, data.Name))
  capture.session.slots[1].connected = true
  local intent = assert(capture:SelectBoon(roomId, spawned.id, 1, data.Name))
  local waiting = capture:RoomRewards()[1].claims[1]
  assert(waiting.state == "claiming" and waiting.selected == data.Name and waiting.choice == nil)
  assert(capture:SelectBoon(roomId, spawned.id, 1, data.Name) == intent)
  game.MapState.RoomRequiredObjects[offer.ObjectId] = replacement
  assert(not capture:SelectBoon(roomId, spawned.id, 1, data.Name))
  game.MapState.RoomRequiredObjects[offer.ObjectId] = offer
  game.ActiveScreens, game.ScreenAnchors = { UpgradeChoice = screen }, { ChoiceScreen = screen }
  if arg[1] then
    -- Use the installed game's Lua for the selection, grant, insertion and return.
    -- Engine/UI calls are doubles. Pause at LogUpgradeChoice after the grant.
    environment.import("gameplay/boon.lua").cancel(capture.roomLoad.boonOffer.reward, intent)
    setmetatable(game, { __index = _G })
    local onUsed
    game.OnUsed = function(event) onUsed = event[1] end
    for _, event in ipairs({ "OnPreThingCreation", "OnAnyLoad", "OnMenuOpened", "OnMenuCloseFinished",
      "OnActiveUseTarget", "OnActiveUseTargetLost", "OnMouseOver", "OnMouseOff" }) do game[event] = function() end end
    for _, module in ipairs({ "Main", "UILogic", "TraitLogic", "UpgradeChoiceLogic", "InteractLogic" }) do
      assert(loadfile(arg[1] .. "/" .. module .. ".lua", "t", game))()
    end
    stockGrant, game.AddTraitData = game.AddTraitData, wrapped
    game.GameState = { TraitsTaken = {} }
    game.TraitData = { [data.Name] = {} }
    local stockThread = game.thread
    for _, name in ipairs({ "EquipReferencedWeapons", "thread", "RemoveStoreItemPin",
      "UpdateHeroTraitDictionary", "ProcessHeroTraitChanges", "CheckActivatedTraits",
      "ClampSprintSpeed", "MergeWeaponDataOverride", "RecordUse", "RunEventsGeneric",
      "AddInputBlock", "RemoveInputBlock", "SetPlayerInvulnerable", "AddPlayerImmuneToForce",
      "PlayInteractAnimation", "AddTimerBlock", "RemoveTimerBlock", "GodLootPickupPresentation",
      "LootPickupPresentation", "UseableOff" }) do game[name] = function() end end
    game.DeepCopyTable = function(t)
      local copy = {}
      for k, v in pairs(t) do copy[k] = v end
      return copy
    end
    game.AreTraitsIdentical = function() return false end
    game.HeroHasTrait = function() return false end
    game.GetTraitUniqueId = function() return "fixture-unique-id" end
    local logged
    game.LogUpgradeChoice = function(clicked) logged = clicked; game.waitUnmodified(1) end

    -- Stand in for the screen layout and the native notify registration. The
    -- original Lua screen coroutine waits, resolves the button and grants.
    game.ActiveScreens, screen.ChoiceMade = {}, nil
    game.AreScreensActive = function() return next(game.ActiveScreens) ~= nil end
    game.HasResourceCost = function(cost) assert(cost == nil); return false end
    game.ShallowCopyTable = game.DeepCopyTable
    hero.IsDead, hero.UntargetableFlags, guest.Traits = false, {}, {}
    game.CurrentRun.LootTypeHistory, game.CurrentRun.LootBiomeRecord = {}, {}
    offer.OnUsedFunctionName = "UseLoot"
    game.CallFunctionName = function(name, ...)
      assert(name == "UseLoot" or name == "HandleUpgradeChoiceSelection")
      return game[name](...)
    end
    local event = "ScreenInput" .. screen.Name
    button.Id, screen.Components = 9876, { Upgrade = button }
    local nativeWait
    game.NotifyOnInteractOrControlPressed = function(args)
      assert(args.Notify == event and args.Ids[1] == button.Id); nativeWait = true
    end
    game.CancelNotify = function(args) assert(nativeWait and args.Name == event); nativeWait = false end
    local isUseable = game.IsUseable
    game.IsUseable = function(args)
      if args.Id == button.Id then return true end
      return isUseable(args)
    end
    game.IsInputAllowed = function() return true end
    game.DebugPrint = function(args) error(args.Text) end
    game.OpenUpgradeChoiceMenu = function(...)
      local source, menuArgs = ...
      assert(select("#", ...) == 2 and source == offer and next(menuArgs) == nil)
      game.ActiveScreens[screen.Name] = screen
      game.HandleScreenInput(screen)
    end
    stockThread(onUsed, { TriggeredByTable = offer, UserTable = hero })
    assert(nativeWait and game.HasWaitUntil(event))
    local offerView = capture:RoomRewards()[1].claims[1]
    local _, _, oldRound = Messages.boonScope(offerView.opportunity)
    assert(oldRound and offerView.grantOption == data.Name)
    capture.session.slots[1].connectionGeneration = 2
    assert(not capture:ClaimBoon(1, roomId, spawned.id, oldRound, data.Name) and nativeWait)
    assert(not capture:ClaimBoon(1, roomId, spawned.id, oldRound + 1, data.Name))
    local _, _, round = Messages.boonScope(capture:RoomRewards()[1].claims[1].opportunity)
    assert(round > oldRound and not capture:ClaimBoon(1, roomId, spawned.id, round, "NotOffered"))
    assert(capture:ClaimBoon(1, roomId, spawned.id, round, data.Name) == "fixture-unique-id")
    assert(logged == button and not nativeWait and not game.HasWaitUntil(event))
    assert(hero.Traits[1].Name == data.Name and hero.Traits[1].Id == "fixture-unique-id")
    assert(next(guest.Traits) == nil)
  else
    local result, gap, last = game.AddTraitData(hero, data, args)
    assert(result == hero.Traits[1] and gap == nil and last == "stock return")
  end
  game.MapState.RoomRequiredObjects[offer.ObjectId], game.LootObjects[offer.ObjectId] = nil, nil
  local roomView = capture:ReadActors().room
  local wire = assert(Codec.decode(Codec.encode(Messages.snapshot(4, {}, {}, roomView))))
  local received = wire.room.rewards[1]
  assert(environment.import("protocol/room.lua").valid(wire.room))
  assert(received.id == spawned.id and received.encounterId == spawned.encounterId and received.objectId == nil)
  assert(#received.claims == 1 and received.claims[1].state == "consumed"
    and received.claims[1].playerId == 1 and received.claims[1].choice == data.Name)
  local line = environment.import("dev/bridge.lua").claimLines(capture:RoomRewards())[1]
  assert(line:find("seat=1 state=consumed choice=PoseidonWeaponBoon", 1, true))
  assert(environment.import("dev/observer_status.lua").format(wire):find(line, 1, true))
  capture.session.slots[2].name = "Guest"
  local path = os.tmpname()
  local console = environment.import("dev/console.lua").new(capture.session)
  environment.import("hack/menu.lua").publish({ console = console, statusPath = path }, capture, "polling")
  local report = assert(io.open(path, "rb"))
  local status = report:read("*a")
  report:close()
  os.remove(path)
  assert(status:find(line, 1, true))
  game.SessionState.MapLoads = 5
  capture:OnMap(rewardRoom.Name)
  assert(capture:RoomRewards() == nil)
end

-- Replay the three coincident guest positions from room 1, TCP tick 19.
do
  local room = {}
  local firstGuestXY = { X = 6500.34180, Y = 9321.06348 }
  local locations = {
    [40000] = { X = 6145.40527, Y = 9667.50195 }, [1000002] = firstGuestXY,
    [11] = firstGuestXY, [12] = firstGuestXY, [13] = {X=6600,Y=9400},
    [14] = {X=6700,Y=9400}, [15] = {X=6800,Y=9400},
  }
  local original = environment.rom.game
  environment.rom.game = {
    GetLocation = function(args) return locations[args.Id] end,
    IdExists = function(args) return locations[args.Id] ~= nil end,
    IsLocationBlocked = function(args) assert(args.CheckUnits) return args.Id == 14 end,
    GetIds = function(args) assert(args.Name == "SpawnPoints") return {11,12,13,14,15} end,
    GetClosest = function(args)
      if args.DestinationIds then return args.DestinationIds[1] end
      return 11
    end,
  }
  local joining = {room=room,load=1}
  local controller = environment.import("hack/game.lua").new()
  controller.guestInputs = {
    [2]={room=room,load=1,id=1000002,slot={connected=false}},
    [3]={room=room,load=1,pendingSpawn=13}, [4]=joining,
  }
  assert(controller:GuestSpawnPoint(40000, joining) == 15)
  locations[15] = firstGuestXY
  assert(controller:GuestSpawnPoint(40000, joining) == nil)
  locations[1000002] = {X=6510,Y=9350}
  assert(controller:GuestSpawnPoint(40000, joining) == 11)
  environment.rom.game = original
end

-- A combat reward is anchored by the yielding encounter call's actual return.
-- A lookalike in the maps alone and an old call finishing after a load both fail.
do
  local encounter = { Name = "GeneratedF", Completed = false }
  local room = { Name = "F_Combat02", Encounter = encounter, ChangeReward = "Boon", ForceLootName = "PoseidonUpgrade" }
  local source = { ObjectId = 912, Name = "PoseidonUpgrade", GodLoot = true }
  local map = { RewardPointsUsed = {}, RoomRequiredObjects = { [912] = source } }
  local g = {
    CurrentRun = { CurrentRoom = room, Hero = { ObjectId = 40000 } },
    SessionState = { MapLoads = 1 }, SessionMapState = { DeferredObstacleInitializationFinished = true },
    MapState = map, LootObjects = { [912] = source },
    IdExists = function(id) return id.Id == 912 end, IsUseable = function(id) return id.Id == 912 end,
    GetName = function() return source.Name end,
    RoomData = {}, RewardData = {}, RoomRewardPreSpawnPresentation = function() end,
    SelectRoomRewardSpawnPoint = function() return 715 end, GetAngleBetween = function() return 0 end,
    CalcOffset = function() return { X = 0, Y = 0 } end, wait = coroutine.yield,
    CheckBoonSkipShrineUpgrade = function() end, GiveLoot = function(args)
      assert(args.ForceLootName == source.Name and args.SpawnPoint == 40000)
      return source
    end,
    GetTotalHeroTraitValue = function() return 0 end, UseHeroTraitsWithValue = function() end,
    RoomRewardSpawnPresentation = function() end, CheckShrineBounties = function() end, CheckRandomBounties = function() end,
  }
  g.CurrentRun.Hero.Traits = {}
  if arg[1] then
    assert(loadfile(arg[1] .. "/RewardLogic.lua", "t", setmetatable(g, { __index = _G })))()
  else
    g.SpawnRoomReward = function()
      coroutine.yield()
      map.RewardPointsUsed[40000] = source.ObjectId
      return source
    end
  end
  local originalGame = environment.rom.game
  environment.rom.game = g
  local adapter = environment.import("hack/game.lua").new(environment.import("protocol/session.lua").new("serve+play"), 1)
  adapter:OnMap(room.Name)
  adapter:Install()
  map.RewardPointsUsed[40000] = 912
  assert(adapter:RoomRewards() == nil)
  local function spawn()
    local co = coroutine.create(function() assert(g.SpawnRoomReward(encounter) == source) end)
    assert(coroutine.resume(co))
    assert(coroutine.status(co) == "suspended")
    return co
  end
  local stale = spawn()
  g.SessionState.MapLoads = 2
  adapter:OnMap(room.Name)
  assert(coroutine.resume(stale))
  assert(adapter:RoomRewards() == nil)
  local current = spawn()
  assert(coroutine.resume(current))
  local row = assert(adapter:RoomRewards()[1])
  assert(row.objectId == source.ObjectId and row.kind == source.Name)
  environment.rom.game = originalGame
end

print("live actor projection passed")
