---@meta _
---@diagnostic disable: lowercase-global

-- Loads the pure layers, then the startup button and the dev command port.
-- Spawning units stays in hack/game.lua.

local Session = import("protocol/session.lua")
local Menu = import("hack/menu.lua")

import("protocol/codec.lua")
import("protocol/messages.lua")
import("gameplay/party.lua")
import("gameplay/death.lua")
import("gameplay/scaling.lua")
import("gameplay/loot.lua")
import("authority/loop.lua")
import("hack/engine.lua")
import("net/loopback.lua")
import("client/input.lua")

local ok, sessionOrErr = pcall(Session.new, config.role)
if not ok then
  rom.log.error("[Hades2Together] " .. tostring(sessionOrErr))
  return
end

local slot = Session.join(sessionOrErr, config.playerName or "Player")
local listening = Menu.install(sessionOrErr, config.devPort)

rom.log.info(string.format(
  "[Hades2Together] menu ready, role=%s, slot=%s, devPort=%s, listening=%s",
  sessionOrErr.role,
  tostring(slot),
  tostring(config.devPort),
  tostring(listening)
))
