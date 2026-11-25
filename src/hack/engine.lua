local Engine = {}

-- The only operations the rest of the mod may ask the game to perform.
Engine.methods = {
  "BindHero",
  "PushInput",
  "ReadActors",
  "RunAsHero",
  "SetCamera",
  "SetAggroTargets",
  "SetFocusTick",
  "ApplySnapshot",
  "SuppressLocalSim",
  "Call",
  "PullEvents",
}

function Engine.check(impl)
  local missing = {}
  for _, name in ipairs(Engine.methods) do
    if type(impl[name]) ~= "function" then
      missing[#missing + 1] = name
    end
  end
  return missing
end

function Engine.assert(impl)
  local missing = Engine.check(impl)
  if #missing > 0 then
    error("hack engine missing: " .. table.concat(missing, ", "))
  end
end

return Engine
