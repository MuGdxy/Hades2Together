local Connection = import("client/connection.lua")

local Play = {}
Play.__index = Play

function Play.new(socket, config)
  return setmetatable({ socket = socket, config = config, retryAt = 0,
    connection = "connecting", sentSeq = 0 }, Play)
end

function Play:step(game)
  local now = self.socket.gettime()
  if now < self.retryAt then return end
  local failure
  if not self.client then
    self.reason = nil
    self.client, failure = Connection.connect(self.socket, self.config.playerPort,
      self.config.playerName, self.config.serverAddress, true)
    self.connection, self.welcomeBy = "connecting", now + 4
  end
  if self.client then
    local items
    items, failure = self.client:poll()
    for _, item in ipairs(items or {}) do
      if item.kind == "error" then self.reason = item.msg.reason end
    end
    if not failure and self.client.playerId then
      self.connection, self.seat = "joined", self.client.playerId
      self.snapshot = self.client.snapshot
      -- A missing local hero/control reader releases the last held sample.
      local state, unavailable = game:ReadLocalInput()
      if unavailable then self.reason = unavailable end
      local ok, err = self.client:sendInput(state or {})
      if not ok then failure = err end
      self.sentSeq = self.client.seq
    elseif not failure and now >= self.welcomeBy then
      failure = "welcome timeout"
    end
  end
  if failure then
    if self.client then self.client:close() end
    self.client, self.seat, self.snapshot = nil, nil, nil
    self.connection, self.retryAt, self.sentSeq = "retrying", now + 1, 0
    if failure ~= "closed" or not self.reason then self.reason = failure end
  end
end

function Play:chooseBoon(opportunity, option)
  if self.connection ~= "joined" then return nil, "seat not connected" end
  return self.client:chooseBoon(opportunity, option)
end

return Play
