-- PlayerUnit damage uses the retail damage thread. Retail only dispatches
-- this action for its hero/summons; the attached guest owns a separate trait.
local GuestInput = import("hack/guest_input.lua")
local Splash = {}
local effects = setmetatable({}, { __mode = "k" })

local function forAttacker(g, unit, seat)
  local original = g.CheckPoseidonSplash
  local cached = effects[unit]
  if cached and cached.original == original and cached.seat == seat then return cached.call end
  -- The retail Lua function captures only its globals. Load a private copy
  -- with its actor reads scoped to this Unit. Never rebind the live function.
  assert(type(original) == "function" and debug.getupvalue(original, 1) == "_ENV"
    and debug.getupvalue(original, 2) == nil, "unsupported CheckPoseidonSplash closure")
  local prefix = "H2T/seat/" .. seat .. "/"
  local env = setmetatable({
    CurrentRun = { Hero = unit },
    HeroHasTrait = function(name) return unit.TraitDictionary[name] ~= nil end,
    GetHeroTraitValues = function(key)
      -- The retail helper uses the primary Hero's cache even with args.Unit.
      local values = {}
      for _, trait in ipairs(unit.Traits) do
        if trait[key] ~= nil then values[#values + 1] = trait[key] end
      end
      return values
    end,
    GetTotalHeroTraitValue = function(key, args)
      args = g.ShallowCopyTable(args)
      args.Hero = unit
      return g.GetTotalHeroTraitValue(key, args)
    end,
    CheckCooldown = function(key, ...) return g.CheckCooldown(prefix .. key, ...) end,
    CheckCountInWindow = function(key, ...) return g.CheckCountInWindow(prefix .. key, ...) end,
  }, { __index = g })
  local call = assert(load(string.dump(original), "CheckPoseidonSplash", "b", env))
  effects[unit] = { original = original, call = call, seat = seat }
  return call
end

function Splash.apply(game, g, victim, unit, args)
  if args.SkipOnDamagedPowers or args.EffectName or not args.ProjectileId or args.AttackerTable ~= unit
    or args.AttackerId ~= unit.ObjectId or args.Victim ~= victim or not victim.TriggersOnDamageEffects
    or not g.ActiveEnemies or g.ActiveEnemies[victim.ObjectId] ~= victim
    or g.Contains(g.MapState.SpellSummons, unit) then return end
  local owned = unit.TraitDictionary and unit.TraitDictionary.PoseidonWeaponBoon
  local trait = owned and owned[1]
  if not trait or trait.Name ~= "PoseidonWeaponBoon" or trait.Slot ~= "Melee"
    or unit.Traits == g.CurrentRun.Hero.Traits or unit.TraitDictionary == g.CurrentRun.Hero.TraitDictionary
    or not g.Contains(unit.Traits, trait) then return end
  local action = trait.OnEnemyDamagedAction
  if not action or action.FunctionName ~= "CheckPoseidonSplash" or action.ValidEffectName
    or not action.Args or not action.ValidWeaponsLookup
    or not action.ValidWeaponsLookup[args.SourceWeapon] or args.SourceProjectile == action.Args.ProjectileName
    or (action.ValidProjectilesLookup and not action.ValidProjectilesLookup[args.SourceProjectile])
    or (action.ExcludeProjectilesLookup and action.ExcludeProjectilesLookup[args.SourceProjectile]) then return end
  for seat, state in pairs(GuestInput.states(game)) do
    if state.actor == unit and state.session == game.session and state.slot and state.slot == game.session.slots[seat]
      and game:BoundGuestUnit(seat) == unit then
      local hitId = args.ProjectileId
      if args.AttackerWeaponData and args.AttackerWeaponData.UniqueDetonationHits and args.Detonation then
        hitId = hitId .. tostring(args.Detonation)
      end
      if action.FirstHitOnly and g.ProjectileHasUnitHit(hitId, action.FunctionName) then return end
      local call = forAttacker(g, unit, seat)
      g.ProjectileRecordUnitHit(hitId, action.FunctionName)
      call(victim, g.ShallowCopyTable(action.Args), args)
      return
    end
  end
end

return Splash
