---@meta _
---@diagnostic disable: lowercase-global

-- Build the runtime module graph without registering callbacks or polling.

local Session = import("protocol/session.lua")
local Menu = import("hack/menu.lua")
local Game = import("hack/game.lua")

assert(type(Game.ObserveHeroSetup) == "function" and type(Game.InstallHubObserver) == "function",
  "hack/game.lua is missing hub observation callbacks")

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

return { Session = Session, Menu = Menu, Game = Game }
