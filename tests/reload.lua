local function readSource(root, name)
  local file = assert(io.open(root .. "/src/" .. name, "rb"))
  local source = assert(file:read("*a"))
  file:close()
  return source
end

local function mockLoader(root)
  local mock = { edits = {}, frames = {}, imports = {}, maps = {}, warnings = {},
    info = {}, polls = 0, clock = 0, entered = {}, inputs = {}, forbiddenCalls = {},
    locations = {}, threads = {}, allowSave = false }
  local controlPath = "mock-home\\Hades2Together\\"
  local commandsPath = controlPath .. "commands.txt"
  local statusPath = controlPath .. "status.txt"
  local files = {
    [controlPath .. "inputs.txt"] = "2 1 0 0.05\n2 0 1 5\n",
    ["mock-content/Maps/F_Test.map_text"] = "",
    ["mock-content/Maps/F_Combat01.map_text"] = "",
  }

  local game = { RoomData = { F_Test = { DebugOnly = true }, F_Combat01 = {} } }
  function game.StartNewGame() end
  function game.GetConfigOptionValue(args)
    assert(args.Name == "AllowSaveLoad")
    return mock.allowSave
  end
  function game.thread(fn)
    local co = coroutine.create(fn)
    mock.threads[#mock.threads + 1] = co
    assert(coroutine.resume(co))
  end
  function game.OnAnyLoad(args)
    mock.maps[#mock.maps + 1] = args[1]
  end
  function game.GetLocation(args)
    return mock.locations[args.Id] or { X = 0, Y = 0 }
  end
  for _, method in ipairs({ "SpawnObstacle", "SpawnUnit", "Move", "Stop", "Teleport", "SendControlInput",
    "SetAnimation", "SetAngle", "SetGoalAngle" }) do
    game[method] = function()
      mock.forbiddenCalls[#mock.forbiddenCalls + 1] = method
      error("unexpected call to " .. method)
    end
  end
  function game.LoadMap(args)
    mock.entered[#mock.entered + 1] = args.Name
  end
  mock.game = game

  local public = setmetatable({ _PLUGIN = { plugins_mod_folder_path = root .. "/src" } }, {
    __index = _G,
  })
  public.captureInput = function(seat, frame)
    mock.inputs[#mock.inputs + 1] = { seat = seat, frame = frame }
    return true
  end
  public.require = function(name)
    assert(name == "socket")
    return mock.observerSocket
  end
  public.bindObserver = function(socket, port, readActors)
    assert(socket == mock.observerSocket and port == 0)
    mock.observerStarts = (mock.observerStarts or 0) + 1
    return {
      port = function() return 12345 end,
      clock = function() return mock.clock end,
      step = function()
        mock.observed = readActors()
        mock.observerTick = (mock.observerTick or 0) + 1
        return { snapshot = {
          tick = mock.observerTick, heroes = mock.observed.heroes,
          enemies = mock.observed.enemies, room = mock.observed.room,
        } }
      end,
    }
  end
  local private = setmetatable({ public = public }, { __index = public })
  public.rom = {
    game = game,
    paths = { Content = function() return "mock-content" end },
    gui = { add_always_draw_imgui = function(fn) mock.frames[#mock.frames + 1] = fn end },
    on_import = { pre = function(fn) mock.imports[#mock.imports + 1] = fn end },
    mods = { ["LuaENVY-ENVY"] = { auto = function()
      -- ENVY binds each entry chunk to the same private environment on reload.
      local fn = debug.getinfo(2, "f").func
      local index = 1
      while debug.getupvalue(fn, index) ~= "_ENV" do
        assert(debug.getupvalue(fn, index))
        index = index + 1
      end
      debug.upvaluejoin(fn, index, function() return private end, 1)
    end } },
    log = {
      info = function(line) mock.info[#mock.info + 1] = line end,
      warning = function(line) mock.warnings[#mock.warnings + 1] = line end,
      error = error,
    },
  }
  mock.rom = public.rom
  public.io = { open = function(path, mode)
    if path == statusPath and mode == "wb" and mock.statusError then
      error(mock.statusError, 0)
    end
    if mode == "rb" and files[path] == nil then
      return nil
    end
    if mode == "wb" then
      files[path] = ""
    end
    return {
      read = function() return files[path] end,
      write = function(_, chunk)
        files[path] = (files[path] or "") .. chunk
        return true
      end,
      close = function() return true end,
    }
  end }
  public.os = {
    getenv = function() return "mock-home" end,
    clock = function() return mock.clock end,
    rename = function(from, to)
      assert(from == commandsPath)
      mock.polls = mock.polls + 1
      if mock.pollError then
        error(mock.pollError, 0)
      end
      if files[from] == nil or files[to] ~= nil then
        return nil
      end
      files[to], files[from] = files[from], nil
      return true
    end,
    remove = function(path) files[path] = nil end,
  }

  private.import = function(path, env)
    -- Like ENVY 1.2.1, every import compiles the current file in the supplied
    -- environment or the plugin's private environment.
    return assert(load(mock.edits[path] or readSource(root, path), "@" .. path, "t", env or private))()
  end
  private.import_as_fallback = function(fallback)
    getmetatable(private).__index = function(_, key)
      local value = fallback[key]
      if value ~= nil then
        return value
      end
      return public[key]
    end
  end
  private._G = private

  function mock:reload()
    -- Hell2Modding clears both loader callback lists, keeps the plugin
    -- environment and reruns main.lua. The game's OnAnyLoad list survives.
    self.frames, self.imports = {}, {}
    assert(loadfile(root .. "/src/main.lua", "t", public))()
  end

  function mock:poll(time)
    self.clock = time
    for _, frame in ipairs(self.frames) do
      frame()
    end
    return files[statusPath] or ""
  end

  function mock:queue(text)
    files[commandsPath] = text
  end

  function mock:status()
    return files[statusPath]
  end

  function mock:removeMapAsset(mapName)
    files["mock-content/Maps/" .. mapName .. ".map_text"] = nil
  end

  function mock:setInputs(text)
    files[controlPath .. "inputs.txt"] = text
  end

  return mock
end

return function(root, test, eq)
  test("observer bootstrap preserves its listener and only reads the game", function()
    local mod = mockLoader(root)
    mod.observerSocket = {}
    mod.edits["config.lua"] = "return { observerSnapshots = true, port = 0 }"
    mod.edits["authority/server.lua"] = "return { observe = bindObserver }"
    mod.edits["hack/menu.lua"] = [[
      local function forbidden() error("observer used CLI game controls") end
      return { new = forbidden, pump = forbidden, publish = forbidden }
    ]]
    local game = readSource(root, "hack/game.lua"):gsub("return Game\n", [[
      local function forbidden() error("observer used a game write method") end
      Game.BindHero, Game.PushInput, Game.Step = forbidden, forbidden, forbidden
      local read = Game.ReadActors
      Game.ReadActors = function(self)
        local sample = read(self)
        sample.version = VERSION
        return sample
      end
      return Game
    ]])
    mod.edits["hack/game.lua"] = game:gsub("VERSION", '"first"')
    mod:reload()
    assert(mod:status():find("snapshot=waiting", 1, true))
    mod.game.CurrentRun = { CurrentRoom = {
      Name = "F_Combat01", Encounter = { Name = "FIntroFight", Completed = false },
    } }
    mod.game.SessionState = { MapLoads = 1 }
    mod.game.SessionMapState = { DeferredObstacleInitializationFinished = true }
    eq(#mod.maps, 1)
    mod.maps[1]({ name = "F_Combat01" })
    local firstStatus = mod:poll(0)
    assert(firstStatus:find("Read-only observer (one native hero)\ntick=1\n", 1, true), firstStatus)
    assert(firstStatus:find("room=F_Combat01 id=1", 1, true), firstStatus)
    assert(firstStatus:find("encounter=FIntroFight id=1 completed=false", 1, true), firstStatus)
    eq(mod.observed.version, "first")
    eq(mod.observed.room.id, 1)
    eq(mod.observed.room.encounter.id, 1)
    eq(mod.observerStarts, 1)
    eq(#mod.frames, 1)
    eq(mod.polls, 0)
    eq(#mod.warnings, 0)

    mod.edits["hack/game.lua"] = game:gsub("VERSION", '"second"')
    mod:reload()
    mod:poll(0.01)
    eq(mod.observed.version, "first")
    mod:poll(0.06)
    eq(mod.observed.version, "second")
    eq(mod.observerTick, 2)
    eq(mod:status(), firstStatus)
    eq(mod.observed.room.id, 1)
    eq(mod.observed.room.encounter.id, 1)
    eq(mod.observerStarts, 1)
    eq(#mod.frames, 1)
    eq(#mod.maps, 1)
    eq(mod.polls, 0)
    eq(#mod.warnings, 0)
    mod.statusError = "fixture status sink failed"
    eq(mod:poll(0.26), firstStatus)
    eq(mod.observerTick, 3)
    eq(#mod.warnings, 0)
    mod.statusError = nil
    mod.edits["dev/observer_status.lua"] = "error('invalid optional status edit')"
    mod:reload()
    local recovered = mod:poll(0.52)
    assert(recovered:find("tick=4\n", 1, true), recovered)
    eq(#mod.warnings, 0)
    eq(mod.observerStarts, 1)

    mod.edits["dev/observer_status.lua"] = "return 17"
    mod.edits["hack/game.lua"] = game:gsub("VERSION", '"third"')
    mod:reload()
    local afterMalformedReturn = mod:poll(0.78)
    assert(afterMalformedReturn:find("tick=5\n", 1, true), afterMalformedReturn)
    eq(mod.observed.version, "third")
    eq(mod.observerStarts, 1)
    eq(#mod.frames, 1)
    eq(#mod.warnings, 0)
  end)

  test("observer status formats only the fields supplied by the authoritative snapshot", function()
    local Status = import("dev/observer_status.lua")
    local snapshot = {
      tick = 42, heroes = { { id = 40000, hp = 19.5, maxHp = 30 } },
      enemies = { { id = 1000001, hp = 0, maxHp = 255, kind = "Brawler" } },
      room = {
        id = 2, name = "F_Combat01", leaving = false, exitsUnlocked = true,
        exits = {
          { id = 10, readyToUse = false, inUse = false },
          { id = 20, readyToUse = true, inUse = true, destination = "F_Reprieve01" },
        },
      },
    }
    local first = Status.format(snapshot)
    assert(first:find("tick=42\n", 1, true))
    assert(first:find("encounter=unavailable\n", 1, true))
    assert(first:find("hero id=40000 hp=19.5/30\n", 1, true))
    assert(first:find("enemy id=1000001 hp=0/255 kind=Brawler\n", 1, true))
    assert(first:find("door id=10 readyToUse=false inUse=false\n", 1, true))
    assert(first:find("door id=20 readyToUse=true inUse=true destination=F_Reprieve01\n", 1, true))
    eq(first:find("reward", 1, true), nil)
    snapshot.room.rewards = { { id = 3, kind = "PoseidonUpgrade", encounterId = 2, objectId = 2000032 } }
    local reward = Status.format(snapshot)
    assert(reward:find("reward id=3 kind=PoseidonUpgrade encounterId=2 objectId=2000032\n", 1, true))
    snapshot.room.exits = {}
    assert(Status.format(snapshot):find("doors=none\n", 1, true))
    snapshot.room = nil
    local loading = Status.format(snapshot)
    assert(loading:find("room=unavailable\n", 1, true))
    assert(loading:match("observerStatus=complete\n$"))
    eq(loading:find("door ", 1, true), nil)
    eq(loading:find("reward", 1, true), nil)
  end)

  test("loader reload preserves playback input frames and installs one control poll", function()
    local mod = mockLoader(root)
    mod.game.CurrentRun = { CurrentRoom = { Name = "F_Test" }, Hero = { ObjectId = 99 } }
    mod.game.GameState = { IllegalConversationModification = true }
    local gameSource, replacements = readSource(root, "hack/game.lua")
      :gsub("function Game:PushInput%(playerId, frame%).-\nend",
        "function Game:PushInput(playerId, frame)\n  return captureInput(playerId, frame)\nend")
    eq(replacements, 1)
    mod.edits["hack/game.lua"] = gameSource
    mod:reload()
    eq(#mod.frames, 1)
    eq(#mod.imports, 0)
    local onMap = assert(mod.maps[1])
    mod:queue("player add Guest\nenter F_Test\nplay\n")
    local first = mod:poll(0)
    assert(first:find("OK play", 1, true), first)
    eq(#mod.entered, 0)
    assert(first:find("enter=ready F_Test", 1, true), first)
    mod:poll(0.03125)
    eq(#mod.inputs, 2)
    eq(mod.inputs[1].seat, 2)
    eq(mod.inputs[1].frame.t, "in")
    eq(mod.inputs[1].frame.playerId, 2)
    eq(mod.inputs[1].frame.tick, 1)
    eq(mod.inputs[1].frame.seq, 1)
    eq(mod.inputs[2].frame.moveX, 1)
    eq(mod.inputs[2].frame.moveY, 0)

    mod.edits["hack/game.lua"] = gameSource
      :gsub('"bodies hero="', '"bodies updated hero="')
      :gsub('return table.concat%(parts, " "%)', 'return table.concat(parts, " ") .. " map=" .. tostring(self.map)')
      :gsub("self.map = name", 'self.map = name .. "-updated"')
    mod.edits["dev/inputs.lua"] = readSource(root, "dev/inputs.lua")
      :gsub("return step.mx, step.my, true", "return step.mx, -step.my, true")
    mod:queue("player add Guest\n")
    mod:reload()
    mod:reload()
    eq(#mod.frames, 1)
    eq(#mod.imports, 0)
    eq(#mod.maps, 1)
    eq(mod.maps[1], onMap)
    eq(mod.polls, 2)
    eq(mod.info[#mod.info], "[Hades2Together] Lua reloaded")

    local updated = mod:poll(0.0625)
    assert(updated:find("bodies updated hero=99", 1, true), updated)
    assert(updated:find("OK rejoined 2 Guest", 1, true), updated)
    eq(#mod.inputs, 3)
    eq(mod.inputs[3].frame.tick, 3)
    eq(mod.inputs[3].frame.seq, 3)
    eq(mod.inputs[3].frame.moveX, 0)
    eq(mod.inputs[3].frame.moveY, -1)
    eq(mod.polls, 3)
    eq(#mod.forbiddenCalls, 0)
    eq(#mod.entered, 0)
    local nextReport = mod:poll(0.09375)
    assert(nextReport:find("OK rejoined 2 Guest", 1, true), nextReport)
    onMap({ name = "NewRoom" })
    local changedMap = mod:poll(0.125)
    assert(changedMap:find("map=NewRoom-updated", 1, true), changedMap)
    eq(#mod.warnings, 0)
  end)

  test("CLI sends validated held samples and release through the playback input contract", function()
    local mod = mockLoader(root)
    mod.game.CurrentRun = { CurrentRoom = { Name = "F_Combat01" }, Hero = { ObjectId = 99 } }
    local source = readSource(root, "hack/game.lua")
    mod.edits["hack/game.lua"] = source:gsub("function Game:PushInput%(playerId, frame%).-\nend",
      "function Game:PushInput(playerId, frame)\n  return captureInput(playerId, frame)\nend")
    mod:reload()
    mod:queue(table.concat({
      "help",
      "input 1 -0.5 1 Attack1 Rush Attack1",
      "input 1 0 0",
      "input 1 0 0 SpawnObstacle",
      "input 1 0 0 256",
      "input 1 \rinput 1 0 0 Attack1",
      "input 1 1.1 0 Attack2",
      "input 1 0",
      "input 5 0 0",
      "input 2 0 0",
    }, "\r\n"))
    local report = mod:poll(0)
    assert(report:find("V1 actions: Attack1 Attack2 Attack3 Rush Use Shout Select Cancel", 1, true), report)
    assert(report:find("ERR unknown input action SpawnObstacle", 1, true), report)
    assert(report:find("ERR unknown input action 256", 1, true), report)
    assert(report:find("ERR expected one command per line", 1, true), report)
    assert(report:find("ERR input axes must be numbers in [-1,1]", 1, true), report)
    assert(report:find("ERR input seat must be 1-4", 1, true), report)
    assert(report:find("ERR input seat 2 is disconnected", 1, true), report)
    eq(#mod.inputs, 2)
    local held, release = mod.inputs[1].frame, mod.inputs[2].frame
    eq(held.t, "in")
    eq(held.tick, 1)
    eq(held.playerId, 1)
    eq(held.seq, 1)
    eq(held.moveX, -0.5)
    eq(held.moveY, 1)
    eq(held.aimX, 0)
    eq(held.aimY, 0)
    eq(held.buttons, 9)
    eq(release.buttons, 0)
    eq(release.seq, 2)

    mod:queue("player remove 1\ninput 1 1 0\nplayer add Player\ninput 1 0 0\n")
    local rejoined = mod:poll(0.03125)
    assert(rejoined:find("OK offline 1 Player\nERR input seat 1 is disconnected\nOK rejoined 1 Player\nOK input 1", 1, true), rejoined)
    eq(#mod.inputs, 3)
    eq(mod.inputs[3].frame.seq, 3)
    eq(mod.inputs[3].frame.moveX, 0)

    mod:setInputs("1 2 0 1\n1 0 1 1\n")
    mod:queue("play\n")
    mod:poll(0.0625)
    eq(#mod.inputs, 4)
    local playback = mod.inputs[4].frame
    eq(playback.tick, 3)
    eq(playback.seq, 4)
    eq(playback.moveX, 0)
    eq(playback.moveY, 1)
    eq(playback.buttons, 0)
  end)

  test("host sampler binds neutral, submits canonical frames and revokes on disconnect", function()
    local mod = mockLoader(root)
    mod.game.CurrentRun = { CurrentRoom = { Name = "Room" }, Hero = { ObjectId = 91 } }
    mod.game.SessionState = { MapLoads = 7 }
    mod.game.IsInputAllowed = function() return true end
    local calls, submitted = {}, {}
    local function record(name, result)
      return function(...)
        calls[#calls + 1] = name
        return result
      end
    end
    local trace = { outcome = "zero_pads" }
    mod.rom.data = {
      h2t_sampler_install = record("install", "ready"),
      h2t_sampler_observe = function(id) eq(id, 91) return trace end,
      h2t_sampler_arm = record("arm", "attached"),
      h2t_active_bind = function(id, epoch)
        eq(id, 91) eq(epoch, 7) return record("bind", true)()
      end,
      h2t_active_connect = record("connect", true), h2t_active_clear = record("clear", true),
      h2t_active_audit = function() return { batch = 3, valid = true, complete = true, sequence = 0 } end,
      h2t_active_revoke = record("revoke", true),
      h2t_active_submit = function(...)
        submitted[#submitted + 1] = {...}
        return true
      end,
    }
    mod:reload()
    mod:queue("input 1 1 0\n")
    assert(mod:poll(0):find("ERR input unsupported waiting for stock pad recognition", 1, true))
    trace = { outcome = "complete", stock_same = true, owner_same = true,
      direct_neutral = true, handler_neutral = true, sample_neutral = true }
    mod:poll(0.02)
    mod:reload()
    mod:queue("input 1 0.8 0 Attack2\nplayer add Guest\ninput 2 1 0\ninput 1 0 0 Rush\n")
    local report = mod:poll(0.04)
    assert(report:find("OK input 1", 1, true))
    assert(report:find("seat 2 has no native player input slot", 1, true))
    assert(report:find("ERR input unsupported host sampler supports", 1, true))
    for i, value in ipairs({7, 2, 0.8, 0, 0, 0, 2}) do eq(submitted[1][i], value) end
    mod.game.IsInputAllowed = function() return false end
    mod:queue("input 1 0 0\nplayer remove 1\nplayer add Other\ninput 1 1 0\n")
    local offline = mod:poll(0.06)
    assert(offline:find("OK offline 1 Player\nOK joined 3 Other\nERR input seat 1 is disconnected", 1, true), offline)
    assert(mod:poll(0.08):find("hostInput=host owner changed", 1, true))
    for i, value in ipairs({7, 4, 0, 0, 0, 0, 0}) do eq(submitted[2][i], value) end
    eq(#submitted, 2)
    eq(table.concat(calls, ","), "install,arm,bind,connect,clear,revoke")
  end)

  test("live CLI playback refuses unsupported seats without spawning or moving actors", function()
    local mod = mockLoader(root)
    mod.game.CurrentRun = { CurrentRoom = { Name = "F_Combat01" }, Hero = { ObjectId = 99 } }
    mod.locations[99] = { X = 12, Y = 34 }
    mod:setInputs("1 1 0 1\n2 0 1 1\n")
    mod:reload()
    mod:queue("input 1 0 0 Attack1\nplay\n")
    local unsupported = mod:poll(0)
    assert(unsupported:find("hero=99:x=12:y=34", 1, true), unsupported)
    assert(unsupported:find("play=unsupported the retail Lua API cannot submit native player movement", 1, true), unsupported)
    assert(unsupported:find("ERR input unsupported the retail Lua API cannot submit native player movement", 1, true), unsupported)
    assert(unsupported:find("2:P2:unsupported", 1, true), unsupported)
    mod:reload()
    eq(mod:poll(1), unsupported)

    mod:setInputs("2 1 0 1\n")
    mod:queue("play\n")
    local extraSeat = mod:poll(2)
    assert(extraSeat:find("play=unsupported seat 2 has no native player input slot", 1, true), extraSeat)
    eq(mod:poll(3), extraSeat)
    eq(#mod.forbiddenCalls, 0)
    eq(#mod.warnings, 0)
  end)

  test("a bad edit keeps the last good control pump and a corrected edit replaces it", function()
    local mod = mockLoader(root)
    local loadMap = mod.game.LoadMap
    mod.game.LoadMap = nil
    mod:reload()
    mod:queue("player add\nenter F_Test\n")
    local waiting = mod:poll(0)
    assert(waiting:find("2:Fake1:up", 1, true), waiting)
    assert(waiting:find("enter=waiting", 1, true), waiting)

    mod.edits["dev/console.lua"] = "local broken ="
    mod:queue("player add\n")
    mod:reload()
    eq(#mod.warnings, 1)
    assert(mod.warnings[1]:find("dev/console.lua", 1, true), mod.warnings[1])
    eq(#mod.frames, 1)
    eq(#mod.imports, 0)
    local lastGood = mod:poll(0.03125)
    assert(lastGood:find("OK joined 3 Fake2", 1, true), lastGood)
    assert(lastGood:find("enter=waiting", 1, true), lastGood)

    mod.edits["dev/console.lua"] = '_G.LoadMap = function() end; error("broken module")'
    mod:reload()
    eq(#mod.warnings, 2)
    assert(mod.warnings[2]:find("broken module", 1, true), mod.warnings[2])
    local stillWaiting = mod:poll(0.0625)
    assert(stillWaiting:find("enter=waiting", 1, true), stillWaiting)

    mod.edits["dev/console.lua"] = "return {}"
    mod:reload()
    eq(#mod.warnings, 3)
    assert(mod.warnings[3]:find("dev/console.lua is missing", 1, true), mod.warnings[3])

    mod.edits["dev/console.lua"] = readSource(root, "dev/console.lua"):gsub('"Fake"', '"Dev"')
    mod.game.LoadMap = loadMap
    mod:queue("player add\n")
    mod:reload()
    eq(#mod.frames, 1)
    eq(#mod.imports, 0)
    eq(#mod.maps, 1)
    eq(mod.polls, 3)
    local corrected = mod:poll(0.09375)
    assert(corrected:find("OK joined 4 Dev3", 1, true), corrected)
    assert(corrected:find("2:Fake1:up 3:Fake2:up", 1, true), corrected)
    eq(#mod.entered, 1)
    mod:poll(0.125)
    eq(#mod.entered, 1)
    eq(#mod.warnings, 3)
  end)

  test("a control poll failure warns once and later polls recover", function()
    local mod = mockLoader(root)
    mod:reload()
    mod:queue("player add\n")
    mod.pollError = "queue unavailable"
    mod:poll(0)
    mod:poll(1)
    eq(#mod.warnings, 1)
    assert(mod.warnings[1]:find("control sync failed: queue unavailable", 1, true), mod.warnings[1])
    mod.pollError = nil
    local recovered = mod:poll(2)
    assert(recovered:find("OK joined 2 Fake1", 1, true), recovered)
    eq(#mod.warnings, 1)
  end)

  test("enter schedules a yielding load once and waits for a real hero", function()
    local mod = mockLoader(root)
    mod.game.LoadMap = function(args)
      mod.entered[#mod.entered + 1] = args.Name
      coroutine.yield()
      mod.game.GameState = { IllegalConversationModification = true }
      mod.game.CurrentRun = { CurrentRoom = { Name = "F_Test" }, Hero = { ObjectId = 99 } }
      mod.locations[99] = { X = 12, Y = 34 }
    end
    mod:reload()
    mod:queue("enter F_Test\n")
    local loading = mod:poll(0)
    assert(loading:find("enter=loading F_Test", 1, true), loading)
    mod:reload()
    mod:queue("enter F_Test\n")
    local stillLoading = mod:poll(1)
    assert(stillLoading:find("enter=loading F_Test", 1, true), stillLoading)
    eq(#mod.threads, 1)
    assert(coroutine.resume(mod.threads[1]))
    local ready = mod:poll(2)
    assert(ready:find("hero=99:x=12:y=34 enter=ready F_Test", 1, true), ready)
    eq(#mod.entered, 1)
  end)

  test("enter refuses unsafe runs and reports a recoverable load error once", function()
    local mod = mockLoader(root)
    mod:reload()
    mod:queue("enter F_Opening01\n")
    local unsafe = mod:poll(0)
    assert(unsafe:find("failed unsupported map F_Opening01", 1, true), unsafe)
    mod:removeMapAsset("F_Test")
    mod:queue("enter\n")
    local unavailable = mod:poll(0.5)
    assert(unavailable:find("failed F_Test is unavailable", 1, true), unavailable)
    mod.allowSave = true
    mod:queue("enter F_Combat01\n")
    local saves = mod:poll(1)
    assert(saves:find("restart with /AllowSaveLoad=false", 1, true), saves)
    mod.allowSave = false
    mod.game.GameState = {}
    mod:queue("enter F_Combat01\n")
    local active = mod:poll(2)
    assert(active:find("failed a run is already active", 1, true), active)
    eq(#mod.threads, 0)
    mod.game.GameState = nil
    local calls = 0
    mod.game.LoadMap = function()
      calls = calls + 1
      if calls == 1 then
        coroutine.yield()
        error("map asset missing", 0)
      end
      coroutine.yield()
    end
    mod:queue("enter F_Combat01\n")
    mod:poll(3)
    assert(coroutine.resume(mod.threads[1]))
    local failed = mod:poll(4)
    assert(failed:find("enter=failed map asset missing", 1, true), failed)
    eq(mod:poll(5), failed)
    eq(calls, 1)
    mod:queue("enter F_Combat01\n")
    mod:poll(6)
    local timeout = mod:poll(27)
    assert(timeout:find("did not finish loading", 1, true), timeout)
    mod:queue("enter F_Combat01\n")
    eq(mod:poll(28), timeout)
    eq(calls, 2)
  end)
end
