local _, ns = ...

local Protocol = ns.Protocol
local Party = ns.Party
local Log = ns.Log

-- Keeps party members who have the addon informed about what their party
-- leader's queue is doing, over the PARTY addon channel.
local PartyStatus = {}

local FORMED_SHOWN = 20
local REQUEST_INTERVAL = 10

local RESEND_DELAY = 2

local info
local lastSent
local lastRequest = 0
local resendScheduled = false

-- Roster changes come in bursts (several joins, role changes); the state is
-- sent once when the burst is over instead of once per change.
local function resendSoon()
    if resendScheduled then
        return
    end
    resendScheduled = true
    C_Timer.After(RESEND_DELAY, function()
        resendScheduled = false
        PartyStatus.sendState(true)
    end)
end

local function send(msg)
    local text = Protocol.encode(msg)
    if text and text ~= lastSent then
        lastSent = text
        ns.Comm.sendParty(text)
    end
end

local function isLeader()
    return Party.state() == "leader"
end

-- Leader side: tells the party the current queue state.
function PartyStatus.sendState(force)
    if not isLeader() then
        lastSent = nil
        return
    end
    if force then
        lastSent = nil
    end
    local engine = ns.engine
    local entry = engine and engine.myEntry
    if not entry or #entry.members < 2 then
        send({ kind = "party", phase = "L" })
        return
    end
    local members = {}
    for i, member in ipairs(entry.members) do
        members[i] = { name = member.name, roles = member.roles }
    end
    send({ kind = "party", phase = "Q", joinedAt = entry.joinedAt, dungeons = entry.dungeons, members = members })
end

function PartyStatus.sendProposal(view)
    if isLeader() then
        send({
            kind = "party", phase = "P", dungeon = view.dungeon,
            secondsLeft = math.max(0, view.deadline - GetServerTime()),
        })
    end
end

function PartyStatus.sendFormed(view)
    if isLeader() then
        send({ kind = "party", phase = "F", dungeon = view.dungeon, leader = view.leader })
    end
end

-- Whether the sender is in my party, and whether it leads it.
local function fromMyParty(sender)
    for _, member in ipairs(Party.members() or {}) do
        if member.name == sender then
            return true, UnitIsGroupLeader(member.unit) == true
        end
    end
    return false, false
end

-- Member side. Only the party leader speaks for the party's queue; any
-- member may ask for it (R).
function PartyStatus.onMessage(sender, text)
    local msg = Protocol.decode(text)
    if not msg or msg.kind ~= "party" then
        return
    end
    local inParty, leads = fromMyParty(sender)
    if not inParty or (msg.phase ~= "R" and not leads) then
        return
    end
    local now = GetServerTime()
    if msg.phase == "R" then
        resendSoon()
    elseif msg.phase == "Q" then
        local roles
        for _, member in ipairs(msg.members) do
            if member.name == ns.selfName then
                roles = member.roles
            end
        end
        info = { phase = "queued", leader = sender, joinedAt = msg.joinedAt, roles = roles }
    elseif msg.phase == "P" then
        info = info or { leader = sender }
        info.joinedAt = info.joinedAt or now
        info.phase, info.dungeon, info.expires = "proposal", msg.dungeon, now + msg.secondsLeft
    elseif msg.phase == "F" then
        info = { phase = "formed", leader = msg.leader, dungeon = msg.dungeon, expires = now + FORMED_SHOWN }
    elseif msg.phase == "L" then
        info = nil
    end
    Log.debug("party status from %s: %s", sender, msg.phase)
end

-- What a party member should see, or nil.
function PartyStatus.current()
    if not info or not IsInGroup() or isLeader() then
        info = nil
        return nil
    end
    if info.expires and GetServerTime() > info.expires then
        if info.phase == "proposal" then
            info.phase, info.expires = "queued", nil
        else
            info = nil
            return nil
        end
    end
    return info
end

local function onRosterUpdate()
    if not IsInGroup() then
        info, lastSent = nil, nil
        return
    end
    if isLeader() then
        resendSoon()
    elseif not info and GetServerTime() - lastRequest >= REQUEST_INTERVAL then
        lastRequest = GetServerTime()
        local text = Protocol.encode({ kind = "party", phase = "R" })
        ns.Comm.sendParty(text)
    end
end

function PartyStatus.init()
    ns.on("GROUP_ROSTER_UPDATE", onRosterUpdate)
end

-- After connecting: a member asks the leader for the current state.
function PartyStatus.onReady()
    onRosterUpdate()
end

ns.PartyStatus = PartyStatus
