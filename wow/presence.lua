local _, ns = ...

-- Who else runs Forever Groups right now: every message on the channel shows
-- its sender is online, and each client announces itself (its version) when
-- it connects and every few minutes after, so idle players are seen too.
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

local seen = {}
local greetedAt = -math.huge
local greeting = false

function Presence.seen(sender)
    if sender and sender ~= ns.selfName then
        seen[sender] = GetTime()
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
end

ns.Presence = Presence
