---@meta _
---@diagnostic disable: lowercase-global

-- Phase 0 loads the pure layers so a bad file fails at startup.
-- It does not bind heroes or wrap game functions. That binding lives in hack/game.lua.

local Session = import("protocol/session.lua")

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

rom.log.info(string.format(
  "[Hades2Together] phase 0 ready, role=%s, authority=%s",
  sessionOrErr.role,
  tostring(Session.isAuthority(sessionOrErr))
))
