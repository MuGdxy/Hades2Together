-- Observe the stock hero attachment before either order of the load callbacks.
local Messages = import("protocol/messages.lua")
local HubRoom = { name = "Hub_Main" }

local function identity(game)
  return { room = game.CurrentHubRoom, generation = game.SessionState and game.SessionState.MapLoads,
    mapState = game.SessionMapState, run = game.CurrentRun }
end

local function capture(game, original, room, ...)
  local before = identity(game)
  local results = table.pack(original(room, ...))
  local after = identity(game)
  after.hero = after.run and after.run.Hero
  after.id = after.hero and after.hero.ObjectId
  return { room = room, before = before, after = after }, results
end

local function confirmed(facts)
  local room, before, after = facts.room, facts.before, facts.after
  if type(room) == "table" and room.Name == HubRoom.name and before.room == room and after.room == room
    and before.run == after.run and before.mapState == after.mapState and before.generation == after.generation
    and Messages.validTick(after.generation) and after.generation > 0
    and Messages.validTick(after.id) and after.id > 0 then
    return after
  end
end

function HubRoom.adopt(state, receiver)
  state.receiver = receiver
  if state.pending then
    state.setup = confirmed(state.pending)
    state.pending = nil
  end
end

function HubRoom.observe(state, game, original, room, ...)
  if room ~= game.CurrentHubRoom or type(room) ~= "table" or room.Name ~= HubRoom.name then
    return original(room, ...)
  end
  state.setup = nil
  local facts, results = capture(game, original, room, ...)
  state.setup = confirmed(facts)
  return table.unpack(results, 1, results.n)
end

function HubRoom.install(state, game)
  if state.installed then return end
  local original = game.SetupHeroObject
  if type(original) == "function" then
    game.SetupHeroObject = function(...)
      local receiver = state.receiver
      if receiver then return receiver:ObserveHeroSetup(original, ...) end
      -- The retained coordinator has not called its adopted Game receiver yet.
      state.pending = nil
      local facts, results = capture(game, original, ...)
      state.pending = facts
      return table.unpack(results, 1, results.n)
    end
    state.installed = true
  elseif not state.waiting and type(game.OnPreThingCreation) == "function" then
    -- RoomLogic defines SetupHeroObject before the native map-load callbacks.
    game.OnPreThingCreation({ function()
      local receiver = state.receiver
      if receiver then return receiver:InstallHubObserver() end
      HubRoom.install(state, game)
    end })
    state.waiting = true
  end
end

return HubRoom
