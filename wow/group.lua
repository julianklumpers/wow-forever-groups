local _, ns = ...

local Log = ns.Log

local Group = {}

local SESSION_TIMEOUT = 120

local pending = {}
local blocked = false
-- { name, at }: the leader of the group just formed, whose invite we expect.
local expected
local session

local function whisper(name, text)
    return ns.Whispers.sendIfAllowed(name, text)
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

local function inPartyWith(name)
    for _, member in ipairs(ns.Party.members() or {}) do
        if member.name == name then
            return true
        end
    end
    return false
end

-- view.queue is "quests" for a questing group and "battlegrounds" for a
-- battleground group: no dungeon to follow and no places for the dungeon
-- filler.
function Group.formed(view)
    local quest = view.queue ~= nil
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
        session = { role = "member", leader = view.leader, dungeon = view.dungeon, startedAt = GetServerTime() }
        if inPartyWith(view.leader) then
            -- The leader's invite came (and was accepted) before this news.
            expected = nil
            return
        end
        expected = { name = view.leader, at = GetServerTime() }
        Log.info("Group formed for %s. Accept the invite from %s.", dungeon, view.leader)
        if IsInGroup() then
            Log.warn("You are still in a group; leave it to accept the invite.")
        end
        return
    end
    expected = nil

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
    local mine
    for _, member in ipairs(view.members) do
        if member.name == ns.selfName then
            mine = member.role
        end
    end
    local english = (view.queue == nil and ns.Dungeons.englishName(view.dungeon))
        or (view.queue == "battlegrounds" and ns.Battlegrounds.englishName(ns.Battlegrounds.parseKey(view.dungeon)))
        or dungeon
    local text = ns.Messages.text("groupInvite", { dungeon = english, spec = ns.Spec.myLabel(mine) })
    for _, name in ipairs(others) do
        whisper(name, text)
        invite(name)
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
        ns.Status.complete(string.format(ns.L["You joined %s's group."], session.leader))
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
-- An invite from a group listed in WoW's Group Finder shows WoW's role
-- window (LFGInvitePopup) instead; it stays up after joining, so it is
-- closed and the role set for the player (verified in Forever with the
-- probe: the window and StaticPopupSpecial_Hide exist).
local function closeRoleWindow()
    local popup = LFGInvitePopup
    if type(popup) ~= "table" or not popup.IsShown or not popup:IsShown() then
        return
    end
    if type(StaticPopupSpecial_Hide) ~= "function" or not pcall(StaticPopupSpecial_Hide, popup) then
        pcall(popup.Hide, popup)
    end
end

-- role: the role ("T", "H", "D") to play in the joined group, or nil.
local function acceptInvite(role)
    if IsInGroup() or type(AcceptGroup) ~= "function" then
        return false
    end
    if role then
        ns.RoleSync.expect(ns.selfName, role)
    end
    local ok = pcall(AcceptGroup)
    if ok and type(StaticPopup_Hide) == "function" then
        -- WoW's invite popup declines the invite when it is hidden unless
        -- it was marked accepted.
        local shown = type(StaticPopup_Visible) == "function" and StaticPopup_Visible("PARTY_INVITE")
        local popup = shown and _G[shown]
        if type(popup) == "table" then
            popup.inviteAccepted = 1
        end
        pcall(StaticPopup_Hide, "PARTY_INVITE")
    end
    if ok then
        closeRoleWindow()
        if C_Timer and C_Timer.After then
            C_Timer.After(0.3, closeRoleWindow)
            C_Timer.After(1, closeRoleWindow)
        end
    end
    return ok
end

-- The leader of a proposal the player accepted that is still open: its
-- invite can arrive before the last answer reaches this client.
local function acceptedProposalLeader(inviter)
    for _, engine in ipairs(ns.Queues.engines()) do
        local proposal = engine and engine.myProposalKey and engine.proposals[engine.myProposalKey]
        if proposal and not proposal.outcome and proposal.leader == inviter
            and proposal.answers[engine.name] == "Y" then
            return true
        end
    end
    return false
end

local function expects(inviter)
    if expected and GetServerTime() - expected.at > SESSION_TIMEOUT then
        expected = nil
    end
    return (expected ~= nil and inviter == expected.name) or acceptedProposalLeader(inviter)
end

local function onInviteRequest(inviter)
    if expects(inviter) then
        expected = nil
        if not ns.db.noAutoAccept and acceptInvite() then
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

Group.acceptInvite = acceptInvite

function Group.init()
    ns.on("CHAT_MSG_SYSTEM", onSystemMessage)
    ns.on("ADDON_ACTION_BLOCKED", onActionBlocked)
    ns.on("ADDON_ACTION_FORBIDDEN", onActionBlocked)
    ns.on("GROUP_ROSTER_UPDATE", onRosterUpdate)
    ns.on("PARTY_INVITE_REQUEST", onInviteRequest)
end

ns.Group = Group
