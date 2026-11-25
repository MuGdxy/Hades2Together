local socket = require("socket")
local directory = arg[2]
local Support = {}

function Support.mark(name, value)
  local path = directory .. "/" .. name
  local file = assert(io.open(path .. ".tmp", "w"))
  assert(file:write(tostring(value), "\n"))
  assert(file:close())
  assert(os.rename(path .. ".tmp", path))
end

function Support.marked(name)
  local file = io.open(directory .. "/" .. name, "r")
  if file then
    file:close()
    return true
  end
end

function Support.waitFor(label, poll)
  local deadline = socket.gettime() + 10
  repeat
    local value = poll()
    if value then
      return value
    end
    socket.sleep(0.01)
  until socket.gettime() >= deadline
  error("timed out waiting for " .. label)
end

function Support.equal(actual, expected, label)
  assert(actual == expected, label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

return Support
