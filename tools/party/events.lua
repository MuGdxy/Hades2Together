-- Isolated recording plugin. Observe the stock event arguments after the
-- game's CombatLogic handlers are registered.
local g = rom.game
local owners = {}
local registered = false
local function record(text) rom.log.info("[H2T-party] " .. text) end

rom.gui.add_always_draw_imgui(function()
  local run = g.CurrentRun
  local room = run and run.CurrentRoom
  local load = g.SessionState and g.SessionState.MapLoads
  if not room or not load then owners = {}; return end
  local current = {}
  if run.Hero then current[1] = run.Hero end
  for _, seat in ipairs(rom.data.h2t_guest_seats()) do
    local b = rom.data.h2t_guest_actor(seat)
    if b and b.load == load and b.actor and b.actor.ObjectId == b.id then current[seat] = b.actor end
  end
  for seat, actor in pairs(current) do
    if not owners[seat] or owners[seat].actor ~= actor or owners[seat].load ~= load then
      record(("bound seat=%d unit=%d room=%s load=%d"):format(seat, actor.ObjectId, room.Name, load))
    end
    current[seat] = {actor=actor, room=room, load=load}
  end
  owners = current
end)

local function stockOwner(actor)
  if not actor or not g.CurrentRun or not g.SessionState then return end
  for seat, owner in pairs(owners) do
    if owner.actor == actor and g.CurrentRun.CurrentRoom == owner.room and g.SessionState.MapLoads == owner.load then
      return seat, owner.load
    end
  end
end

rom.on_import.post(function(path)
  if registered or path ~= "CombatLogic.lua" then return end
  g.OnWeaponFired({ "WeaponStaffSwing", function(args)
    local seat, load = stockOwner(args.OwnerTable)
    if seat and args.name == "WeaponStaffSwing" and args.ProjectileName == "ProjectileStaffSwing1" then
      record(("fire load=%d seat=%d unit=%d projectile=%s volley=%s"):format(
        load, seat, args.OwnerTable.ObjectId, tostring(args.ProjectileId), tostring(args.ProjectileVolley)))
    end
  end })
  g.OnHit({ function(args)
    local seat, load = stockOwner(args.AttackerTable)
    local victim = args.Victim
    if seat and victim and victim.ObjectId and args.SourceWeapon == "WeaponStaffSwing" then
      record(("onhit load=%d seat=%d unit=%d victim=%d kind=%s hp=%s projectile=%s volley=%s"):format(
        load, seat, args.AttackerTable.ObjectId, victim.ObjectId, tostring(victim.Name), tostring(victim.Health),
        tostring(args.ProjectileId), tostring(args.ProjectileVolley)))
    end
  end })
  registered = true
end)
