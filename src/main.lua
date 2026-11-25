---@meta _
-- Set up the mod before the game scripts load, without waiting for ModUtil.

---@diagnostic disable-next-line: undefined-global
local mods = rom.mods

---@module 'LuaENVY-ENVY-auto'
mods['LuaENVY-ENVY'].auto()
---@diagnostic disable: lowercase-global

-- The loader runs this file again in the same environment after clearing
-- loader-owned callbacks. Keep the reload coordinator in ENVY's private table.
if not reloadRuntime then
  rom = rom
  _PLUGIN = _PLUGIN
  game = rom.game
  import_as_fallback(game)
  config = import("config.lua")
  public.config = config
  reloadRuntime = import("reload.lua")
end

reloadRuntime.load()
