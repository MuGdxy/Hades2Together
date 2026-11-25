return function(test, eq)
  local Codec = import("protocol/codec.lua")
  local Client = import("client/connection.lua")
  local Messages = import("protocol/messages.lua")
  local Tcp = import("net/tcp.lua")
  local Transport = import("net/transport.lua")

  local function stub()
    local socket = { incoming = "", sent = "", sendLimit = math.huge }
    function socket:settimeout(timeout)
      eq(timeout, 0)
      return true
    end
    function socket:receive(count)
      local bytes = self.incoming:sub(1, count)
      self.incoming = self.incoming:sub(#bytes + 1)
      if #bytes == count then
        return bytes
      end
      return nil, "timeout", bytes
    end
    function socket:send(data)
      local bytes = data:sub(1, math.min(self.sendLimit, #data))
      self.sent = self.sent .. bytes
      if #bytes == #data then
        return #bytes
      end
      return nil, "timeout", #bytes
    end
    function socket:close()
      self.closed = true
    end
    return socket
  end

  test("TCP preserves split headers and bodies and partial writes", function()
    local sender, receiver = stub(), stub()
    local tx, rx = assert(Tcp.attach(sender)), assert(Tcp.attach(receiver))
    eq(#Transport.check(tx), 0)
    sender.sendLimit = 2
    assert(tx:send("hello", Messages.hello("First")))
    assert(tx:send("hello", Messages.hello("Second")))

    local function transfer(maxBytes)
      sender.sendLimit = maxBytes
      tx:flush()
      receiver.incoming, sender.sent = sender.sent, ""
      return rx:drain()
    end
    eq(#transfer(2), 0) -- first half of the length
    eq(#transfer(5), 0) -- rest of the length and start of the body
    local frames = transfer(1000)
    eq(#frames, 2)
    eq(frames[1].kind, "hello")
    eq(frames[1].msg.name, "First")
    eq(frames[2].msg.name, "Second")
    eq(#rx:drain(), 0)
    rx:close()
    eq(receiver.closed, true)
  end)

  test("TCP bounds message work and rejects a bad length or body", function()
    local socket = stub()
    local stream = assert(Tcp.attach(socket))
    for _ = 1, Tcp.MAX_MESSAGES + 1 do
      assert(stream:send("hello", Messages.hello("A")))
    end
    stream:flush()
    socket.incoming = socket.sent
    eq(#stream:drain(), Tcp.MAX_MESSAGES)
    eq(#stream:drain(), 1)
    socket.incoming = string.char(0, 1, 0, 1)
    eq(#stream:drain(), 0)
    eq(stream.closed, "invalid frame length")
    eq(socket.closed, true)

    socket = stub()
    stream = assert(Tcp.attach(socket))
    socket.incoming = string.char(0, 0, 0, 1) .. "!"
    eq(#stream:drain(), 0)
    eq(stream.closed, "invalid encoded message")
  end)

  test("codec rejects malformed decimal lengths, non-finite numbers and deep data", function()
    for _, data in ipairs({
      "s1.5:abc",
      "a1e3;",
      "o2;s1:as1:bs1:az",
      "n1e999;",
      string.rep("a1;", 26) .. "z",
      string.rep("z", Codec.MAX_BYTES + 1),
    }) do
      local value, err = Codec.decode(data)
      eq(value, nil)
      eq(type(err), "string")
    end
  end)

  test("client replaces the entire view and ignores stale and repeated snapshots", function()
    local wire = stub()
    function wire:connect()
      return true
    end
    local api = { tcp = function() return wire end }
    function wire:settimeout()
      return true
    end
    local client = assert(Client.connect(api, 1, "Player"))
    local sender = stub()
    local tx = assert(Tcp.attach(sender))

    local function deliver(...)
      for _, msg in ipairs({ ... }) do
        assert(tx:send(msg.t, msg))
      end
      tx:flush()
      wire.incoming, sender.sent = sender.sent, ""
      return assert(client:poll())
    end

    local action = { name = "fixture-attack", phase = "active", instanceId = 7 }
    local old = Messages.snapshot(5, { { id = 1, hp = 12 } }, { { id = 2, hp = 20 } })
    local newest = Messages.snapshot(6, { { id = 1, hp = 11, action = action } }, {})
    eq(#deliver(Messages.welcome(1), old), 2)
    eq(client.snapshot.enemies[1].id, 2)
    eq(#deliver(newest, old, Messages.snapshot(6, {}, { { id = 3 } })), 1)
    eq(client.tick, 6)
    eq(#client.snapshot.enemies, 0)
    eq(client.snapshot.heroes[1].hp, 11)
    eq(client.snapshot.heroes[1].action.name, "fixture-attack")
    eq(client.snapshot.heroes[1].action.phase, "active")
    eq(client.snapshot.heroes[1].action.instanceId, 7)
  end)
end
