local _, ns = ...
ns = ns or {}

-- How many messages one sender may send: a token bucket per sender. A sender
-- that empties its bucket is muted for a while, so a flood is cut off as a
-- whole instead of trickling through at the refill rate.
local RateLimit = {}
RateLimit.__index = RateLimit

-- The own Outbox never sends more than 6 at once and 1 per second after that
-- (both queues together), so a normal client never empties the bucket.
local DEFAULTS = {
    capacity = 20,
    refillPerSecond = 1,
    muteSeconds = 300,
}

local PRUNE_EVERY = 200

function RateLimit.new(opts)
    local self = setmetatable({}, RateLimit)
    for key, value in pairs(DEFAULTS) do
        self[key] = opts[key] or value
    end
    self.clock = opts.clock
    self.senders = {}
    self.calls = 0
    return self
end

function RateLimit:prune(now)
    for key, state in pairs(self.senders) do
        local full = state.tokens + (now - state.at) * self.refillPerSecond >= self.capacity
        if full and now >= state.mutedUntil then
            self.senders[key] = nil
        end
    end
end

-- Returns whether the message may be handled, and true the moment the sender
-- gets muted.
function RateLimit:allow(key)
    local now = self.clock()
    self.calls = self.calls + 1
    if self.calls % PRUNE_EVERY == 0 then
        self:prune(now)
    end
    local state = self.senders[key]
    if not state then
        state = { tokens = self.capacity, at = now, mutedUntil = -math.huge }
        self.senders[key] = state
    end
    if now < state.mutedUntil then
        return false, false
    end
    state.tokens = math.min(self.capacity, state.tokens + (now - state.at) * self.refillPerSecond)
    state.at = now
    if state.tokens < 1 then
        state.mutedUntil = now + self.muteSeconds
        state.tokens = self.capacity
        return false, true
    end
    state.tokens = state.tokens - 1
    return true, false
end

function RateLimit:isMuted(key)
    local state = self.senders[key]
    return state ~= nil and self.clock() < state.mutedUntil
end

ns.RateLimit = RateLimit
return RateLimit
