local function readSource(root, name)
  local file = assert(io.open(root .. "/src/" .. name, "rb"))
  local source = assert(file:read("*a"))
  file:close()
  return source
end

local function mockLoader(root)
  local mock = { edits = {}, frames = {}, imports = {}, maps = {}, errors = {},
    info = {}, polls = 0, clock = 0, spawned = 0, entered = {}, positions = {},
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
  function game.SpawnObstacle()
    mock.spawned = mock.spawned + 1
    return 100 + mock.spawned
  end
  function game.GetLocation(args)
    return mock.locations[args.Id] or { X = 0, Y = 0 }
  end
  function game.Teleport(args)
    mock.positions[args.Id] = args
    local origin = args.DestinationId and game.GetLocation({ Id = args.DestinationId })
    mock.locations[args.Id] = { X = (origin and origin.X or 0) + args.OffsetX,
      Y = (origin and origin.Y or 0) + args.OffsetY }
  end
  function game.LoadMap(args)
    mock.entered[#mock.entered + 1] = args.Name
  end
  mock.game = game

  local public = setmetatable({ _PLUGIN = { plugins_mod_folder_path = root .. "/src" } }, {
    __index = _G,
  })
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
      error = function(line) mock.errors[#mock.errors + 1] = line end,
    },
  }
  public.io = { open = function(path, mode)
    if mode == "rb" and files[path] == nil then
      return nil
    end
    if mode == "wb" then
      files[path] = ""
    end
    return {
      read = function() return files[path] end,
      write = function(_, chunk) files[path] = (files[path] or "") .. chunk end,
      close = function() end,
    }
  end }
  public.os = {
    getenv = function() return "mock-home" end,
    clock = function() return mock.clock end,
    rename = function(from, to)
      assert(from == commandsPath)
      mock.polls = mock.polls + 1
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

  function mock:removeMapAsset(mapName)
    files["mock-content/Maps/" .. mapName .. ".map_text"] = nil
  end

  return mock
end

return function(root, test, eq)
  test("loader reload keeps live bodies and playback and installs one control poll", function()
    local mod = mockLoader(root)
    mod.game.CurrentRun = { CurrentRoom = { Name = "F_Test" }, Hero = { ObjectId = 99 } }
    mod.game.GameState = { IllegalConversationModification = true }
    mod:reload()
    eq(#mod.frames, 1)
    eq(#mod.imports, 0)
    local onMap = assert(mod.maps[1])
    mod:queue("player add Guest\nenter F_Test\nplay\n")
    local first = mod:poll(0)
    assert(first:find("2:Guest:spawned=101:x=180:y=40", 1, true), first)
    assert(first:find("OK play", 1, true), first)
    eq(#mod.entered, 0)
    assert(first:find("enter=ready F_Test", 1, true), first)
    eq(mod.spawned, 6)
    local moving = mod:poll(0.03125)
    assert(moving:find("2:Guest:spawned=101:x=196:y=40", 1, true), moving)

    mod.edits["hack/game.lua"] = readSource(root, "hack/game.lua")
      :gsub('"bodies hero="', '"bodies updated hero="')
      :gsub('return table.concat%(parts, " "%)', 'return table.concat(parts, " ") .. " map=" .. tostring(self.map)')
      :gsub("self.map = name", 'self.map = name .. "-updated"')
    mod.edits["dev/inputs.lua"] = readSource(root, "dev/inputs.lua")
      :gsub("x %+ mx %* speed %* dt, y %+ my %* speed %* dt",
        "x + mx * speed * dt * 2, y + my * speed * dt * 2")
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
    assert(updated:find("2:Guest:spawned=101:x=196:y=73", 1, true), updated)
    eq(mod.positions[101].OffsetX, 196.875)
    eq(mod.positions[101].OffsetY, 73.75)
    eq(mod.polls, 3)
    eq(mod.spawned, 6)
    eq(#mod.entered, 0)
    local nextReport = mod:poll(0.09375)
    assert(nextReport:find("OK rejoined 2 Guest", 1, true), nextReport)
    onMap({ name = "NewRoom" })
    local changedMap = mod:poll(0.125)
    assert(changedMap:find("map=NewRoom-updated", 1, true), changedMap)
    eq(#mod.errors, 0)
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
    eq(#mod.errors, 1)
    assert(mod.errors[1]:find("dev/console.lua", 1, true), mod.errors[1])
    eq(#mod.frames, 1)
    eq(#mod.imports, 0)
    local lastGood = mod:poll(0.03125)
    assert(lastGood:find("OK joined 3 Fake2", 1, true), lastGood)
    assert(lastGood:find("enter=waiting", 1, true), lastGood)

    mod.edits["dev/console.lua"] = '_G.LoadMap = function() end; error("broken module")'
    mod:reload()
    eq(#mod.errors, 2)
    assert(mod.errors[2]:find("broken module", 1, true), mod.errors[2])
    local stillWaiting = mod:poll(0.0625)
    assert(stillWaiting:find("enter=waiting", 1, true), stillWaiting)

    mod.edits["dev/console.lua"] = "return {}"
    mod:reload()
    eq(#mod.errors, 3)
    assert(mod.errors[3]:find("dev/console.lua is missing", 1, true), mod.errors[3])

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
    eq(#mod.errors, 3)
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
