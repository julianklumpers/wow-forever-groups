local _, ns = ...
ns = ns or {}

-- The leaders of listed groups a player asked to invite them (the
-- battleground and questing finders): when, from which Group Finder result,
-- with which role, and how it went. An ask waits `wait` seconds for an
-- invite, `promiseWait` after the leader said yes; a no, or the group
-- leaving the Group Finder, ends it.
local Asks = {}
Asks.__index = Asks

-- clock: function() -> seconds; find(names, name): the key of names that is
-- this player, with or without a realm (Whispers.find).
function Asks.new(opts)
    return setmetatable({
        clock = opts.clock, findName = opts.find, wait = opts.wait, promiseWait = opts.promiseWait,
        list = {},
    }, Asks)
end

-- request: the player asked this one themselves (Who is looking), not the
-- finder.
function Asks:add(leader, listingId, role, request)
    self.list[leader] = { at = self.clock(), listingId = listingId, role = role, request = request or nil }
end

-- The key an incoming name is stored under, or nil.
function Asks:find(name)
    return self.findName(self.list, name)
end

function Asks:get(name)
    local key = self:find(name)
    return key and self.list[key], key
end

function Asks:any()
    return next(self.list) ~= nil
end

-- Keeps only the player's own requests younger than `age` seconds; returns
-- whether any ask of the finder's own was dropped.
function Asks:keepRequests(age)
    local dropped = false
    for leader, ask in pairs(self.list) do
        if not ask.request or self.clock() - ask.at >= age then
            self.list[leader] = nil
            dropped = dropped or not ask.request
        end
    end
    return dropped
end

local function promised(self, ask)
    return ask.yesAt ~= nil and self.clock() - ask.yesAt < self.promiseWait
end

-- Asks still waiting for an invite.
function Asks:waiting()
    local count = 0
    for _, ask in pairs(self.list) do
        if not ask.over and (self.clock() - ask.at < self.wait or promised(self, ask)) then
            count = count + 1
        end
    end
    return count
end

-- After results newer than an ask, or once its group is known to have left
-- (delisted(listingId)): one whose group is no longer listed (listed(leader,
-- listingId) is false) ends. Returns the leaders it ended.
function Asks:settle(updatedAt, listed, delisted)
    local ended = {}
    for leader, ask in pairs(self.list) do
        local news = (updatedAt or 0) > ask.at or (delisted ~= nil and delisted(ask.listingId))
        if not ask.over and not ask.yesAt and news and not listed(leader, ask.listingId) then
            ask.over = true
            ended[#ended + 1] = leader
        end
    end
    table.sort(ended)
    return ended
end

-- answer: "yes", "no" or nil (unclear), from core/replies.lua.
function Asks:answer(leader, answer)
    local ask = self.list[leader]
    if not ask then
        return
    end
    if answer == "no" then
        ask.over = true
    elseif answer == "yes" then
        ask.yesAt = self.clock()
    end
end

-- True the first time only: a leader's question is answered once.
function Asks:firstQuestion(leader)
    local ask = self.list[leader]
    if not ask or ask.answered then
        return false
    end
    ask.answered = true
    return true
end

ns.Asks = Asks
return Asks
