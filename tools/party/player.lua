-- One persistent TCP player. The terminal appends commands to this connection's
-- private journal so waiting for a console line never stops snapshot polling.
local root, journal = assert(arg[1], "expected plugin directory"), assert(arg[2], "expected empty command file")
package.path = root .. "/?.lua;" .. package.path
function import(path) return require((path:gsub("%.lua$", ""):gsub("/", "."))) end
local Connection = import("client/connection.lua")
local Input = import("client/input.lua")
local Status = import("dev/observer_status.lua")
local socket = require("socket")
local config = assert(loadfile(root .. "/config.lua"))()
assert(config.role == "play", "expected a play configuration")
local initial = assert(io.open(journal, "rb"))
assert(initial:seek("end") == 0, "use a fresh command file for each connection")
initial:close()
io.stdout:setvbuf("no")
local transcript = assert(io.open(journal .. ".log", "wb"))
local function report(line)
  print(line)
  assert(transcript:write(line, "\n"))
  assert(transcript:flush())
end
local client = assert(Connection.connect(socket, config.playerPort, config.playerName, config.serverAddress))
local untilWelcome = socket.gettime() + 4
local offset, partial, reason = 0, ""

local function command(line)
  local words = {}
  for word in line:gmatch("%S+") do words[#words + 1] = word end
  if words[1] == "quit" and #words == 1 then return false end
  if words[1] == "status" and #words == 1 then
    report(Status.format(client.snapshot, { connection = client.playerId and "joined" or "connecting",
      seat = client.playerId, sentSeq = client.seq, reason = reason }))
  elseif words[1] == "input" then
    local state, err = Input.parse(words, 2)
    if state then
      local ok
      ok, err = client:sendInput(state)
      if ok then report(("sent_input seat=%d seq=%d x=%g y=%g buttons=%d"):format(
        client.playerId, client.seq, state.moveX, state.moveY, state.buttons)) end
    end
    if err then report("ERR " .. err) end
  elseif words[1] == "boon" and #words == 3 then
    local ok, err = client:chooseBoon(words[2], words[3])
    if ok then report("sent_boon seat=" .. client.playerId .. " opportunity=" .. words[2] .. " option=" .. words[3])
    else report("ERR " .. err) end
  else
    report("ERR commands: status | input <x> <y> [V1 action ...] | boon <room/reward/round> <option> | quit")
  end
  return true
end

while true do
  local events, failure = client:poll()
  for _, event in ipairs(events or {}) do
    if event.kind == "welcome" then
      report("joined name=" .. config.playerName .. " seat=" .. client.playerId)
      local ready = assert(io.open(journal .. ".joined", "w"))
      ready:write(tostring(client.playerId))
      ready:close()
    elseif event.kind == "error" then
      reason = event.msg.reason
      report("ERR authority " .. reason)
    end
  end
  assert(not failure, reason or failure)
  assert(client.playerId or socket.gettime() < untilWelcome, "welcome timeout")
  local file = assert(io.open(journal, "rb"))
  assert(file:seek("set", offset))
  local chunk = file:read(4096) or ""
  file:close()
  offset = offset + #chunk
  partial = partial .. chunk
  while true do
    local newline = partial:find("\n", 1, true)
    if not newline then break end
    local line = partial:sub(1, newline - 1)
    partial = partial:sub(newline + 1)
    if not command(line) then client:close(); transcript:close(); return end
  end
  assert(#partial <= 4096, "command too long")
  socket.sleep(0.01)
end
