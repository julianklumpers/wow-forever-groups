local _, ns = ...

-- Who else runs Forever Groups right now: every message on the channel shows
-- its sender is online, and each client announces itself (its version) when
-- it connects and every few minutes after, so idle players are seen too.
local Log = ns.Log

local Presence = {}

local ANNOUNCE_EVERY = 300
-- A newcomer asks who is there (its sync); everyone answers with its
-- announcement once, after a random moment so the answers spread out.
local GREET_DELAY = 8
-- At most one announcement per GREET_GAP; one that is already planned serves
-- every newcomer until it goes out.
local GREET_GAP = 10
-- With many players online only about this many answer; the newcomer sees
-- the others at their next announcement.
local GREET_ANSWERS = 10
-- A little longer than the announce interval, so one late message does not
-- drop a player.
local ONLINE_FOR = 390
-- A party member who sends Forever Groups messages in the party but nothing
-- on our channel this long (after we joined it too) is on another channel:
-- an older version, or WoW splitting channels.
local SPLIT_AFTER = 420
local SPLIT_CHECK = 60

local seen = {}
local onChannel = {}
-- Party members heard from in the party: they run Forever Groups.
local partyHeard = {}
local inPartySince = {}
local splitReported = {}
local greetedAt = -math.huge
local greeting = false

-- onChannelToo: the message came over our channel, not the party.
function Presence.seen(sender, onChannelToo)
    if sender and sender ~= ns.selfName then
        seen[sender] = GetTime()
        if onChannelToo then
            onChannel[sender] = GetTime()
        else
            partyHeard[sender] = true
        end
    end
end

local function recently(at)
    return at ~= nil and GetTime() - at <= ONLINE_FOR
end

function Presence.checkSplit()
    local joined = ns.Comm.connectedAt()
    local now = GetTime()
    local party = ns.Party.members()
    if not party then
        return
    end
    local members = {}
    for _, member in ipairs(party) do
        if UnitIsConnected(member.unit) then
            members[member.name] = true
        end
    end
    for name in pairs(partyHeard) do
        if not members[name] then
            partyHeard[name], inPartySince[name] = nil, nil
        end
    end
    if not joined then
        return
    end
    for name in pairs(members) do
        if partyHeard[name] and not recently(onChannel[name]) then
            inPartySince[name] = inPartySince[name] or now
            if now - inPartySince[name] >= SPLIT_AFTER and now - joined >= SPLIT_AFTER and not splitReported[name] then
                splitReported[name] = true
                Log.info("%s uses Forever Groups but is not on your channel: you can group, but you won't see each "
                    .. "other in the queue. An older Forever Groups, or WoW splitting the channel, can cause this.",
                    name)
            end
        else
            inPartySince[name] = nil
        end
    end
end

-- Whether the player sent Forever Groups messages recently (channel or party).
function Presence.isOnline(name)
    local at = seen[name]
    return at ~= nil and GetTime() - at <= ONLINE_FOR
end

-- The other players seen recently, sorted by name.
function Presence.others()
    local names = {}
    for name, at in pairs(seen) do
        if GetTime() - at <= ONLINE_FOR then
            names[#names + 1] = name
        else
            seen[name] = nil
        end
    end
    table.sort(names)
    return names
end

function Presence.newcomer()
    if greeting then
        return
    end
    local online = #Presence.others() + 1
    if online > GREET_ANSWERS and math.random() > GREET_ANSWERS / online then
        return
    end
    greeting = true
    local wait = math.max(0, greetedAt + GREET_GAP - GetTime()) + math.random() * GREET_DELAY
    C_Timer.After(wait, function()
        greeting = false
        greetedAt = GetTime()
        ns.Version.announce()
    end)
end

function Presence.start()
    C_Timer.NewTicker(ANNOUNCE_EVERY, ns.Version.announce)
    C_Timer.NewTicker(SPLIT_CHECK, Presence.checkSplit)
end

ns.Presence = Presence
