---@meta _
-- The multiplayer button has to exist on the shell menu, which appears
-- before the game scripts load. This file therefore does not wait for ModUtil.

---@diagnostic disable-next-line: undefined-global
local mods = rom.mods

---@module 'LuaENVY-ENVY-auto'
mods['LuaENVY-ENVY'].auto()
---@diagnostic disable: lowercase-global

---@diagnostic disable-next-line: undefined-global
rom = rom
---@diagnostic disable-next-line: undefined-global
_PLUGIN = _PLUGIN

---@module 'config'
config = import 'config.lua'
public.config = config

import 'ready.lua'
