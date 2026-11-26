-- Applies queued dev commands and formats the roster for the local controls.

local Console = import("dev/console.lua")

local Bridge = {}

function Bridge.controlRoot()
  local home = os.getenv("USERPROFILE") or os.getenv("HOME") or "."
  return home .. "\\Hades2Together"
end

function Bridge.applyLines(console, lines, submitInput)
  local results = {}
  for _, line in ipairs(lines) do
    if line ~= "" then
      results[#results + 1] = Console.execute(console, line, submitInput)
    end
  end
  return results
end

function Bridge.statusText(console)
  return Console.execute(console, "status") .. "\n" .. Console.execute(console, "players") .. "\n"
end

function Bridge.claimLines(rewards)
  local lines = {}
  for _, reward in ipairs(rewards or {}) do
    for _, claim in ipairs(reward.claims or {}) do
      lines[#lines + 1] = "claim reward=" .. reward.id .. " kind=" .. reward.kind
        .. " seat=" .. claim.playerId .. " state=" .. claim.state
        .. (claim.choice and " choice=" .. claim.choice or "")
    end
  end
  return lines
end

function Bridge.sync(console, commandsPath, submitInput)
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
  return Bridge.applyLines(console, lines, submitInput)
end

return Bridge
