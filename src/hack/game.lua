-- Game binding. This is the only file allowed to touch the live game.
-- Phase 0 implements the method names and refuses to call them.

local Engine = import("hack/engine.lua")

local Game = {}

local function later(name)
  return function()
    error("hack.game." .. name .. " is not implemented (phase 1)", 0)
  end
end

for _, name in ipairs(Engine.methods) do
  Game[name] = later(name)
end

return Game
