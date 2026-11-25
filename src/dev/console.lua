local Session = import("protocol/session.lua")

local Console = {}

local function tokens(line)
  local out = {}
  for word in line:gmatch("%S+") do
    out[#out + 1] = word
  end
  return out
end

local function freshName(console)
  while true do
    console.fakeSerial = console.fakeSerial + 1
    local name = "Fake" .. tostring(console.fakeSerial)
    local taken = false
    for index = 1, Session.MAX_PLAYERS do
      local slot = console.session.slots[index]
      if slot and slot.name == name then
        taken = true
      end
    end
    if not taken then
      return name
    end
  end
end

local function findSlot(session, token)
  local index = tonumber(token)
  if index and session.slots[index] then
    return index
  end
  for seat = 1, Session.MAX_PLAYERS do
    local slot = session.slots[seat]
    if slot and slot.name == token then
      return seat
    end
  end
end

local function roster(session)
  local parts = {}
  for index = 1, Session.MAX_PLAYERS do
    local slot = session.slots[index]
    if slot then
      local state = slot.connected and "up" or "down"
      parts[#parts + 1] = index .. ":" .. slot.name .. ":" .. state
    end
  end
  if #parts == 0 then
    return "none"
  end
  return table.concat(parts, " ")
end

function Console.new(session)
  return {
    session = session,
    fakeSerial = 0,
  }
end

function Console.roster(console)
  return roster(console.session)
end

function Console.execute(console, line)
  if type(line) ~= "string" then
    return "ERR empty"
  end
  line = line:gsub("\r", "")
  line = line:gsub("^%s+", ""):gsub("%s+$", "")
  if line == "" then
    return "ERR empty"
  end

  local words = tokens(line)
  local head = words[1]
  local session = console.session

  if head == "help" then
    return "OK commands: help | status | players | player add [name] | player remove <slot|name> | enter [map] | play"
  end

  if head == "play" then
    console.play = true
    return "OK play"
  end

  if head == "enter" then
    local mapName = words[2] or "F_Test"
    if #words > 2 or not mapName:match("^[%w_]+$") then
      return "ERR bad map; use enter F_Test"
    end
    console.enterMap = mapName
    return "OK enter " .. mapName
  end

  if head == "status" then
    return string.format(
      "OK role=%s players=%d roster=%s",
      session.role,
      Session.count(session),
      roster(session)
    )
  end

  if head == "players" then
    return "OK " .. roster(session)
  end

  if head == "player" and words[2] == "add" then
    local name
    if #words >= 3 then
      name = table.concat(words, " ", 3)
    else
      name = freshName(console)
    end
    local slot, how = Session.join(session, name)
    if not slot then
      return "ERR " .. tostring(how)
    end
    return string.format("OK %s %d %s", how, slot, name)
  end

  if head == "player" and words[2] == "remove" then
    if not words[3] then
      return "ERR name required"
    end
    local token = table.concat(words, " ", 3)
    local slot = findSlot(session, token)
    if not slot then
      return "ERR not found"
    end
    local name = session.slots[slot].name
    Session.drop(session, slot)
    return string.format("OK dropped %d %s", slot, name)
  end

  return "ERR unknown command"
end

return Console
