-- Applies queued dev commands and formats the roster for the local controls.

local Console = import("dev/console.lua")

local Bridge = {}

function Bridge.applyLines(console, lines)
  local results = {}
  for _, line in ipairs(lines) do
    if line ~= "" then
      results[#results + 1] = Console.execute(console, line)
    end
  end
  return results
end

function Bridge.statusText(console)
  return Console.execute(console, "status") .. "\n" .. Console.execute(console, "players") .. "\n"
end

function Bridge.sync(console, commandsPath)
  local lines = {}
  local taken = commandsPath .. ".take"
  if os.rename(commandsPath, taken) then
    local file = io.open(taken, "rb")
    if file then
      local text = file:read("*a") or ""
      file:close()
      os.remove(taken)
      for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        if line ~= "" then
          lines[#lines + 1] = line
        end
      end
    end
  end
  return Bridge.applyLines(console, lines)
end

return Bridge
