local _, ns = ...

local Log = ns.Log
local Battlegrounds = ns.Battlegrounds

-- Find group on the Battlegrounds tab, through WoW's Group Finder (which
-- lists Warsong Gulch only). Alone, it first asks the leaders of listed
-- groups in the player's level bracket to invite them, one at a time, and
-- joins when one does; without an invite (or when the player would like to
-- lead) it builds the group from listed solo players instead, up to the
-- chosen size, turning the party into a raid past five. Signing up stays
-- the leader's: at a battlemaster, as a group.
local BgFinder = {}

local ASK_WAIT = 20
local PROMISE_WAIT = 30
-- How long asking groups may take before building the group instead.
local ASKING_TIME = 60
local INVITE_TIMEOUT = 30
local STALE = 30
local PARTY_SIZE = 5

local state
-- Leaders asked by hand from Who is looking (no Find group running), for
-- REQUEST_KEPT seconds, as for dungeons.
local requested = {}
local REQUEST_KEPT = 300

local function now()
    return GetTime()
end

local function members()
    return IsInGroup() and math.max(1, GetNumGroupMembers() or 1) or 1
end

local function canInvite()
    return not IsInGroup() or UnitIsGroupLeader("player")
end

local function battlegroundName()
    return Battlegrounds.name(state.battleground)
end

local function englishName()
    return Battlegrounds.englishName(state.battleground)
end

local function whisper(name, text)
    return ns.Whispers.sendIfAllowed(name, text)
end

local function sameBracket(listing)
    return Battlegrounds.sameBracket(listing.level, UnitLevel("player"))
end

local function forState(listing)
    for _, id in ipairs(listing.battlegrounds or {}) do
        if id == state.battleground then
            return sameBracket(listing)
        end
    end
    return false
end

local function asking()
    local count = 0
    for leader, at in pairs(state.asked) do
        local promised = state.promisedAt[leader] and now() - state.promisedAt[leader] < PROMISE_WAIT
        if not state.over[leader] and (now() - at < ASK_WAIT or promised) then
            count = count + 1
        end
    end
    return count
end

local function pendingCount()
    local count = 0
    for _ in pairs(state.pending) do
        count = count + 1
    end
    return count
end

local function finish(text)
    if text then
        Log.info(text)
    end
    state = nil
    ns.Window.refresh()
    ns.Status.refresh()
end

local function startBuilding()
    if state.phase ~= "build" then
        state.phase = "build"
        Log.detail("No battleground group took you; building your own %s group.", battlegroundName())
    end
end

local function ask(listing)
    state.asked[listing.leader] = now()
    state.askedIds[listing.leader] = listing.id
    if ns.db.dryRun then
        Log.info("Dry run: would ask %s to invite you for %s.", listing.leader, battlegroundName())
        return
    end
    local role = ns.LfgPick.askRole(state.roles)
    local sent = whisper(listing.leader, ns.Messages.text("bgAsk", {
        level = UnitLevel("player"), spec = ns.Spec.myLabel(role), role = ns.Widgets.describeRolesEnglish(role),
        battleground = englishName(),
    }))
    if sent then
        ns.Apply.rememberAsk(listing.leader)
        ns.Whispers.expectReplies(listing.leader, 90)
        Log.detail("Asked %s to invite you for %s.", listing.leader, battlegroundName())
    end
end

-- The next listed group to ask: in the bracket, with room, not asked
-- before (also not in the last 15 minutes), the most recently listed first.
local function nextGroup()
    local best
    for _, listing in ipairs((ns.LfgList.battlegroundListings())) do
        if not listing.solo and (listing.open or 0) > 0 and listing.leader ~= ns.selfName and forState(listing)
            and not state.asked[listing.leader] and not ns.Apply.recentlyAsked(listing.leader)
            and (not best or (listing.age or 0) < (best.age or 0)) then
            best = listing
        end
    end
    return best
end

-- Listed groups that left the Group Finder after an ask are over.
local function settleAsks()
    local listings, updatedAt = ns.LfgList.battlegroundListings()
    for leader, at in pairs(state.asked) do
        if not state.over[leader] and not state.promisedAt[leader] and (updatedAt or 0) > at then
            local listed = ns.LfgList.stillListed(state.askedIds[leader])
            for _, listing in ipairs(listings) do
                listed = listed or (not listing.solo and listing.leader == leader)
            end
            if not listed then
                state.over[leader] = true
                Log.detail("%s's group is no longer listed; asking another.", leader)
            end
        end
    end
end

-- The names in the player's party or raid.
local function groupNames()
    local names = {}
    local prefix, count = "party", 4
    if IsInRaid() then
        prefix, count = "raid", 40
    end
    for i = 1, count do
        local name = ns.Party.unitName(prefix .. i)
        if name then
            names[name] = true
        end
    end
    return names
end

local function heals(listing)
    return string.find(listing.roles or "", "H", 1, true) ~= nil
end

-- Healers the group still lacks: one per five players; the player counts
-- when they ticked Healer, invited healers while in the group or on the way.
local function healersShort()
    local have = string.find(state.roles or "", "H", 1, true) and 1 or 0
    local names = groupNames()
    for name in pairs(state.healerNames) do
        if names[name] or state.pending[name] then
            have = have + 1
        end
    end
    return math.max(0, math.ceil(state.size / PARTY_SIZE) - have)
end

-- Up to count listed players for the open places (need), longest listed
-- first, but the healers the group lacks before anyone else; the places
-- those healers are still lacking for stay open.
local function picks(count, need)
    local candidates = {}
    for _, listing in ipairs((ns.LfgList.battlegroundListings())) do
        if listing.solo and listing.name ~= ns.selfName and forState(listing) and not state.tried[listing.name] then
            candidates[#candidates + 1] = listing
        end
    end
    table.sort(candidates, function(a, b)
        return (a.age or 0) > (b.age or 0)
    end)
    local short = healersShort()
    local result, rest = {}, {}
    for _, listing in ipairs(candidates) do
        if heals(listing) and #result < math.min(count, short) then
            result[#result + 1] = listing
        else
            rest[#rest + 1] = listing
        end
    end
    short = short - #result
    local room = math.min(count, need - short) - #result
    for i = 1, math.min(room, #rest) do
        result[#result + 1] = rest[i]
    end
    return result
end

local function invite(listing)
    state.tried[listing.name] = true
    if ns.db.dryRun then
        Log.info("Dry run: would invite %s for %s.", listing.name, battlegroundName())
        return
    end
    state.pending[listing.name] = now()
    state.listedRoles[listing.name] = listing.roles
    if heals(listing) then
        state.healerNames[listing.name] = true
    end
    whisper(listing.name, ns.Messages.text("bgInvite", { battleground = englishName(), size = state.size }))
    local ok, err = pcall(C_PartyInfo.InviteUnit, listing.name)
    if not ok then
        Log.debug("invite %s failed: %s", listing.name, tostring(err))
    end
    Log.detail("Invited %s from the Group Finder for %s.", listing.name, battlegroundName())
end

-- Invites as many listed players as fit: up to five in a party; past that
-- the party first becomes a raid (WoW takes a moment to make it one).
local function fill()
    if not canInvite() then
        return
    end
    local have, waiting = members(), pendingCount()
    local need = state.size - have - waiting
    if need <= 0 then
        return
    end
    local room = need
    if not IsInRaid() then
        room = math.min(need, PARTY_SIZE - have - waiting)
        if room <= 0 and have >= 2 then
            if not state.convertedAt or now() - state.convertedAt > 5 then
                state.convertedAt = now()
                local ok = pcall(C_PartyInfo.ConvertToRaid)
                Log.detail("Turning the group into a raid for %s: %s", battlegroundName(), ok and "ok" or "failed")
            end
            return
        end
        room = room - math.min(room, ns.BgQueue.soloWaiting())
    end
    for _, listing in ipairs(picks(room, need)) do
        invite(listing)
    end
    ns.BgQueue.sync()
end

local function checkDone()
    if members() >= state.size then
        finish(string.format("Your %s group is complete (%d players). Sign it up at a battlemaster: join as a group.",
            battlegroundName(), members()))
        return true
    end
    return false
end

local function newState(opts)
    return {
        battleground = opts.battleground, size = opts.size, roles = opts.roles, startedAt = now(),
        phase = (IsInGroup() or opts.lead or not ns.Features.apply()) and "build" or "ask",
        asked = {}, askedIds = {}, over = {}, promisedAt = {}, answered = {}, pending = {}, tried = {},
        healerNames = {}, listedRoles = {},
    }
end

-- opts: battleground (id), size (5 or 10), roles ("HD"), lead (true when
-- the player would like to lead). From a click: it also searches.
function BgFinder.start(opts)
    if ns.Party.state() == "member" then
        return false, "your group's leader looks for the group"
    end
    if not ns.Features.groupFinder() then
        return false, "WoW's Group Finder is turned off in the settings (/fg settings)"
    end
    state = newState(opts)
    ns.LfgList.searchBattlegrounds()
    Log.info("Looking for a %s group.", battlegroundName())
    ns.Window.refresh()
    ns.Status.refresh()
    return true
end

function BgFinder.stop()
    if state then
        finish("Stopped looking for a battleground group.")
    end
end

-- Another group formed for the player: no more looking, without a word.
function BgFinder.cancel()
    if state then
        finish(nil)
    end
end

-- The group size chosen on the Battlegrounds tab: 5 or 10 (the default).
function BgFinder.chosenSize()
    local size = ns.charDb.bgSize
    return (size == 5 or size == 10) and size or 10
end

-- Roles by name of the players the Group Finder brought in.
function BgFinder.joinedRoles()
    return state and state.listedRoles or {}
end

-- One role letter for each Group Finder invite still on its way ("HDD").
function BgFinder.pendingRoles()
    local letters = {}
    local joined = groupNames()
    for name in pairs(state and state.pending or {}) do
        local roles = state.listedRoles[name]
        if roles and not joined[name] then
            letters[#letters + 1] = string.sub(roles, 1, 1)
        end
    end
    table.sort(letters)
    return table.concat(letters)
end

-- A group formed in the Forever Groups battleground queue. Its leader goes
-- on filling it from the Group Finder up to the chosen size (for a
-- battleground the Group Finder lists); everyone else stops looking.
function BgFinder.onFormed(view)
    local id = Battlegrounds.parseKey(view.dungeon)
    local battleground = id and Battlegrounds.get(id)
    if not view.isLeader or not battleground then
        BgFinder.cancel()
        return
    end
    if not battleground.lfg or not ns.Features.groupFinder() then
        BgFinder.cancel()
        Log.info("Sign your %s group up at a battlemaster: join as a group.", battleground.name)
        return
    end
    local mine = "D"
    for _, member in ipairs(view.members) do
        if member.name == ns.selfName then
            mine = member.role
        end
    end
    state = state or newState({ battleground = id, size = BgFinder.chosenSize(), roles = mine })
    state.battleground, state.roles, state.phase = id, mine, "build"
    for _, member in ipairs(view.members) do
        if member.name ~= ns.selfName then
            state.pending[member.name] = now()
            state.tried[member.name] = true
            if member.role == "H" then
                state.healerNames[member.name] = true
            end
        end
    end
    ns.Window.refresh()
end

function BgFinder.isActive()
    return state ~= nil
end

-- Building the player's own group from the Group Finder, with players
-- invited for it.
function BgFinder.isRecruiting()
    return state ~= nil and state.phase == "build" and next(state.listedRoles) ~= nil
end

-- For the card: { phase, battleground, size, members, asked, invited,
-- healersShort }.
function BgFinder.summary()
    if not state then
        return nil
    end
    return { phase = state.phase, battleground = state.battleground, size = state.size, members = members(),
        asked = asking(), invited = pendingCount(), healersShort = healersShort() }
end

-- With fresh results: settle the asks, ask the next group or build.
function BgFinder.onResults()
    if not state then
        return
    end
    if state.phase == "ask" then
        settleAsks()
        if asking() == 0 then
            local listing = nextGroup()
            if listing then
                ask(listing)
            elseif now() - state.startedAt >= ASKING_TIME then
                startBuilding()
            end
        end
    end
    if state.phase == "build" and not checkDone() then
        fill()
    end
end

function BgFinder.tick()
    if not state then
        return
    end
    if ns.Party.state() == "member" then
        finish(nil)
        return
    end
    for name, at in pairs(state.pending) do
        if now() - at > INVITE_TIMEOUT then
            state.pending[name] = nil
            Log.detail("%s did not answer the invite; inviting someone else.", name)
        end
    end
    ns.BgQueue.sync()
    if state.phase == "ask" and asking() == 0 and now() - state.startedAt >= ASKING_TIME then
        startBuilding()
    end
    BgFinder.onResults()
end

-- Results older than this are refreshed on the player's next key press.
function BgFinder.searchIfUseful(interval)
    if not state or ns.LfgList.secondsSinceBattlegroundSearch() < math.max(interval, STALE) then
        return false
    end
    return ns.LfgList.searchBattlegrounds()
end

local function onRoster()
    if not state then
        return
    end
    if not IsInGroup() then
        if state.grouped then
            finish(string.format("You left your %s group; stopped looking.", battlegroundName()))
        end
        return
    end
    state.grouped = true
    local names = groupNames()
    local joined = false
    for name in pairs(state.pending) do
        if names[name] then
            state.pending[name] = nil
            joined = true
        end
    end
    if joined then
        ns.Queues.leaveOthers(ns.bgEngine)
    end
    if state.phase == "build" and not checkDone() then
        fill()
    end
end

local function onSystem(text)
    if not state or type(text) ~= "string" then
        return
    end
    local declined = ns.Filler.declinedName(text)
    local name = declined and ns.Whispers.find(state.pending, declined)
    if name then
        state.pending[name] = nil
        Log.detail("%s can't join; inviting someone else.", name)
        ns.BgQueue.sync()
    end
end

-- Asking one leader by hand (Who is looking): a whisper; their invite is
-- joined as for Find group.
function BgFinder.request(listing)
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        Log.info("WoW blocks whispers right now (a boss fight?); try again in a moment.")
        return
    end
    local id = (listing.battlegrounds or {})[1] or "wsg"
    requested[listing.leader] = now()
    local role = ns.LfgPick.askRole(ns.charDb.lastRoles or "D")
    whisper(listing.leader, ns.Messages.text("bgAsk", {
        level = UnitLevel("player"), spec = ns.Spec.myLabel(role), role = ns.Widgets.describeRolesEnglish(role),
        battleground = Battlegrounds.englishName(id),
    }))
    Log.info("Asked %s to invite you for %s.", listing.leader, Battlegrounds.name(id))
end

local function recentRequests()
    for leader, at in pairs(requested) do
        if now() - at > REQUEST_KEPT then
            requested[leader] = nil
        end
    end
    return requested
end

function BgFinder.wasAsked(leader)
    return (state and ns.Whispers.find(state.asked, leader) ~= nil) or ns.Whispers.find(recentRequests(), leader) ~= nil
end

function BgFinder.onWhisper(text, sender)
    sender = state and ns.Whispers.find(state.asked, sender)
    if not sender or state.over[sender] then
        return
    end
    local ok, answer = pcall(ns.Replies.classify, text)
    if not ok then
        return
    end
    Log.detail("%s answered: \"%s\" (%s)", sender, text, answer or "unclear")
    if answer == "no" then
        state.over[sender] = true
        BgFinder.onResults()
        return
    end
    if answer == "yes" then
        state.promisedAt[sender] = now()
    end
    if not state.answered[sender] and ns.Replies.isQuestion(text) then
        state.answered[sender] = true
        ns.Apply.answerQuestion(sender, ns.LfgPick.askRole(state.roles))
    end
end

-- An invite from a leader the player asked, while alone, is joined at once
-- (unless switched off).
function BgFinder.onInvite(inviter)
    local asked = (state and ns.Whispers.find(state.asked, inviter)) or ns.Whispers.find(recentRequests(), inviter)
    if not asked or IsInGroup() or ns.db.noAutoAcceptAsked then
        return
    end
    local roles = (state and state.roles) or ns.charDb.lastRoles or "D"
    if ns.Group.acceptInvite(ns.LfgPick.askRole(roles)) then
        ns.Whispers.stopQuiet(asked)
        requested = {}
        finish(string.format("Joined %s's battleground group.", asked))
    end
end

-- What WoW's battleground queue says about the player: { status, name,
-- wait (seconds, or nil) } for the first battleground signed up for, or nil.
function BgFinder.queueStatus()
    local status = GetBattlefieldStatus
    if type(status) ~= "function" then
        return nil
    end
    local max = type(GetMaxBattlefieldID) == "function" and GetMaxBattlefieldID() or 3
    for i = 1, max do
        local ok, what, name = pcall(status, i)
        if ok and (what == "queued" or what == "confirm" or what == "active") then
            local wait = type(GetBattlefieldEstimatedWaitTime) == "function" and GetBattlefieldEstimatedWaitTime(i)
            return { status = what, name = name, wait = type(wait) == "number" and wait > 0 and wait / 1000 or nil }
        end
    end
    return nil
end

-- The battlegrounds' names in the player's language, from the client.
local function loadNames()
    local info = C_PvP and C_PvP.GetBattlegroundInfo
    if type(info) ~= "function" or string.find(ns.Locale.code(), "^en") then
        return
    end
    for i = 1, 20 do
        local ok, bg = pcall(info, i)
        if not ok or type(bg) ~= "table" then
            break
        end
        for _, battleground in ipairs(Battlegrounds.list) do
            if bg.battlegroundID == battleground.pvp and type(bg.name) == "string" and bg.name ~= "" then
                Battlegrounds.localNames[battleground.id] = bg.name
            end
        end
    end
end

function BgFinder.init()
    ns.on("PLAYER_LOGIN", loadNames)
    ns.LfgList.onUpdate(BgFinder.onResults)
    ns.on("CHAT_MSG_WHISPER", BgFinder.onWhisper)
    ns.on("PARTY_INVITE_REQUEST", BgFinder.onInvite)
    ns.on("GROUP_ROSTER_UPDATE", onRoster)
    ns.on("CHAT_MSG_SYSTEM", onSystem)
    ns.on("UPDATE_BATTLEFIELD_STATUS", function()
        ns.Window.refresh()
    end)
end

ns.BgFinder = BgFinder
