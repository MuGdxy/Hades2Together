local Actions = import("protocol/actions.lua")
local Input = import("client/input.lua")
local Messages = import("protocol/messages.lua")
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
    if not Session.findSeat(console.session, name) then
      return name
    end
  end
end

local function findSlot(session, token)
  local index = tonumber(token)
  if index and session.slots[index] then
    return index
  end
  return Session.findSeat(session, token)
end

local function roster(session)
  local parts = {}
  local seats = {}
  for index in pairs(session.slots) do
    seats[#seats + 1] = index
  end
  table.sort(seats)
  for _, index in ipairs(seats) do
    local slot = session.slots[index]
    local state = slot.connected and "up" or "down"
    parts[#parts + 1] = index .. ":" .. slot.name .. ":" .. state
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

local function submitSample(words, submitInput, maxPlayers)
  local seatText = words[2]
  local seat = seatText and seatText:match("^%d+$") and tonumber(seatText)
  if not Session.validSeat(seat, maxPlayers) then
    return "ERR input seat must be 1-" .. maxPlayers
  end
  local sample, errorMessage = Input.parse(words, 3)
  if not sample then return "ERR " .. errorMessage end
  if not submitInput then
    return "ERR input submission unavailable"
  end
  local ok, reason = submitInput(seat, sample)
  if not ok then
    return "ERR input " .. reason
  end
  return "OK input " .. seat
end

function Console.execute(console, line, submitInput, submitBoon, killAll)
  if type(line) ~= "string" then
    return "ERR empty"
  end
  if line:find("[\r\n]") then
    return "ERR expected one command per line"
  end
  line = line:gsub("^%s+", ""):gsub("%s+$", "")
  if line == "" then
    return "ERR empty"
  end

  local words = tokens(line)
  local head = words[1]
  local session = console.session

  if head == "help" then
    return "OK commands: help | status | players | player add [name] | player remove <slot|name> | enter [map] | play"
      .. " | env kill-all | boon <seat> <room/reward/round> <option> | input <seat> <moveX> <moveY> [action ...]; V" .. Actions.VERSION .. " actions: " .. Actions.names()
      .. "; player remove marks the seat offline; player add with the same name reconnects it"
  end

  if head == "input" then
    return submitSample(words, submitInput, Session.capacity(session))
  end

  if head == "env" then
    if #words ~= 2 or words[2] ~= "kill-all" then return "ERR usage: env kill-all" end
    if not Session.isAuthority(session) or not killAll then return "ERR env kill-all requires local authority" end
    local request, reason = killAll()
    if not request then return "ERR env kill-all " .. reason end
    return "OK env kill-all accepted request=" .. request
  end

  if head == "boon" then
    if not Session.isAuthority(session) or not submitBoon then return "ERR boon requires local authority" end
    local seat = tonumber((words[2] or ""):match("^[1-9]%d*$") or "")
    local room, reward, round = Messages.boonScope(words[3])
    if #words ~= 4 or not Session.validSeat(seat, Session.capacity(session)) or not room
      or #words[4] > 128 or not words[4]:match("^[%w_]+$") then
      return "ERR usage: boon <seat> <room/reward/round> <option>"
    end
    local id, reason = submitBoon(seat, room, reward, round, words[4])
    local request = "boon seat=" .. seat .. " opportunity=" .. words[3] .. " option=" .. words[4]
    if not id then return "ERR " .. request .. " " .. tostring(reason) end
    return "OK " .. request .. " instance=" .. id
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
    Session.release(session, slot)
    return string.format("OK offline %d %s", slot, name)
  end

  return "ERR unknown command"
end

return Console
