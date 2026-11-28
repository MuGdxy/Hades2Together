-- Applies queued dev commands and formats the roster for the local controls.

local Console = import("dev/console.lua")

local Bridge = {}

function Bridge.controlRoot()
  local home = os.getenv("USERPROFILE") or os.getenv("HOME") or "."
  return home .. "\\Hades2Together"
end

function Bridge.applyLines(console, lines, submitInput, submitBoon, killAll)
  local results = {}
  for _, line in ipairs(lines) do
    if line ~= "" then
      results[#results + 1] = Console.execute(console, line, submitInput, submitBoon, killAll)
    end
  end
  return results
end

function Bridge.killAllLine(receipt)
  if not receipt then return end
  return string.format("%s env kill-all request=%d state=%s room=%s targets=%d completed=%d skipped=%d pending=%d failed=%d canceled=%d%s",
    receipt.state == "failed" and "ERR" or "OK", receipt.id, receipt.state, receipt.room,
    receipt.total, receipt.completed, receipt.skipped, receipt.pending, receipt.failed, receipt.canceled,
    receipt.reason and (" reason=" .. receipt.reason) or "")
end

function Bridge.statusText(console)
  return Console.execute(console, "status") .. "\n" .. Console.execute(console, "players") .. "\n"
end

function Bridge.actorLine(label, actor)
  local hp = tostring(actor.hp or "?") .. "/" .. tostring(actor.maxHp or "?")
  local kind = actor.kind and " kind=" .. actor.kind or ""
  local position = actor.x ~= nil and actor.y ~= nil and (" x=" .. actor.x .. " y=" .. actor.y) or ""
  local line = label .. " id=" .. actor.id .. " hp=" .. hp .. kind .. position
  if label ~= "hero" then return line end
  if actor.playerId then line = line .. " seat=" .. actor.playerId end
  if actor.connected ~= nil then line = line .. " connected=" .. tostring(actor.connected) end
  if actor.heldBoons then
    local values = {}
    for _, boon in ipairs(actor.heldBoons) do
      values[#values + 1] = table.concat({ boon.name, boon.rarity, boon.stacks }, ":")
    end
    line = line .. " heldBoons=" .. (#values > 0 and table.concat(values, ",") or "none")
  end
  return line
end

function Bridge.claimLines(rewards)
  local lines = {}
  for _, reward in ipairs(rewards or {}) do
    for _, claim in ipairs(reward.claims or {}) do
      lines[#lines + 1] = "claim reward=" .. reward.id .. " kind=" .. reward.kind
        .. " seat=" .. claim.playerId .. " state=" .. claim.state
        .. (claim.choice and " choice=" .. claim.choice or "")
        .. (claim.selected and " selected=" .. claim.selected or "")
        .. (claim.options and claim.state ~= "consumed" and " options=" .. table.concat(claim.options, ",") or "")
        .. (claim.opportunity and " opportunity=" .. claim.opportunity .. " grantOption=" .. claim.grantOption or "")
        .. (claim.grantOptions and " grantOptions=" .. table.concat(claim.grantOptions, ",") or "")
    end
  end
  return lines
end

function Bridge.sync(console, commandsPath, submitInput, submitBoon, killAll)
  local lines = {}
  local taken = commandsPath .. ".take"
  if os.rename(commandsPath, taken) then
    local file = io.open(taken, "rb")
    if file then
      local text = file:read("*a") or ""
      file:close()
      os.remove(taken)
      for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line = line:gsub("\r$", "")
        if line ~= "" then
          lines[#lines + 1] = line
        end
      end
    end
  end
  return Bridge.applyLines(console, lines, submitInput, submitBoon, killAll)
end

return Bridge
