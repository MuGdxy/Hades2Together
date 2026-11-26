-- Record complete snapshots from the read-only listener. No player slot is used.
local root = assert(arg[1])
package.path = root .. "/Ship/ReturnOfModding/plugins/MuGdxy-Hades2Together/?.lua;" .. package.path
function import(path) return require((path:gsub("%.lua$", ""):gsub("/", "."))) end
local Client = import("client/connection.lua")
local Bridge = import("dev/bridge.lua")
local socket = require("socket")
local deadline = socket.gettime() + 90
local client
repeat
  client = Client.connect(socket, 27778, "PartyObserver")
  if not client then socket.sleep(0.1) end
until client or socket.gettime() > deadline
assert(client, "authority observer unavailable")
local output = assert(io.open(root .. "/snapshots.tsv", "wb"))
local received = false
local ready = false
while true do
  local events, failure = client:poll()
  for _, event in ipairs(events or {}) do
    local snap = event.msg
    if snap.t == "snap" then
      received = true
      local room = snap.room
      local prefix = table.concat({ socket.gettime(), snap.tick, room and room.id or "-", room and room.name or "-" }, "\t") .. "\t"
      for _, hero in ipairs(snap.heroes) do output:write(prefix, Bridge.actorLine("hero", hero), "\n") end
      for _, enemy in ipairs(snap.enemies) do output:write(prefix, Bridge.actorLine("enemy", enemy), "\n") end
      for _, line in ipairs(Bridge.claimLines(room and room.rewards)) do output:write(prefix, line, "\n") end
      output:flush()
      if not ready and room and room.name == "F_Combat02" and not room.leaving and snap.heroes[1] then
        local path = root .. "/room-ready.txt"
        local marker = assert(io.open(path .. ".tmp", "wb"))
        assert(marker:write(("room=%s id=%d tick=%d hero=%d\n"):format(room.name, room.id, snap.tick, snap.heroes[1].id)))
        assert(marker:close())
        assert(os.rename(path .. ".tmp", path))
        ready = true
      end
    end
  end
  if failure then
    assert(received and failure == "closed", failure)
    break
  end
  socket.sleep(0.01)
end
client:close()
output:close()
