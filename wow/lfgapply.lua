local _, ns = ...

local Dungeons = ns.Dungeons
local LfgPick = ns.LfgPick
local Log = ns.Log
local Widgets = ns.Widgets

-- The other direction: a solo player asks groups listed in WoW's Group Finder
-- that need one of their roles to invite them, and waits a short while for an
-- invite. Forever's Group Finder is the board-style one, without applications:
-- asking is a whisper to the leader, as its own "Send Message" does. Inviting
-- players yourself makes you a party leader at once, after which another
-- group's invite cannot be accepted, so building your own group only starts
-- when no group fits or no invite came in time.
local Apply = {}

-- One leader at a time: two invites at once would leave one leader
-- waiting for nothing. The next is asked when this one sent no invite.
local ASK_TIMEOUT = 20
-- A leader who whispered yes gets this long to send the invite, also past
-- the time we would otherwise start building our own group.
local PROMISE_WAIT = 30
local WAIT_FOR_INVITE = 60
local ASK_SPACING = 2
local INVITE_VALID = 60
-- The Find group click searches a moment before the first tick sees us
-- seeking; that search still counts as fresh.
local SEARCH_SLACK = 2
-- How long a request the player clicked (Who is looking) is remembered, so
-- the leader's invite is recognised.
local REQUEST_KEPT = 300

local asks = {}
-- A leader asked automatically is not asked again for a while, also in a
-- later queue or after a reload: they said no, or did not answer.
local ASKED_COOLDOWN = 15 * 60
local seekingSince
local seekingStartedAt
local lastAskAt = -math.huge

-- Group Finder results from a search made after this search started; older
-- ones may be for other dungeons or about groups that have filled since.
local function freshResults()
    local _, updatedAt = ns.LfgList.listings()
    return updatedAt ~= nil and seekingStartedAt ~= nil and updatedAt >= seekingStartedAt
end

local function proposalOpen()
    local engine = ns.engine
    local proposal = engine and engine.myProposalKey and engine.proposals[engine.myProposalKey]
    return proposal ~= nil and not proposal.outcome
end

-- The automatic asks; the player's own requests (Who is looking) do not
-- count against them.
local function askCount()
    local count = 0
    for _, a in pairs(asks) do
        if not a.request then
            count = count + 1
        end
    end
    return count
end

-- A leader who said yes and has not invited yet.
local function promised()
    for _, a in pairs(asks) do
        if a.yesAt and not a.over and GetServerTime() - a.yesAt < PROMISE_WAIT then
            return true
        end
    end
    return false
end

-- An automatic ask still waiting for its invite: not refused, not gone.
local function waitingForInvite()
    for _, a in pairs(asks) do
        if not a.request and not a.over and GetServerTime() - a.at < ASK_TIMEOUT then
            return true
        end
    end
    return promised()
end

-- Results that came in after an ask tell whether its group still has a
-- place for us: gone from the Group Finder or full, the ask is over.
local function settleAsks(roles)
    local _, updatedAt = ns.LfgList.listings()
    for leader, a in pairs(asks) do
        if not a.over and not a.invitedAt and not a.yesAt and updatedAt and a.askedAt and updatedAt > a.askedAt then
            local found
            for _, group in ipairs(ns.LfgList.groups()) do
                if group.leader == leader then
                    found = group
                end
            end
            local room = false
            for role in string.gmatch(found and roles or "", ".") do
                room = room or (found.remaining[role] or 0) > 0
            end
            if not room then
                a.over = true
                Log.info("%s's group %s; asking another.", leader, found and "is full" or "is no longer listed")
            end
        end
    end
end

local function invitedBy()
    for leader, a in pairs(asks) do
        if a.invitedAt then
            return leader, a
        end
    end
end

-- A solo player in the queue who is not building a group yet. A player who
-- would like to lead never asks other groups.
function Apply.isSeeker()
    if not ns.Features.apply() or ns.charDb.wantsLead then
        return false
    end
    local entry = ns.engine and ns.engine.myEntry
    return entry ~= nil and #entry.members == 1 and (entry.reserved or "") == "" and not IsInGroup()
        and not ns.Filler.isActive()
end

-- True once building our own group should take over: no listed group fits,
-- or the leaders asked sent no invite in time.
function Apply.wantsToBuild()
    if not Apply.isSeeker() then
        return true
    end
    if invitedBy() then
        return false
    end
    if promised() then
        return false
    end
    if seekingSince ~= nil and GetServerTime() - seekingSince >= WAIT_FOR_INVITE then
        return true
    end
    return freshResults() and askCount() == 0 and GetTime() - lastAskAt >= ASK_SPACING
end

function Apply.reset()
    asks = {}
    seekingSince, seekingStartedAt = nil, nil
end

local function dropAutomaticAsks()
    for leader, a in pairs(asks) do
        if not a.request or GetServerTime() - a.at > REQUEST_KEPT then
            asks[leader] = nil
        end
    end
end

-- Out of the queue: the automatic asks end, the player's own requests stay
-- for a while.
function Apply.stopSeeking()
    dropAutomaticAsks()
    seekingSince, seekingStartedAt = nil, nil
end

local function askText(pick)
    local roles = {}
    for _, role in ipairs({ "T", "H", "D" }) do
        if (role == "T" and pick.tank) or (role == "H" and pick.healer) or (role == "D" and pick.dps) then
            roles[#roles + 1] = Widgets.ROLE_NAMES[role]
        end
    end
    return ns.Messages.text("applyAsk", {
        level = UnitLevel("player"), spec = ns.Spec.myLabel(), role = table.concat(roles, "/"),
        dungeon = Dungeons.name(pick.dungeon),
    })
end

local ask

-- A click on "Request to join" in Who is looking: asks the leader of a listed
-- group to invite the player (roles: the player's letters), for a dungeon both
-- look for. The invite is then followed like any ask.
function Apply.request(listing, roles, dungeon)
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        Log.info("WoW blocks whispers right now (a boss fight?); try again in a moment.")
        return
    end
    roles = roles or ""
    ask({ leader = listing.leader, dungeon = dungeon, request = true,
        tank = string.find(roles, "T", 1, true) ~= nil, healer = string.find(roles, "H", 1, true) ~= nil,
        dps = string.find(roles, "D", 1, true) ~= nil })
end

function ask(pick)
    lastAskAt = GetTime()
    if ns.db.dryRun then
        Apply.rememberAsk(pick.leader)
        Log.info("[dry run] Would ask %s to invite you for %s.", pick.leader, Dungeons.name(pick.dungeon))
        return
    end
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        return
    end
    local text = askText(pick)
    local ok, err = true, nil
    if text then
        ok, err = ns.Whispers.send(pick.leader, text)
    end
    if not ok then
        Log.debug("asking %s failed: %s", pick.leader, tostring(err))
        return
    end
    if not pick.request then
        Apply.rememberAsk(pick.leader)
    end
    asks[pick.leader] = { dungeon = pick.dungeon, at = GetServerTime(), askedAt = GetTime(), request = pick.request }
    Log.info("Asked %s to invite you for %s.", pick.leader, Dungeons.name(pick.dungeon))
end

-- Follows an invite from a leader we asked: joined, or expired.
local function followInvite()
    local leader, invited = invitedBy()
    if not leader then
        return false
    end
    if IsInGroup() and not UnitIsGroupLeader("player") then
        Log.info("You joined %s's group for %s.", leader, Dungeons.name(invited.dungeon))
        Apply.reset()
        ns.Filler.stop(true)
        if ns.engine and ns.engine.myEntry then
            ns.engine:leave()
        end
        ns.GroupView.track(invited.dungeon)
    elseif GetServerTime() - invited.invitedAt > INVITE_VALID then
        asks[leader] = nil
    end
    return true
end

function Apply.tick()
    if followInvite() then
        return
    end
    if not Apply.isSeeker() then
        Apply.stopSeeking()
        return
    end
    seekingSince = seekingSince or GetServerTime()
    seekingStartedAt = seekingStartedAt or GetTime() - SEARCH_SLACK
    if GetServerTime() - seekingSince >= WAIT_FOR_INVITE and not promised() then
        if askCount() > 0 then
            Log.info("No invite from the groups you asked; building your own group now.")
        end
        dropAutomaticAsks()
        return
    end
    local entry = ns.engine.myEntry
    settleAsks(entry.members[1].roles)
    if waitingForInvite() or GetTime() - lastAskAt < ASK_SPACING or proposalOpen() or not freshResults() then
        return
    end
    local wanted, exclude = {}, {}
    for _, id in ipairs(entry.dungeons) do
        wanted[id] = true
    end
    local groups = ns.Playstyle.filter(ns.LfgList.groups(), entry.playstyle)
    for _, group in ipairs(groups) do
        if Apply.recentlyAsked(group.leader) or asks[group.leader] then
            exclude[group.id] = true
        end
    end
    local pick = LfgPick.groupsToApply(groups, {
        roles = entry.members[1].roles, dungeons = wanted, exclude = exclude, max = 1,
    })[1]
    if pick then
        ask(pick)
    end
end

-- An invite from a leader we asked is joined at once, while still looking
-- (or for a request the player clicked), unless switched off.
-- The role to join an asked group with: DPS while it has a DPS place, else
-- tank, else healer, of the roles the player plays. The open places come
-- from the group's listing, else from the invite (the roles it asks for).
local function joinRole(inviter, tank, healer, dps)
    local entry = ns.engine and ns.engine.myEntry
    local roles = entry and #entry.members == 1 and entry.members[1].roles or ns.charDb.lastRoles
    local remaining
    for _, group in ipairs(ns.LfgList.groups()) do
        if group.leader == inviter then
            remaining = group.remaining
        end
    end
    if not remaining and (tank or healer or dps) then
        remaining = { T = tank and 1 or 0, H = healer and 1 or 0, D = dps and 1 or 0 }
    end
    return LfgPick.joinRole(roles, remaining)
end

local function onInviteRequest(inviter, tank, healer, dps)
    local a = asks[inviter]
    if not a then
        return
    end
    a.invitedAt = GetServerTime()
    local role = joinRole(inviter, tank == true, healer == true, dps == true)
    if not ns.db.noAutoAcceptAsked and (a.request or Apply.isSeeker()) and ns.Group.acceptInvite(role) then
        Log.info("Joined %s's group for %s as %s.", inviter, Dungeons.name(a.dungeon), Widgets.ROLE_NAMES[role] or "?")
        return
    end
    Log.info("%s invited you for %s. Accept the invite!", inviter, Dungeons.name(a.dungeon))
    ns.Notify.attention()
    ns.Status.refresh()
end

function Apply.rememberAsk(leader)
    ns.charDb.askedLeaders = ns.charDb.askedLeaders or {}
    local now = GetServerTime()
    for name, at in pairs(ns.charDb.askedLeaders) do
        if now - at >= ASKED_COOLDOWN then
            ns.charDb.askedLeaders[name] = nil
        end
    end
    ns.charDb.askedLeaders[leader] = now
end

function Apply.recentlyAsked(leader)
    local at = ns.charDb.askedLeaders and ns.charDb.askedLeaders[leader]
    return at ~= nil and GetServerTime() - at < ASKED_COOLDOWN
end

-- For the status bar: { invitedBy = leader, dungeon } or { asked = n, left =
-- seconds until building our own group }, or nil.
function Apply.summary()
    local leader, invited = invitedBy()
    if leader then
        return { invitedBy = leader, dungeon = invited.dungeon }
    end
    local count = askCount()
    if count > 0 and seekingSince then
        return { asked = count, left = math.max(0, WAIT_FOR_INVITE - (GetServerTime() - seekingSince)) }
    end
    return nil
end

-- A whisper from a leader we asked: a clear no moves on to the next group
-- at once, a clear yes holds off asking others while the invite comes.
function Apply.onWhisper(text, sender)
    local a = type(sender) == "string" and asks[sender]
    if not a or a.over or a.invitedAt then
        return
    end
    local ok, answer = pcall(ns.Replies.classify, text)
    if not ok then
        return
    end
    if answer == "no" then
        a.over = true
        Log.info("%s can't take you; asking another group.", sender)
    elseif answer == "yes" then
        a.yesAt = GetServerTime()
    end
end

function Apply.init()
    ns.on("PARTY_INVITE_REQUEST", onInviteRequest)
    ns.on("CHAT_MSG_WHISPER", Apply.onWhisper)
end

ns.Apply = Apply
