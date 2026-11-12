local _, ns = ...

local Log = ns.Log

local Group = {}

local INVITE_SPACING = 0.5

local SESSION_TIMEOUT = 120

local pending = {}
local blocked = false
local expectedLeader
local session

local function whisper(name, text)
    if not text or ns.db.noWhisper then
        return
    end
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        return
    end
    local send = C_ChatInfo.SendChatMessage or SendChatMessage
    local ok, err = pcall(send, text, "WHISPER", nil, name)
    if not ok then
        Log.debug("whisper to %s failed: %s", name, tostring(err))
    end
end

local function invite(name)
    local ok, err = pcall(C_PartyInfo.InviteUnit, name)
    if not ok then
        Log.warn("Inviting %s failed: %s", name, tostring(err))
    end
end

function Group.inviteAll()
    local names = {}
    for name in pairs(pending) do
        names[#names + 1] = name
    end
    table.sort(names)
    if #names == 0 then
        Log.info("No invites to send.")
        return
    end
    blocked = false
    for _, name in ipairs(names) do
        invite(name)
    end
end

local function fakeCount(view)
    local count, leaderIsFake = 0, false
    for _, member in ipairs(view.members) do
        if member.fake then
            count = count + 1
            leaderIsFake = leaderIsFake or member.name == view.leader
        end
    end
    return count, leaderIsFake
end

-- view.queue is "quests" for a questing group: no dungeon to follow and no
-- Group Finder places to fill.
function Group.formed(view)
    local quest = view.queue == "quests"
    local dungeon = ns.Quests.nameOf(view.dungeon)
    local fakes, leaderIsFake = fakeCount(view)
    -- A test group with fakes never becomes a real party: nothing to follow.
    if not quest and fakes == 0 then
        ns.GroupView.track(view.dungeon, view.playstyles)
    end
    for _, member in ipairs(view.members) do
        ns.RoleSync.expect(member.name, member.role)
    end
    ns.RoleSync.apply()
    if leaderIsFake then
        Log.info("Test group for %s complete. Its leader is a fake player, so nobody is invited.", dungeon)
        return
    end
    if not view.isLeader then
        ns.Filler.stop()
        expectedLeader = view.leader
        session = { role = "member", leader = view.leader, dungeon = view.dungeon, startedAt = GetServerTime() }
        Log.info("Group formed for %s. Accept the invite from %s.", dungeon, view.leader)
        if IsInGroup() then
            Log.warn("You are still in a group; leave it to accept the invite.")
        end
        return
    end

    pending = {}
    local others = {}
    for _, member in ipairs(view.members) do
        if member.owner ~= ns.selfName and not member.fake then
            pending[member.name] = true
            others[#others + 1] = member.name
        end
    end
    Log.info("Group formed for %s. You are the leader; inviting %d players.", dungeon, #others)
    if #others > 0 then
        session = {
            role = "leader", leader = ns.selfName, dungeon = view.dungeon, total = #others, startedAt = GetServerTime(),
        }
    end
    if not quest and ns.Features.fill() and not ns.Filler.adopt(view) and view.missing and view.missing ~= "" then
        local names = {}
        for _, member in ipairs(view.members) do
            names[#names + 1] = member.name
        end
        ns.Filler.start({ dungeon = view.dungeon, missing = view.missing, members = names })
    end
    if fakes > 0 then
        Log.info("%d fake players are not invited.", fakes)
    end
    for i, name in ipairs(others) do
        C_Timer.After(INVITE_SPACING * i, function()
            whisper(name, ns.Messages.text("groupInvite", { dungeon = dungeon, spec = ns.Spec.myLabel() }))
            invite(name)
        end)
    end
end

local function onActionBlocked(addon, func)
    if addon == ns.addonName and type(func) == "string" and string.find(func, "InviteUnit") and not blocked then
        blocked = true
        Log.warn("WoW blocked the automatic invite. Type /fg invite to send the invites.")
    end
end

local function partyNames()
    local names = {}
    for _, member in ipairs(ns.Party.members() or {}) do
        names[member.name] = true
    end
    return names
end

local function onRosterUpdate()
    local names = partyNames()
    for name in pairs(pending) do
        if names[name] then
            pending[name] = nil
        end
    end
    if not session then
        return
    end
    if session.role == "leader" and next(pending) == nil then
        session = nil
    elseif session.role == "member" and names[session.leader] then
        ns.Status.complete("You joined " .. session.leader .. "'s group.")
        session = nil
    end
end

-- A player Forever Groups invited into this group who has not joined yet.
function Group.isExpected(name)
    return pending[name] == true and Group.status() ~= nil
end

-- What happens after a group formed: { role = "leader"|"member", leader,
-- dungeon, total, joined }, or nil.
function Group.status()
    if not session then
        return nil
    end
    if GetServerTime() - session.startedAt > SESSION_TIMEOUT then
        session = nil
        return nil
    end
    if session.role == "leader" then
        local waiting = 0
        for _ in pairs(pending) do
            waiting = waiting + 1
        end
        session.joined = session.total - waiting
    end
    return session
end

-- Everyone said yes in the proposal popup, so the expected leader's invite
-- is accepted without a second click (verified in Forever: AcceptGroup from
-- this event joins, StaticPopup_Hide removes WoW's invite popup).
local function acceptInvite()
    if ns.db.noAutoAccept or IsInGroup() or type(AcceptGroup) ~= "function" then
        return false
    end
    local ok = pcall(AcceptGroup)
    if ok and type(StaticPopup_Hide) == "function" then
        pcall(StaticPopup_Hide, "PARTY_INVITE")
    end
    return ok
end

local function onInviteRequest(inviter)
    if expectedLeader and inviter == expectedLeader then
        expectedLeader = nil
        if acceptInvite() then
            Log.info("Joined %s's group.", inviter)
            return
        end
        ns.Notify.attention()
        Log.info("This is your Forever Groups invite from %s.", inviter)
    end
end

local function onSystemMessage(text)
    local name = ns.Filler.declinedName(text)
    if name and pending[name] then
        pending[name] = nil
        ns.RoleSync.forget(name)
        Log.info("%s did not accept the group invite.", name)
    end
end

function Group.init()
    ns.on("CHAT_MSG_SYSTEM", onSystemMessage)
    ns.on("ADDON_ACTION_BLOCKED", onActionBlocked)
    ns.on("ADDON_ACTION_FORBIDDEN", onActionBlocked)
    ns.on("GROUP_ROSTER_UPDATE", onRosterUpdate)
    ns.on("PARTY_INVITE_REQUEST", onInviteRequest)
end

ns.Group = Group
