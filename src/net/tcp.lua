local Codec = import("protocol/codec.lua")

local Tcp = { HOST = "127.0.0.1", MAX_MESSAGES = 16 }
local Stream = {}
Stream.__index = Stream

local MAX_QUEUED_BYTES = 4 * (Codec.MAX_BYTES + 4)

local function header(length)
  return string.char(
    math.floor(length / 16777216),
    math.floor(length / 65536) % 256,
    math.floor(length / 256) % 256,
    length % 256
  )
end

function Tcp.attach(socket)
  local ok, err = socket:settimeout(0)
  if not ok then
    socket:close()
    return nil, err
  end
  return setmetatable({ socket = socket, incoming = "", needed = 4, outgoing = "" }, Stream)
end

function Tcp.listen(api, port)
  local socket, err = api.tcp()
  if not socket then
    return nil, err
  end
  local ok
  ok, err = socket:bind(Tcp.HOST, port)
  if ok then
    ok, err = socket:listen()
  end
  if ok then
    ok, err = socket:settimeout(0)
  end
  if not ok then
    socket:close()
    return nil, err
  end
  return socket
end

function Tcp.connect(api, port)
  local socket, err = api.tcp()
  if not socket then
    return nil, err
  end
  local ok
  ok, err = socket:settimeout(2)
  if ok then
    ok, err = socket:connect(Tcp.HOST, port)
  end
  if not ok then
    socket:close()
    return nil, err
  end
  return Tcp.attach(socket)
end

function Stream:close(reason)
  if not self.closed then
    self.closed = reason or "closed"
    self.socket:close()
    self.incoming, self.outgoing = "", ""
  end
end

function Stream:send(kind, msg)
  if self.closed then
    return nil, self.closed
  end
  if type(msg) ~= "table" or msg.t ~= kind then
    return nil, "invalid message kind"
  end
  local bytes = Codec.encode(msg)
  if #bytes > Codec.MAX_BYTES then
    return nil, "message byte limit"
  end
  if #self.outgoing + 4 + #bytes > MAX_QUEUED_BYTES then
    return nil, "send queue full"
  end
  self.outgoing = self.outgoing .. header(#bytes) .. bytes
  return true
end

function Stream:flush()
  if self.closed or self.outgoing == "" then
    return
  end
  local sent, err, partial = self.socket:send(self.outgoing)
  self.outgoing = self.outgoing:sub((sent or partial or 0) + 1)
  if not sent and err ~= "timeout" then
    self:close(err)
  end
end

function Stream:finish(reason, deadline)
  self.closing = reason
  self.deadline = deadline
end

function Stream:drain()
  local items = {}
  while not self.closed and not self.closing and #items < Tcp.MAX_MESSAGES do
    local data, err, partial = self.socket:receive(self.needed - #self.incoming)
    self.incoming = self.incoming .. (data or partial or "")
    if not data then
      if err ~= "timeout" then
        self:close(err)
      end
      break
    end
    if not self.readingBody then
      local a, b, c, d = self.incoming:byte(1, 4)
      self.needed = ((a * 256 + b) * 256 + c) * 256 + d
      if self.needed == 0 or self.needed > Codec.MAX_BYTES then
        self:close("invalid frame length")
        break
      end
      self.readingBody = true
    else
      local msg = Codec.decode(self.incoming)
      if type(msg) ~= "table" or type(msg.t) ~= "string" then
        self:close("invalid encoded message")
        break
      end
      items[#items + 1] = { kind = msg.t, msg = msg }
      self.readingBody, self.needed = false, 4
    end
    self.incoming = ""
  end
  return items
end

return Tcp
