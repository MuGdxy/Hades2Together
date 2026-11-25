local environment = setmetatable({}, { __index = _G })
local modules = {}

function environment.import(path)
  if not modules[path] then
    modules[path] = assert(loadfile("src/" .. path, "t", environment))()
  end
  return modules[path]
end

local held = {}
local reads = {}
local game = {
  CurrentRun = { Hero = { ObjectId = 99 } },
  IsControlDown = function(args)
    reads[#reads + 1] = args.Name
    return held[args.Name] == true
  end,
}
environment.rom = { game = game }
local capture = environment.import("hack/game.lua").new()
local Input = environment.import("client/input.lua")

local function expect(x, y, buttons)
  reads = {}
  local state = assert(capture:ReadLocalInput())
  assert(state.moveX == x and state.moveY == y and state.buttons == buttons)
  assert(state.aimX == nil and state.aimY == nil)
  assert(table.concat(reads, ",") == "Right,Left,Down,Up,Attack1")
  return state
end

expect(0, 0, 0)
held = { Right = true, Down = true, Attack1 = true }
local state = expect(1, 1, 1)
local frame = Input.frame(5, 3, state)
assert(frame.moveX == 1 and frame.moveY == 1 and frame.buttons == 1)
assert(frame.playerId == 3 and frame.tick == 5 and frame.aimX == 0 and frame.aimY == 0)
expect(1, 1, 1)
held = { Right = true, Left = true, Up = true, Down = true }
expect(0, 0, 0)
held = { Left = true, Up = true }
expect(-1, -1, 0)
held = {}
expect(0, 0, 0)
assert(state.moveX == 1 and state.moveY == 1 and state.buttons == 1)

game.CurrentRun = nil
local unavailable, reason = capture:ReadLocalInput()
assert(unavailable == nil and reason == "local hero is unavailable")
game.IsControlDown = nil
unavailable, reason = capture:ReadLocalInput()
assert(unavailable == nil and reason == "native control readback is unavailable")

print("local input capture passed")
