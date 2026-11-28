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

-- Give both the bootstrap hook and the adopted Game the same persistent state.
if not hubRoomObservation and (config.observerSnapshots or config.role ~= "play") then
  hubRoomObservation = {}
end

reloadRuntime.load()

-- A cached coordinator can restore callbacks without calling Game:Install.
-- Before its adopted receiver runs, this hook only captures stock setup facts.
if hubRoomObservation and not hubRoomObservation.receiver and not hubRoomObservation.installed then
  local ok, hub = pcall(import, "hack/hub_room.lua")
  if ok and type(hub) == "table" and hub.name == "Hub_Main" and type(hub.install) == "function"
    and type(hub.adopt) == "function" and type(hub.observe) == "function" then
    local armed, err = pcall(hub.install, hubRoomObservation, game)
    if not armed then rom.log.warning("[Hades2Together] hub observer bootstrap failed: " .. tostring(err)) end
  end
end
