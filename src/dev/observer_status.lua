local Bridge = import("dev/bridge.lua")

local ObserverStatus = {}

local function actorLines(lines, label, actors)
  for _, actor in ipairs(actors) do
    local hp = tostring(actor.hp or "?") .. "/" .. tostring(actor.maxHp or "?")
    local kind = actor.kind and " kind=" .. actor.kind or ""
    lines[#lines + 1] = label .. " id=" .. actor.id .. " hp=" .. hp .. kind
  end
end

local function roomLines(lines, room)
  if not room then
    lines[#lines + 1] = "room=unavailable"
    return
  end
  lines[#lines + 1] = "room=" .. room.name .. " id=" .. room.id
    .. " leaving=" .. tostring(room.leaving) .. " exitsUnlocked=" .. tostring(room.exitsUnlocked)
  local encounter = room.encounter
  lines[#lines + 1] = encounter and ("encounter=" .. encounter.name .. " id=" .. encounter.id
    .. " completed=" .. tostring(encounter.completed)) or "encounter=unavailable"

  if not room.exits then
    lines[#lines + 1] = "doors=unavailable"
  elseif #room.exits == 0 then
    lines[#lines + 1] = "doors=none"
  else
    for _, door in ipairs(room.exits) do
      local destination = door.destination and " destination=" .. door.destination or ""
      lines[#lines + 1] = "door id=" .. door.id .. " readyToUse=" .. tostring(door.readyToUse)
        .. " inUse=" .. tostring(door.inUse) .. destination
    end
  end

  for _, reward in ipairs(room.rewards or {}) do
    local object = reward.objectId and " objectId=" .. reward.objectId or ""
    lines[#lines + 1] = "reward id=" .. reward.id .. " kind=" .. reward.kind
      .. " encounterId=" .. reward.encounterId .. object
  end
end

function ObserverStatus.format(snapshot)
  local lines = { "control=observer", "Read-only observer (one native hero)" }
  if snapshot then
    lines[#lines + 1] = string.format("tick=%.0f", snapshot.tick)
    roomLines(lines, snapshot.room)
    if #snapshot.heroes == 0 then
      lines[#lines + 1] = "hero=unavailable"
    end
    if #snapshot.enemies == 0 then
      lines[#lines + 1] = "enemies=none"
    end
    actorLines(lines, "hero", snapshot.heroes)
    actorLines(lines, "enemy", snapshot.enemies)
  else
    lines[#lines + 1] = "snapshot=waiting"
  end
  -- Readers only display a complete report if they race a Windows file write.
  lines[#lines + 1] = "observerStatus=complete"
  return table.concat(lines, "\n") .. "\n"
end

function ObserverStatus.publish(snapshot)
  local text = ObserverStatus.format(snapshot)
  local report, openError = io.open(Bridge.controlRoot() .. "\\status.txt", "wb")
  if not report then
    return nil, openError
  end
  local written, writeError = report:write(text)
  local closed, closeError = report:close()
  if not written or not closed then
    return nil, writeError or closeError
  end
  return true
end

return ObserverStatus
