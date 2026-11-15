local _, ns = ...

local Log = ns.Log

-- WoW's Group Finder for the questing queue, next to the Forever Groups
-- players: the "Quests & Zones" category lists players and groups per zone.
-- A listed player in the zone of one of the queued quests is invited with a
-- whisper that says what for; the leader of a listed group there is asked to
-- invite the player; and the group is listed in its zone while it needs
-- players. Someone listed for a zone may be doing any quest there, so the
-- whisper names the quest and offers to share it.
local QuestFinder = {}

local STALE = 20
local INVITE_TIMEOUT = 30
local PARTY_SIZE = 5
-- One leader at a time, the next after this long without an invite.
local MAX_ASKS = 1
local ASK_WAIT = 20
local PROMISE_WAIT = 30

local invited = {}

local function newAsks()
    return ns.Asks.new({ clock = GetTime, find = ns.Whispers.find, wait = ASK_WAIT, promiseWait = PROMISE_WAIT })
end

-- Leaders asked to invite the player, with the one role offered to each.
local asks = newAsks()
-- Everyone invited while this queue entry lasts: a player who let the
-- invite run out is not invited again.
local tried = {}
-- focus: the quest the first invite was for; the entry is narrowed to it.
-- chosen: the quests queued for before that, given back when every invite
-- ran out and nobody joined.
local focus, chosen, focusJoined

local function entry()
    return ns.QuestQueue.entry()
end

local function questFor(key)
    for _, quest in ipairs(ns.Quests.groupQuests()) do
        if quest.key == key then
            return quest
        end
    end
end

local function zonesOf(keys)
    local zones, seen = {}, {}
    for _, key in ipairs(keys) do
        local quest = questFor(key)
        if quest and quest.zone and not seen[quest.zone] and ns.LfgList.zoneActivity(quest.zone) then
            seen[quest.zone] = true
            zones[#zones + 1] = quest.zone
        end
    end
    return zones
end

local function pendingRoles()
    local roles = ""
    for _, invite in pairs(invited) do
        roles = roles .. invite.role
    end
    return roles
end

local function hasZone(listing, zone)
    for _, name in ipairs(listing.zones or {}) do
        if name == zone then
            return true
        end
    end
    return false
end

-- The role a listed player gets: tank or healer while that place is free,
-- else DPS; nil when nothing fits.
local function roleFor(roles, taken)
    for _, role in ipairs({ "T", "H" }) do
        if string.find(roles, role, 1, true) and taken[role] == 0 then
            return role
        end
    end
    if string.find(roles, "D", 1, true) then
        return "D"
    end
end

local function takenRoles(current)
    local taken = { T = 0, H = 0, D = 0 }
    local options = ns.Roles.options(ns.Roles.withReserved(current.members, current.reserved),
        ns.Protocol.QUESTS.slots)
    local best = options[1]
    for _, option in ipairs(options) do
        if option.counts.T + option.counts.H > best.counts.T + best.counts.H then
            best = option
        end
    end
    if best then
        taken = { T = best.counts.T, H = best.counts.H, D = best.counts.D }
    end
    return taken
end

local function inParty(name)
    for _, member in ipairs(ns.Party.members() or {}) do
        if member.name == name then
            return true
        end
    end
    return false
end

-- Narrows the queue entry to the quest the party is now being built for,
-- with the invited roles reserved.
local function updateEntry(key)
    local current = entry()
    if not current then
        return
    end
    ns.questEngine:updateEntry(current.members, pendingRoles(), { key })
end

-- Returns whether the whisper went out.
local function whisper(name, text)
    return ns.Whispers.sendIfAllowed(name, text)
end

local function invite(listing, key, role, quest)
    tried[listing.name] = true
    invited[listing.name] = { role = role, at = GetTime(), key = key }
    if not focus then
        local current = entry()
        chosen = current and { unpack(current.dungeons) } or nil
        focusJoined = false
    end
    focus = key
    local _, size = ns.QuestMatch.parse(key)
    if ns.db.dryRun then
        Log.info("Dry run: would invite %s from the Group Finder for %s.", listing.name, quest.title)
        return
    end
    whisper(listing.name, ns.Messages.text("questInvite", {
        quest = quest.title, zone = quest.zone, size = size, spec = ns.Spec.myLabel(),
    }))
    ns.Invites.send(listing.name, "quests")
    Log.detail("Invited %s from the Group Finder for %s.", listing.name, quest.title)
end

local function askLeader(listing, quest)
    local role = ns.LfgPick.askRole(entry().members[1].roles, listing.remaining)
    if ns.db.dryRun then
        asks:add(listing.leader, listing.id, role)
        Log.info("Dry run: would ask %s, who leads a group in %s, to invite you.", listing.leader, quest.zone)
        return
    end
    local sent = whisper(listing.leader, ns.Messages.text("questAsk", {
        level = UnitLevel("player"), spec = ns.Spec.myLabel(role), role = ns.Widgets.describeRolesEnglish(role),
        quest = quest.title,
    }))
    if not sent then
        return
    end
    asks:add(listing.leader, listing.id, role)
    ns.Apply.rememberAsk(listing.leader)
    ns.Whispers.expectReplies(listing.leader, 90)
    Log.detail("Asked %s, who leads a group in %s, to invite you for %s.", listing.leader, quest.zone, quest.title)
end

local function askCount()
    return asks:waiting()
end

-- Zone results that came in after an ask: a group no longer listed is over.
local function settleAsks(listings, updatedAt)
    local ended = asks:settle(updatedAt, function(leader, id)
        local listed = ns.LfgList.stillListed(id)
        for _, listing in ipairs(listings) do
            listed = listed or (not listing.solo and listing.leader == leader)
        end
        return listed
    end, ns.LfgList.isDelisted)
    for _, leader in ipairs(ended) do
        Log.detail("%s's group is no longer listed; asking another.", leader)
    end
end

-- With fresh zone results: invite listed players for the first queued quest
-- that has some, else ask a listed group in its zone.
function QuestFinder.onResults()
    local current = entry()
    local listings, updatedAt = ns.LfgList.zoneListings()
    if not current or not updatedAt or GetTime() - updatedAt > STALE then
        return
    end
    if ns.questEngine.myProposalKey or ns.questEngine.held or ns.Filler.isActive() then
        return
    end
    settleAsks(listings, updatedAt)
    -- Oldest listing first, on a copy: the list belongs to LfgList.
    local byAge = {}
    for i, listing in ipairs(listings) do
        byAge[i] = listing
    end
    table.sort(byAge, function(a, b)
        return (a.age or 0) > (b.age or 0)
    end)
    listings = byAge
    local keys = focus and { focus } or current.dungeons
    for _, key in ipairs(keys) do
        local quest = questFor(key)
        local _, size = ns.QuestMatch.parse(key)
        local open = quest and size - #current.members - #(current.reserved or "") or 0
        if not IsInRaid() then
            -- Invites we stopped waiting for still hold a place in WoW.
            local free = PARTY_SIZE - (IsInGroup() and math.max(1, GetNumGroupMembers() or 1) or 1)
                - math.max(#(current.reserved or ""), ns.Invites.held())
            open = math.min(open, free)
        end
        if open > 0 then
            local taken = takenRoles(current)
            local picked = 0
            for _, listing in ipairs(ns.Features.fill() and listings or {}) do
                local role = listing.solo and hasZone(listing, quest.zone) and not tried[listing.name]
                    and listing.name ~= ns.selfName and not inParty(listing.name)
                    and ns.Levels.fits(ns.PartyLevels.rules("quests"), listing.level) and roleFor(listing.roles, taken)
                if role and picked < open then
                    taken[role] = taken[role] + 1
                    picked = picked + 1
                    invite(listing, key, role, quest)
                end
            end
            if picked > 0 then
                updateEntry(key)
                return
            end
            if ns.Features.apply() and not ns.charDb.wantsLeadQuests and #current.members == 1 and next(invited) == nil
                and askCount() < MAX_ASKS then
                local groups = {}
                for _, listing in ipairs(listings) do
                    if not listing.solo and hasZone(listing, quest.zone) and not asks:find(listing.leader)
                        and not ns.Apply.recentlyAsked(listing.leader) and (listing.members or 1) < size then
                        groups[#groups + 1] = listing
                    end
                end
                -- Recent listings first, then the fullest, then the newest.
                table.sort(groups, function(a, b)
                    local oldA, oldB = ns.LfgPick.isOld(a), ns.LfgPick.isOld(b)
                    if oldA ~= oldB then
                        return oldB
                    end
                    if (a.members or 1) ~= (b.members or 1) then
                        return (a.members or 1) > (b.members or 1)
                    end
                    return (a.age or 0) < (b.age or 0)
                end)
                if groups[1] then
                    askLeader(groups[1], quest)
                    return
                end
            end
        end
    end
end

-- From a key press (KeySearch) or click: searches the zones of the queued
-- quests when their results are older than the dungeon results.
function QuestFinder.searchIfUseful(interval)
    if not ns.Features.fill() and not ns.Features.apply() then
        return false
    end
    local current = entry()
    if not current or ns.LfgList.secondsSinceZoneSearch() < math.max(interval, STALE) then
        return false
    end
    local dungeonAge = ns.LfgList.secondsSinceSearch()
    if ns.Filler.isActive() and ns.LfgList.secondsSinceZoneSearch() < dungeonAge then
        return false
    end
    return ns.LfgList.searchZones(zonesOf(focus and { focus } or current.dungeons))
end

function QuestFinder.searchNow()
    local current = entry()
    if current and (ns.Features.fill() or ns.Features.apply()) then
        ns.LfgList.searchZones(zonesOf(current.dungeons))
    end
end

-- The roles a player who whispers about our listing can still get, as
-- letters ("HD": the healer place and DPS places are free), or "".
function QuestFinder.openRoles()
    local current = entry()
    local key = current and (focus or current.dungeons[1])
    local _, size = ns.QuestMatch.parse(key or "")
    if not size then
        return ""
    end
    if size - #current.members - #(current.reserved or "") <= 0 then
        return ""
    end
    local taken = takenRoles(current)
    return (taken.T == 0 and "T" or "") .. (taken.H == 0 and "H" or "") .. "D"
end

-- Invites a player who whispered about our listing, like a listed player.
function QuestFinder.inviteWhisperer(name, role)
    local current = entry()
    local key = current and (focus or current.dungeons[1])
    local quest = key and questFor(key)
    if not quest or invited[name] or inParty(name) then
        return false
    end
    invite({ name = name }, key, role, quest)
    updateEntry(key)
    return true
end

-- { activity, name } for the group's own Group Finder listing, or nil.
function QuestFinder.listing()
    local current = entry()
    if not current then
        return nil
    end
    local quest = questFor(focus or current.dungeons[1])
    local activity = quest and ns.LfgList.zoneActivity(quest.zone)
    if not activity then
        return nil
    end
    return { activity = activity, name = quest.title .. " (" .. quest.zone .. ")" }
end

-- Invited players who are in the party now: { [name] = role }. They stop
-- being pending, so the queue entry can take them as members.
function QuestFinder.takeJoined()
    local joined = {}
    for name, pending in pairs(invited) do
        if inParty(name) then
            joined[name] = pending.role
            invited[name] = nil
            focusJoined = true
        end
    end
    return joined
end

function QuestFinder.isInvited(name)
    return invited[name] ~= nil
end

function QuestFinder.pendingRoles()
    return pendingRoles()
end

function QuestFinder.focus()
    return focus
end

-- A click on "Request to join" on a listed questing group in Who is looking:
-- asks its leader to invite the player, naming a wanted quest in its zone.
function QuestFinder.request(listing, roles, wanted)
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        Log.info("WoW blocks whispers right now (a boss fight?); try again in a moment.")
        return
    end
    local keys = {}
    for key in pairs(wanted or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    local subject
    for _, key in ipairs(keys) do
        local quest = questFor(key)
        if quest and hasZone(listing, quest.zone) then
            subject = quest.title
            break
        end
    end
    subject = subject or (listing.zones and listing.zones[1]) or "your group"
    local role = ns.LfgPick.askRole(roles or "D", listing.remaining)
    if ns.db.dryRun then
        asks:add(listing.leader, listing.id, role)
        Log.info("Dry run: would ask %s to invite you for %s.", listing.leader, subject)
        return
    end
    local sent = whisper(listing.leader, ns.Messages.text("questAsk", {
        level = UnitLevel("player"), spec = ns.Spec.myLabel(role), role = ns.Widgets.describeRolesEnglish(role),
        quest = subject,
    }))
    if not sent then
        Log.debug("asking %s failed: the whisper did not go out", listing.leader)
        return
    end
    asks:add(listing.leader, listing.id, role)
    Log.info("Asked %s to invite you for %s.", listing.leader, subject)
end

function QuestFinder.wasAsked(leader)
    return asks:find(leader) ~= nil
end

-- A whisper from a leader we asked: a clear no moves on to the next group,
-- a clear yes holds off asking others while the invite comes.
function QuestFinder.onWhisper(text, sender)
    local ask
    ask, sender = asks:get(sender)
    if not ask or ask.over then
        return
    end
    local ok, answer = pcall(ns.Replies.classify, text)
    if not ok then
        return
    end
    Log.detail("%s answered: \"%s\" (%s)", sender, text, answer or "unclear")
    asks:answer(sender, answer)
    if answer == "no" then
        Log.detail("%s can't take you; asking another group.", sender)
        QuestFinder.onResults()
        return
    end
    if ns.Replies.isQuestion(text) and asks:firstQuestion(sender) then
        ns.Apply.answerQuestion(sender, ask.role)
    end
end

function QuestFinder.reset()
    invited, tried, focus, chosen, focusJoined = {}, {}, nil, nil, nil
    asks = newAsks()
end

-- For the status: { invited = n, asked = n }.
function QuestFinder.summary()
    local count = 0
    for _ in pairs(invited) do
        count = count + 1
    end
    return { invited = count, asked = askCount() }
end

function QuestFinder.tick()
    if not entry() then
        if next(invited) or asks:any() or next(tried) or focus then
            QuestFinder.reset()
        end
        return
    end
    local expired = false
    for name, pending in pairs(invited) do
        if GetTime() - pending.at > INVITE_TIMEOUT and not inParty(name) then
            invited[name] = nil
            expired = true
        end
    end
    if not expired or not focus then
        return
    end
    local current = entry()
    if next(invited) == nil and not focusJoined and chosen and current then
        focus = nil
        ns.questEngine:updateEntry(current.members, pendingRoles(), chosen)
        chosen = nil
    else
        updateEntry(focus)
    end
end

-- An invite from a leader we asked while still looking alone is joined at
-- once, unless switched off.
function QuestFinder.onInvite(inviter, tank, healer, dps)
    local current = entry()
    local ask
    ask, inviter = asks:get(inviter)
    if not ask or not current or #current.members ~= 1 or ns.db.noAutoAcceptAsked or ns.Group.justAccepted()
        or next(invited) ~= nil or (current.reserved or "") ~= "" then
        return
    end
    local remaining
    for _, listing in ipairs((ns.LfgList.zoneListings())) do
        if not listing.solo and listing.leader == inviter then
            remaining = listing.remaining
        end
    end
    local invitedRoles = ns.LfgPick.inviteRoles(tank == true, healer == true, dps == true)
    local role = ask.role
    if not role or (invitedRoles and invitedRoles[role] == 0) then
        role = ns.LfgPick.joinRole(current.members[1].roles, remaining or invitedRoles)
    end
    if ns.Group.acceptInvite(role) then
        ns.Whispers.stopQuiet(inviter)
        Log.info("Questing group found: you're the %s.", ns.Widgets.roleName(role) or "?")
        Log.detail("Joined %s's group.", inviter)
    end
end

-- WoW turned the invite down, the party being full: that player was not
-- invited after all and may be picked again.
local function onRefused(name)
    if invited[name] then
        invited[name] = nil
        tried[name] = nil
        if focus then
            updateEntry(focus)
        end
    end
end

function QuestFinder.init()
    ns.Invites.onRefused("quests", onRefused)
    ns.LfgList.onUpdate(QuestFinder.onResults)
    ns.on("CHAT_MSG_WHISPER", QuestFinder.onWhisper)
    ns.on("PARTY_INVITE_REQUEST", QuestFinder.onInvite)
end

ns.QuestFinder = QuestFinder
