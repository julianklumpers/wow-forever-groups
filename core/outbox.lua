local _, ns = ...
ns = ns or {}

-- Token-bucket send queue. The WoW layer passes a transmit function that
-- returns one of:
--   "ok"        sent
--   "throttled" server refused because of rate limits; retry later
--   "blocked"   messaging is locked down (instance/combat); retry later
--   "error"     message can never be sent; dropped
local Outbox = {}
Outbox.__index = Outbox

Outbox.HIGH, Outbox.NORMAL, Outbox.LOW = 1, 2, 3

local DEFAULTS = {
    capacity = 6,
    refillPerSecond = 1,
    throttleBackoff = 2,
    blockedBackoff = 5,
    maxQueued = 60,
}

function Outbox.new(opts)
    local self = setmetatable({}, Outbox)
    for key, value in pairs(DEFAULTS) do
        self[key] = opts[key] or value
    end
    self.clock = opts.clock
    self.transmit = opts.transmit
    self.onDrop = opts.onDrop or function() end
    self.tokens = self.capacity
    self.updatedAt = self.clock()
    self.pausedUntil = -math.huge
    self.queue = {}
    self.sequence = 0
    return self
end

function Outbox:refill()
    local now = self.clock()
    self.tokens = math.min(self.capacity, self.tokens + (now - self.updatedAt) * self.refillPerSecond)
    self.updatedAt = now
end

local function before(a, b)
    if a.priority ~= b.priority then
        return a.priority < b.priority
    end
    return a.sequence < b.sequence
end

-- replaceKey: a queued item with the same key is replaced instead of adding a
-- second one (e.g. only the newest heartbeat matters).
function Outbox:push(text, priority, replaceKey)
    priority = priority or Outbox.NORMAL
    if replaceKey then
        for _, item in ipairs(self.queue) do
            if item.replaceKey == replaceKey then
                item.text = text
                return
            end
        end
    end
    self.sequence = self.sequence + 1
    self.queue[#self.queue + 1] = {
        text = text, priority = priority, replaceKey = replaceKey, sequence = self.sequence,
    }
    table.sort(self.queue, before)
    while #self.queue > self.maxQueued do
        local dropped = table.remove(self.queue)
        self.onDrop(dropped.text, "queue full")
    end
end

-- Drops a queued item that has not been sent yet.
function Outbox:remove(replaceKey)
    for i, item in ipairs(self.queue) do
        if item.replaceKey == replaceKey then
            table.remove(self.queue, i)
            return true
        end
    end
    return false
end

function Outbox:size()
    return #self.queue
end

function Outbox:flush()
    self:refill()
    local sent = 0
    while #self.queue > 0 and self.clock() >= self.pausedUntil and self.tokens >= 1 do
        local item = self.queue[1]
        local result = self.transmit(item.text)
        if result == "ok" then
            table.remove(self.queue, 1)
            self.tokens = self.tokens - 1
            sent = sent + 1
        elseif result == "throttled" then
            self.tokens = 0
            self.pausedUntil = self.clock() + self.throttleBackoff
        elseif result == "blocked" then
            self.pausedUntil = self.clock() + self.blockedBackoff
        else
            table.remove(self.queue, 1)
            self.onDrop(item.text, tostring(result))
        end
    end
    return sent
end

ns.Outbox = Outbox
return Outbox
