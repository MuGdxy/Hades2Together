-- Command boundary with the production selection logic and a fixture grant result.
local unit = { ObjectId = 300 }
local room = { Name = "F_Reprieve01", SpawnRewardOnId = 55, Encounter = { Name = "HealthRestore" } }
local source = { ObjectId = 90, Name = "PoseidonUpgrade" }
local env = setmetatable({ rom = { game = {
  CurrentRun = { CurrentRoom = room, Hero = { ObjectId = 100 } }, SessionState = { MapLoads = 1 },
  SessionMapState = { DeferredObstacleInitializationFinished = true },
  MapState = { RoomRequiredObjects = { [90] = source }, RewardPointsUsed = { [55] = 90 } }
} } }, { __index = _G })
local modules = {}
function env.import(path)
  if not modules[path] then modules[path] = assert(loadfile("src/" .. path, "t", env))() end
  return modules[path]
end
local Session, Game = env.import("protocol/session.lua"), env.import("hack/game.lua")
local Menu, Console = env.import("hack/menu.lua"), env.import("dev/console.lua")
local session = Session.new("serve+play")
assert(Session.join(session, "Host", 1) and Session.join(session, "Guest", 3))
local game, name = Game.new(session, 1), "PoseidonSpecialBoon"
game:OnMap(room.Name)
function game:BoundGuestUnit(seat) if seat == 3 then return unit end end
local roll = { options = { "PoseidonWeaponBoon", name, "PoseidonCastBoon" },
  rarities = { PoseidonWeaponBoon = "Common", [name] = "Rare", PoseidonCastBoon = "Rare" } }
local reward = { id = 2, encounterId = 1, kind = source.Name, guests = {
  [3] = { slot = session.slots[3], unit = unit, actorId = 300, round = 4, rolls = { [4] = roll } }
} }
local load = game.roomLoad
load.id, load.boonClaims = 7, { reward }
load.boonOffer = { id = 2, source = source, objectId = 90, encounter = room.Encounter, reward = reward }
local calls = 0
function game:GrantGuestBoon(roomId, rewardId, seat, token)
  local entry = reward.seats[3]
  assert(roomId == 7 and rewardId == 2 and seat == 3)
  if entry.consumed then
    assert(token == entry.grantedSelection)
    return entry.instanceId
  end
  calls = calls + 1
  assert(token == entry.pending and entry.selected == name)
  if calls == 1 then return nil, "fixture refusal" end
  assert(env.import("gameplay/boon.lua").confirm(session, reward, token, 300, name, "fixture-id"))
  entry.grantedSelection = token
  return "fixture-id"
end
for _, method in ipairs({ "UpdateInputOwner", "CheckEnter", "Install", "Step" }) do game[method] = function() end end
function game:BodyReport() return "bodies hero=100" end
local control = { console = Console.new(session), commandsPath = os.tmpname(), statusPath = os.tmpname() }
local function report()
  local file = assert(io.open(control.statusPath, "rb"))
  local result = file:read("*a")
  file:close()
  return result
end
Menu.publish(control, game, "polling")
local wireClaim = game:ReadActors().room.rewards[1].claims[1]
assert(wireClaim.playerId == 3 and wireClaim.opportunity == "7/2/4" and wireClaim.grantOption == "PoseidonWeaponBoon")
assert(table.concat(wireClaim.grantOptions, ",") == "PoseidonWeaponBoon,PoseidonSpecialBoon")
assert(report():find("options=PoseidonWeaponBoon,PoseidonSpecialBoon,PoseidonCastBoon opportunity=7/2/4 "
  .. "grantOption=PoseidonWeaponBoon grantOptions=PoseidonWeaponBoon,PoseidonSpecialBoon", 1, true))
local function pump(command)
  local file = assert(io.open(control.commandsPath, "wb"))
  file:write(command .. "\n")
  file:close()
  Menu.pump(control, game)
  return control.results[1]
end
local cmd = "boon 3 7/2/4 " .. name
for _, bad in ipairs({ cmd .. " Rare", "boon 3 7/2/3 " .. name, "boon 1 7/2/4 " .. name,
    "boon 3 7/2/4 PoseidonCastBoon", "boon 3 8/2/4 " .. name }) do
  assert(pump(bad):match("^ERR ") and not reward.seats[3].pending and calls == 0)
end
assert(pump(cmd):find("fixture refusal", 1, true) and calls == 1 and not reward.seats[3].consumed)
local success = "OK boon seat=3 opportunity=7/2/4 option=" .. name .. " instance=fixture-id"
assert(pump(cmd) == success and pump(cmd) == success)
assert(report():find("seat=3 state=consumed choice=" .. name, 1, true) and calls == 2)
for _, role in ipairs({ "play", "observer" }) do
  assert(Console.execute({ session = { role = role } }, cmd, nil, error):match("^ERR "))
end
os.remove(control.statusPath)
print("boon command: authoritative seat/room/reward/round, stale/extra/unsupported refusal, result and read-only checks passed")
