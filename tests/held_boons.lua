-- State after an offline guest acquired a replacement room Unit. No grant or input callbacks.
package.path = "src/?.lua;" .. package.path
function import(path) return require((path:gsub("%.lua$", ""):gsub("/", "."))) end
local Session, Game = import("protocol/session.lua"), import("hack/game.lua")
local Status, Menu = import("dev/observer_status.lua"), import("hack/menu.lua")
local Client, Messages, Codec = import("client/connection.lua"), import("protocol/messages.lua"), import("protocol/codec.lua")
local weapon, special = "PoseidonWeaponBoon", "PoseidonSpecialBoon"
local hero = { ObjectId=40000, Health=20, MaxHealth=30, Traits={} }
local guest = { ObjectId=900, Health=24, MaxHealth=30, Traits={
  [1]={ Name=weapon, Rarity="Rare", StackNum=2 }, [3]={ Name=special, Rarity="Common" }, [4]={ Name="Other" },
} }
local room = { Name="F_Combat01" }
local binding = { id=900, actor=guest, load=8 }
rom = { game={ CurrentRun={ CurrentRoom=room, Hero=hero }, SessionState={ MapLoads=8 },
  SessionMapState={ DeferredObstacleInitializationFinished=true },
  GetName=function() return "_PlayerUnit" end, IsAlive=function() return true end,
  GetLocation=function() return { X=10, Y=20 } end },
  data={ h2t_guest_capacity=true, h2t_guest_actor=function(seat) assert(seat == 3); return binding end } }
local session = Session.new("serve+play")
for seat, name in ipairs({ "Host", "Pending", "Guest" }) do Session.join(session, name, seat) end
Session.release(session, 3)
local game = Game.new(session, 1)
game:OnMap(room.Name)
game.guestInputs = { [2]={ id=899, load=7, publication=10, reason="retiring" },
  [3]={ session=session, slot=session.slots[3], room=room, hero=hero, load=8,
  publication=13, id=900, actor=guest, reason="offline" } }
-- Deliberately disagree with both the bound Unit and its stack count.
game.guestBoonHoldings.players[session.slots[3]] = { { Name=weapon, Rarity="Epic", StackNum=9 } }
local actors = game:ReadActors()
local msg = assert(Codec.decode(Codec.encode(Messages.snapshot(1, actors.heroes, actors.enemies, actors.room))))
local client = setmetatable({ playerId=1, maxPlayers=4 }, Client)
assert(client:accept(msg) and #msg.heroes == 2 and not msg.room.rewards)
local host, remote = table.unpack(msg.heroes)
assert(host.playerId == 1 and #host.heldBoons == 0)
assert(remote.playerId == 3 and remote.id == 900 and remote.connected == false and #remote.heldBoons == 2)
local a, b = table.unpack(remote.heldBoons)
assert(a.name == special and a.rarity == "Common" and a.stacks == 1)
assert(b.name == weapon and b.rarity == "Rare" and b.stacks == 2)

local control = Menu.new(session)
control.statusPath = arg[1] and (arg[1] .. "/polling.txt") or os.tmpname()
Menu.publish(control, game, "polling")
local report = assert(io.open(control.statusPath, "rb"))
local polling = report:read("*a")
report:close()
assert(polling:find("unbound seat=2", 1, true))
if not arg[1] then os.remove(control.statusPath) end
local observer = Status.format(client.snapshot)
local play = Status.format(client.snapshot, { connection="joined", seat=1, sentSeq=0 })
for _, status in ipairs({ polling, observer, play }) do
  assert(status:find("seat=3 connected=false heldBoons=" .. special .. ":Common:1," .. weapon .. ":Rare:2", 1, true))
  assert(status:find("seat=1 connected=true heldBoons=none", 1, true) and not status:find("claim reward=", 1, true))
end
binding.load = 7
assert(#game:ReadHeroes() == 1) -- old World, recycled numeric ID and a retained run inventory
local old = Messages.snapshot(2, { { id=900, hp=24, maxHp=30 } }, {})
assert(client:accept(old))
local legacy = Status.format(client.snapshot)
assert(not legacy:find("heldBoons=", 1, true))
if arg[1] then
  for name, status in pairs({ observer=observer, play=play, legacy=legacy }) do
    local file = assert(io.open(arg[1] .. "/" .. name .. ".txt", "wb"))
    assert(file:write(status)); assert(file:close())
  end
end
print("held-boons: bound offline seat 3 Common x1 / Rare x2; host empty; stale binding excluded; legacy unknown")
