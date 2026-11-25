local Loot = {}

local function livingIds(party)
  local ids = {}
  for playerId, member in pairs(party.members) do
    if member.alive then
      ids[#ids + 1] = playerId
    end
  end
  table.sort(ids)
  return ids
end

-- `context` is mutated. round_robin stores the next index in context.cursor.
function Loot.assign(party, policy, context)
  context = context or {}
  local ids = livingIds(party)
  if #ids == 0 then
    return nil, context
  end

  if policy == "host" then
    for _, playerId in ipairs(ids) do
      if playerId == 1 then
        return 1, context
      end
    end
    return ids[1], context
  end

  if policy == "killer" then
    local killer = context.killerId
    local member = killer and party.members[killer]
    if member and member.alive then
      return killer, context
    end
    return ids[1], context
  end

  if policy == "round_robin" then
    local cursor = context.cursor or 1
    if cursor > #ids or cursor < 1 then
      cursor = 1
    end
    local playerId = ids[cursor]
    cursor = cursor + 1
    if cursor > #ids then
      cursor = 1
    end
    context.cursor = cursor
    return playerId, context
  end

  error("unknown loot policy " .. tostring(policy))
end

return Loot
