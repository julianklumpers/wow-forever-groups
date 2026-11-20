local _, ns = ...

local Fill = ns.Fill
local Roles = ns.Roles
local Dungeons = ns.Dungeons
local Party = ns.Party
local LfgList = ns.LfgList
local Widgets = ns.Widgets
local Log = ns.Log

-- Fills a group's open roles from WoW's Group Finder: whispers and invites
-- the best listed players, replaces anyone who declines or does not join in
-- time, and asks for a click when the results are used up or too old.
local Filler = {}

-- Every open invite takes a place in the party: WoW keeps an invite open for
-- INVITE_LIFETIME s, and nobody else can have that place meanwhile. So the
-- place stays the invited player's until they accept or decline. WoW reports
-- an invite left unanswered as declined when it expires, at INVITE_LIFETIME s
-- (/fgp invitewatch, 2026-11-18): such a "decline" counts as no answer.
-- INVITE_TIMEOUT only catches that message missed (a /reload in between).
-- Inviting into a full party gets "Your party is full": a place is held by
-- something not counted (an invite sent elsewhere). Nobody is invited until a
-- place frees, which WoW always tells: a decline (also an expired invite,
-- within INVITE_LIFETIME s) or the group's size changing. The invite follows
-- the whisper after AWAY_CHECK s, so an away player's automatic reply (AFK,
-- DND) comes first and they are passed over.
local INVITE_LIFETIME = 60
local INVITE_TIMEOUT = INVITE_LIFETIME + 2
local AWAY_CHECK = 1.5
local PARTY_SIZE = 5
-- Results stay usable this long: delisted players drop out of them as WoW
-- reports it, only new listings need a search (which needs player input).
local STALE_RESULTS = 300
local DECLINE_MESSAGES = { "ERR_DECLINE_GROUP_S", "ERR_ALREADY_IN_GROUP_S", "ERR_BAD_PLAYER_NAME_S" }
-- What each of those messages means for the player invited.
local DECLINE_KINDS = { ERR_DECLINE_GROUP_S = "declined", ERR_ALREADY_IN_GROUP_S = "grouped",
    ERR_BAD_PLAYER_NAME_S = "missing" }
-- A player who did not answer (or was away) is tried once more when still
-- listed this long after.
local REOPEN_WAIT = 300

local state
local changeListeners = {}

local function changed()
    for _, listener in ipairs(changeListeners) do
        listener()
    end
end

local function removeLetter(letters, role)
    local i = string.find(letters, role, 1, true)
    if not i then
        return letters
    end
    return string.sub(letters, 1, i - 1) .. string.sub(letters, i + 1)
end

local function describeLetters(letters)
    local names = {}
    for letter in string.gmatch(letters, ".") do
        names[#names + 1] = Widgets.ROLE_NAMES[letter]
    end
    return table.concat(names, ", ")
end

local function rangeOf(id)
    local dungeon = Dungeons.get(id)
    return dungeon and dungeon.min and { min = dungeon.min, max = dungeon.max } or nil
end

-- Zones between a listed player and the dungeon (wow/zonemap.lua): the
-- closest go first, and one further away waits Zones.STEP_WAIT s a step from
-- when they showed up (or the search started) for someone closer. Nothing
-- changes for a player whose zone is not told, or a dungeon not on the map.
function Filler.zoneSteps(listing, dungeon)
    local steps, most = ns.ZoneMap.areaDistance(dungeon, listing.area)
    if most == nil then
        return nil
    end
    return ns.Zones.rank(steps, most)
end

function Filler.zoneHeld(listing, dungeon)
    local steps, most = ns.ZoneMap.areaDistance(dungeon, listing.area)
    if most == nil or not state then
        return false
    end
    local now = GetServerTime()
    local shownAt = now - (listing.age or 0) - (GetTime() - (listing.seenAt or GetTime()))
    return ns.Zones.waitLeft(steps, most, shownAt, state.startedAt, now) > 0
end

-- Zones between the dungeon and the furthest of the player and their party
-- members, or nil when nobody's zone is known.
function Filler.groupSteps(dungeon)
    local worst
    local function add(zone)
        local steps, most = ns.ZoneMap.distance(dungeon, zone)
        if zone and most ~= nil then
            worst = math.max(worst or 0, ns.Zones.rank(steps, most))
        end
    end
    add(ns.ZoneMap.myZone())
    for _, member in ipairs(Party.members() or {}) do
        add(member.unit and ns.ZoneMap.unitZone(member.unit))
    end
    return worst
end

-- For the log: how a dungeon was chosen (Fill.score), e.g. "4 of 4 places
-- filled now, the furthest player 1 zone away, levels 2.5 from its middle".
function Filler.describeScore(score)
    local parts = { score.places == 0 and "no places left to fill"
        or string.format("%d of %d places filled now", score.places - score.open, score.places) }
    if score.steps ~= math.huge then
        parts[#parts + 1] = string.format("the furthest player %d zone%s away", score.steps,
            score.steps == 1 and "" or "s")
    end
    parts[#parts + 1] = string.format("levels %.1f from its middle", score.apart)
    return table.concat(parts, ", ")
end

-- Settles the dungeon of a fill for several (Fill.plan's choice), as its
-- first invite goes out.
function Filler.choose(plan)
    state.dungeon = plan.dungeon
    ns.GroupView.track(plan.dungeon)
    Log.detail("Chose %s: %s.", Dungeons.name(plan.dungeon), Filler.describeScore(plan.score))
end

-- The levels of the player and their party members.
function Filler.groupLevels()
    local levels = {}
    local own = Party.playerLevel()
    if type(own) == "number" and own > 0 then
        levels[1] = own
    end
    for _, member in ipairs(Party.members() or {}) do
        if type(member.level) == "number" and member.level > 0 then
            levels[#levels + 1] = member.level
        end
    end
    return levels
end

-- For the log: why each open role still has nobody although players are
-- listed for it ("Tank: 3 listed (2 outside the dungeon's levels, 1 of another
-- playstyle)"); empty when nobody is listed at all.
local function whyNobody(open, all, listings)
    local dungeons = state.dungeon and { state.dungeon } or state.dungeons
    if open == "" or not dungeons or #dungeons == 0 then
        return ""
    end
    local ranges = {}
    for _, id in ipairs(dungeons) do
        ranges[id] = rangeOf(id)
    end
    local opts = { dungeons = dungeons, ranges = ranges, exclude = state.exclude, places = Filler.freePlaces(),
        levels = ns.PartyLevels.rules("dungeons"), avoid = Filler.avoidClasses(), held = Filler.zoneHeld }
    local lines, seen = {}, {}
    for letter in string.gmatch(open, ".") do
        if not seen[letter] then
            seen[letter] = true
            local why = Fill.skipped(listings, opts, letter)
            local style = Fill.skipped(all, { dungeons = dungeons }, letter).listed - why.listed
            local total = why.listed + style
            if total > 0 then
                local reasons = {}
                local function add(count, text)
                    if count > 0 then
                        reasons[#reasons + 1] = count .. " " .. text
                    end
                end
                add(why.excluded, "already invited, asked or declined")
                add(why.level, "outside the dungeon's levels")
                add(why.limit, "outside your level limit")
                add(why.class, "of a class your class choices leave out")
                add(why.variety, string.format("of a class your group has in that role or twice, for %d s more",
                    Filler.varietyLeft()))
                add(why.held, "further from the dungeon, waiting a little for someone closer")
                add(style, "of another playstyle")
                add(why.listed - why.excluded - why.level - why.limit - why.class - why.variety - why.held,
                    "picked for another role")
                lines[#lines + 1] = string.format("%s: %d listed (%s)", Widgets.ROLE_NAMES[letter], total,
                    table.concat(reasons, ", "))
            end
        end
    end
    return #lines > 0 and (" " .. table.concat(lines, "; ") .. ".") or ""
end

local function stillNeeded()
    local needed = state.open
    for _, pending in pairs(state.pending) do
        needed = removeLetter(needed, pending.role)
    end
    return needed
end

-- What the filler waits for, in the saved log (and chat with /fg debug on)
-- when it changes.
local function setMessage(text)
    if text and text ~= state.message then
        Log.detail(text)
    end
    state.message = text
end

local function whisper(name, text)
    return ns.Whispers.sendIfAllowed(name, text)
end

local function sendInvite(name)
    local pending = state and state.pending[name]
    if not pending or pending.sentAt then
        return
    end
    pending.sentAt = GetTime()
    ns.Invites.send(name, "filler")
    Log.detail("Invited %s from the Group Finder as %s.", name, Widgets.ROLE_NAMES[pending.role])
end

-- Places left in the party for new invites: the members, the invites
-- about to go out and those still open in WoW (any part's) take theirs; none
-- after WoW said it is full, until a place frees (placeFreed).
local function freePlaces()
    if state.fullAt then
        return 0
    end
    local taken = IsInGroup() and math.max(1, GetNumGroupMembers() or 1) or 1
    for _, pending in pairs(state.pending) do
        if not pending.sentAt then
            taken = taken + 1
        end
    end
    return PARTY_SIZE - taken - ns.Invites.held()
end

-- What became of a player invited this fill: { kind, at, again } with kind
-- "invited", "declined", "grouped" (already in a group), "missing" (WoW knows
-- no such player), "noanswer" or "away"; again: let back in once already.
local function setOutcome(name, kind)
    local old = state.outcomes[name]
    state.outcomes[name] = { kind = kind, at = GetTime(), again = old and old.again }
end

-- Players passed over after an invite who are looking again: one who was in a
-- group or not found once they list again (a listing newer than the invite),
-- one who declined once more after listing again, one who did not answer once
-- more when still listed REOPEN_WAIT later.
local function reopen(listings)
    local listedAt = {}
    for _, listing in ipairs(listings) do
        listedAt[listing.name] = (listing.seenAt or GetTime()) - (listing.age or 0)
    end
    local now = GetTime()
    for name, out in pairs(state.outcomes) do
        local since = listedAt[name]
        if since and state.exclude[name] and not state.pending[name] then
            local relisted = since > out.at + 1
            local kind = out.kind
            local back = ((kind == "grouped" or kind == "missing") and relisted)
                or (kind == "declined" and relisted and not out.again)
                or ((kind == "noanswer" or kind == "away") and now - out.at >= REOPEN_WAIT and not out.again)
            if back then
                state.exclude[name], state.late[name] = nil, nil
                state.outcomes[name] = { kind = "back", at = now, again = true }
                Log.detail("%s is looking again; they may be invited again.", name)
            end
        end
    end
end

local function invite(pick)
    state.exclude[pick.name] = true
    setOutcome(pick.name, "invited")
    local role = Widgets.ROLE_NAMES[pick.role]
    state.pending[pick.name] = { role = pick.role, at = GetTime(), class = pick.class }
    state.invited[pick.name] = pick.role
    ns.RoleSync.expect(pick.name, pick.role)
    local whispered = whisper(pick.name, ns.Messages.inviteText(state.dungeon, string.lower(role), "fillInvite", {
        dungeon = Dungeons.englishName(state.dungeon), role = string.lower(role),
        spec = ns.Spec.myLabel(ns.RoleSync.expected(ns.selfName)),
    }))
    if not whispered then
        sendInvite(pick.name)
        return
    end
    C_Timer.After(AWAY_CHECK, function()
        sendInvite(pick.name)
    end)
end

local function finish(text)
    if text then
        Log.detail(text)
    end
    state = nil
    changed()
end

-- A group proposal in any queue (or the dungeon queue held for one in
-- another queue): no inviting until it is answered.
local function queueProposalOpen()
    return ns.Queues.anyProposalOpen() or (ns.engine ~= nil and ns.engine.held == true)
end

local function wantsDungeon(entry, dungeons)
    for _, id in ipairs(entry.dungeons or {}) do
        for _, wanted in ipairs(dungeons) do
            if id == wanted then
                return true
            end
        end
    end
    return false
end

-- The roles of `needed` that solo Forever Groups players waiting in the
-- queue for this dungeon can play: those are left to the matchmaker for one
-- round (Config.MATCH_ROUND), and while its proposal is open until it is
-- accepted, declined or let lapse. Only while our own group is in the queue
-- (else the matchmaker cannot pair us), and only players who are not
-- building a group of their own.
local function addonRoles(needed)
    local engine = ns.engine
    if not engine or not engine.myEntry or needed == "" then
        return ""
    end
    local dungeons = state.dungeon and { state.dungeon } or state.dungeons or {}
    local style = ns.Playstyle.forGroup()
    local now, left, covered = engine:now(), needed, ""
    for _, other in ipairs(engine.queue:list()) do
        local recent = now - (other.lastSeen or now) <= engine.config.HEARTBEAT_INTERVAL + 15
        if other.id ~= engine.name and recent and not engine.fakes[other.id] and not engine:isReserved(other.id)
            and #other.members == 1 and (other.reserved or "") == "" and not state.exclude[other.id]
            and wantsDungeon(other, dungeons)
            and ns.Playstyles.compatible(style, other.playstyle) and engine:sharesLanguage(other) then
            for _, role in ipairs({ "T", "H", "D" }) do
                if string.find(other.members[1].roles, role, 1, true) and string.find(left, role, 1, true) then
                    left = removeLetter(left, role)
                    covered = covered .. role
                    break
                end
            end
        end
    end
    return covered
end

function Filler.step()
    if not state then
        return
    end
    local partyState = Party.state()
    if partyState == "member" or partyState == "raid" then
        finish("You joined another group, so Forever Groups stopped inviting players.")
        return
    end
    if state.open == "" and next(state.pending) == nil then
        finish("Group complete!")
        return
    end
    local needed = stillNeeded()
    if needed == "" then
        return
    end
    local forAddon = addonRoles(needed)
    local leaving
    if forAddon == "" then
        state.addonSince = nil
    else
        state.addonSince = state.addonSince or GetTime()
        if GetTime() - state.addonSince < ns.Config.MATCH_ROUND then
            for letter in string.gmatch(forAddon, ".") do
                needed = removeLetter(needed, letter)
            end
            leaving = "Leaving " .. describeLetters(forAddon) .. " to Forever Groups players in the queue."
            setMessage(leaving)
            if needed == "" then
                return
            end
        end
    end
    if queueProposalOpen() then
        setMessage("Waiting for the queue's group proposal before inviting more.")
        return
    end
    if ns.QuestFinder.summary().invited > 0 then
        setMessage("Waiting for the players invited for your questing group.")
        return
    end
    local all, updatedAt = LfgList.listings()
    local listings = ns.Playstyle.filter(all, ns.Playstyle.forGroup())
    if not updatedAt or GetTime() - updatedAt > STALE_RESULTS then
        setMessage(ns.KeySearch.isReady() and "Refreshing the Group Finder while you play..."
            or "Group Finder results are too old. Click the Forever Groups bar to search again.")
        state.needSearch = true
        return
    end
    reopen(listings)
    local picks, open
    local places, avoid, prefer = Filler.freePlaces(), Filler.avoidClasses(), Filler.preferClasses()
    local spread = Filler.spreadClasses()
    local near = Filler.groupLevel()
    if state.dungeon then
        picks, open = Fill.pick(listings, {
            missing = needed, dungeon = state.dungeon, exclude = state.exclude, range = rangeOf(state.dungeon),
            places = places, levels = ns.PartyLevels.rules("dungeons"), avoid = avoid, prefer = prefer, spread = spread,
            near = near, steps = Filler.zoneSteps, held = Filler.zoneHeld,
        })
    else
        local ranges = {}
        for _, id in ipairs(state.dungeons) do
            ranges[id] = rangeOf(id)
        end
        local plan = Fill.plan(listings, {
            missing = needed, dungeons = state.dungeons, exclude = state.exclude, ranges = ranges, places = places,
            levels = ns.PartyLevels.rules("dungeons"), avoid = avoid, prefer = prefer, spread = spread, near = near,
            steps = Filler.zoneSteps, held = Filler.zoneHeld, groupSteps = Filler.groupSteps,
            groupLevels = Filler.groupLevels(),
        })
        picks, open = plan.picks, plan.open
        if #picks > 0 then
            Filler.choose(plan)
        end
    end
    if (prefer or spread) and #picks > 0 and state.dungeon then
        local chosen = {}
        for _, pick in ipairs(picks) do
            chosen[pick.name] = true
        end
        local plain = Fill.pick(listings, { missing = needed, dungeon = state.dungeon, exclude = state.exclude,
            range = rangeOf(state.dungeon), places = places, levels = ns.PartyLevels.rules("dungeons"), near = near,
            steps = Filler.zoneSteps, held = Filler.zoneHeld })
        for _, pick in ipairs(plain) do
            if not chosen[pick.name] then
                Log.detail("Passed over %s (%s) for a %s place: another class was listed.", pick.name,
                    pick.class and ns.Spec.className(pick.class) or "?", Widgets.ROLE_NAMES[pick.role])
            end
        end
    end
    local room = freePlaces()
    if #picks > 0 and room <= 0 then
        state.waitingForPlace = true
        setMessage("Waiting for a place: earlier invites are still open in WoW.")
        return
    end
    state.waitingForPlace = #picks > room or nil
    for i, pick in ipairs(picks) do
        if i <= room then
            invite(pick)
        end
    end
    if #picks > 0 then
        changed()
    end
    setMessage(open ~= "" and ("Nobody listed for: " .. describeLetters(open) .. ". Searching again soon."
        .. whyNobody(open, all or {}, listings)) or leaving)
    state.needSearch = open ~= ""
    if state.open == "" and next(state.pending) == nil then
        Filler.step()
        return
    end
end

-- opts: missing ("HD"), dungeon (fixed) or dungeons (to choose from),
-- members (names already in or joining the group), replacement (a run's
-- open place: no class variety).
function Filler.start(opts)
    local exclude = { [ns.selfName] = true }
    for _, name in ipairs(opts.members or {}) do
        exclude[name] = true
    end
    local dungeons = opts.dungeons or { opts.dungeon }
    local dungeon = opts.dungeon or (#dungeons == 1 and dungeons[1] or nil)
    state = {
        open = opts.missing, dungeon = dungeon, dungeons = dungeons,
        pending = {}, late = {}, exclude = exclude, invited = {}, outcomes = {},
        startedAt = GetServerTime(), variety = not opts.replacement or nil,
    }
    if dungeon then
        ns.GroupView.track(dungeon)
    end
    Log.detail("Looking in the Group Finder for: %s.", describeLetters(opts.missing))
    Filler.step()
end

-- Only from a click or typed command (the Group Finder search is protected).
function Filler.searchAgain()
    local ok, why = LfgList.search()
    if why == "wait" then
        Log.detail("The Group Finder is searched again in a moment.")
    elseif not ok then
        Log.warn("WoW did not allow the Group Finder search.")
    end
end

function Filler.stop(quiet)
    if state then
        finish(not quiet and "Stopped filling from the Group Finder." or nil)
    end
end

function Filler.isActive()
    return state ~= nil
end

-- Party places free for one more invite right now; 0 when not filling.
function Filler.room()
    return state and freePlaces() or 0
end

-- The invites for the group's open places in the window: { name, role, held, left }
-- per player invited (left: seconds until the filler moves on), and per
-- player given up on whose invite WoW still holds open (held = true, left:
-- seconds until that place is free), oldest first.
function Filler.invites()
    local list = {}
    if not state then
        return list
    end
    local now = GetTime()
    for name, pending in pairs(state.pending) do
        list[#list + 1] = { name = name, role = pending.role, at = pending.at,
            left = math.max(0, INVITE_TIMEOUT - (now - (pending.sentAt or pending.at))) }
    end
    for name, late in pairs(state.late) do
        local left = ns.Invites.HOLD - (now - late.at)
        if left > 0 then
            list[#list + 1] = { name = name, role = late.role, at = late.at, held = true, left = left }
        end
    end
    table.sort(list, function(a, b)
        return a.at < b.at
    end)
    return list
end

function Filler.stillNeeded()
    return state and stillNeeded() or ""
end

-- The roles held by invites still waiting for an answer ("HD").
function Filler.pendingRoles()
    local roles = ""
    for _, pending in pairs(state and state.pending or {}) do
        roles = roles .. pending.role
    end
    return roles
end

function Filler.excluded()
    return state and state.exclude or {}
end

-- Whether Who is looking leaves a listed player out: one who is not
-- available after all (already in a group, or no such player), as long as
-- the listing shown is from a search before that. A search after it that
-- still lists them brings them back (WoW drops a player who joins a group
-- from its Group Finder), and nothing once the fill is over (no state); time
-- alone does not, as the list only ever shows what a search said. One who
-- declined or did not answer stays: they may have meant yes, and the player
-- can invite them.
function Filler.hidden(listing)
    local out = state and listing and state.outcomes[listing.name]
    if not out or (out.kind ~= "grouped" and out.kind ~= "missing") or not state.exclude[listing.name] then
        return false
    end
    return (listing.seenAt or GetTime()) <= out.at
end

-- An invite sent another way (an applicant to our listing) counts like one of
-- ours: its role is reserved, and joining or not is followed the same way.
-- Varied classes for this group: off with db.noClassVariety, and the
-- leader's class wishes decide instead. A replacement never waits for
-- another class (Fill.avoided), it only takes one first (preferClasses).
local function variedClasses()
    return state ~= nil and not ns.db.noClassVariety and Filler.freePlaces() == nil
end

local function wantsVariety()
    return variedClasses() and state.variety == true
end

-- Seconds left of Config.VARIETY_TIME from the start, in which a class the
-- group has enough of waits; 0 when that is over or there is no variety.
function Filler.varietyLeft()
    if not wantsVariety() then
        return 0
    end
    return math.max(0, ns.Config.VARIETY_TIME - (GetServerTime() - (state.startedAt or 0)))
end

-- The classes in the group and on their way to it with their roles: the
-- party, the players a formed queue group brought and the invites out,
-- { [class] = { count, roles } } (Fill.avoided).
local function classesInGroup()
    local classes = {}
    for _, member in ipairs(ns.GroupView.members()) do
        if member.classToken and not state.pending[member.name] then
            Fill.addClass(classes, member.classToken, member.role)
        end
    end
    for _, player in ipairs(ns.Group.expectedPlayers()) do
        if player.class and not state.pending[player.name] then
            Fill.addClass(classes, player.class, player.role)
        end
    end
    for _, pending in pairs(state.pending) do
        if pending.class then
            Fill.addClass(classes, pending.class, pending.role)
        end
    end
    return classes
end

-- The average level of the player and the party: of the players who fit, the
-- closest to it go first (Fill.pick's near).
function Filler.groupLevel()
    local sum, count = 0, 0
    local own = Party.playerLevel()
    if type(own) == "number" and own > 0 then
        sum, count = own, 1
    end
    for _, member in ipairs(Party.members() or {}) do
        if type(member.level) == "number" and member.level > 0 then
            sum, count = sum + member.level, count + 1
        end
    end
    return count > 0 and sum / count or nil
end

-- The group's classes while one it has enough of waits (Filler.varietyLeft);
-- nil otherwise.
function Filler.avoidClasses()
    return Filler.varietyLeft() > 0 and classesInGroup() or nil
end

-- The group's classes once nobody waits for another class any more: another
-- class that is listed still goes first (Fill.pick's prefer); nil otherwise.
function Filler.preferClasses()
    return variedClasses() and Filler.varietyLeft() <= 0 and classesInGroup() or nil
end

-- Under the leader's class wishes, the group's classes: of the players as
-- close to the dungeon, another class goes first (Fill.pick's spread), but
-- nobody waits for one; nil without wishes or with varied classes off.
function Filler.spreadClasses()
    return state ~= nil and not ns.db.noClassVariety and Filler.freePlaces() ~= nil and classesInGroup() or nil
end

-- The class wishes' free places, with the invites on their way counted
-- (wow/partycompose.lua); nil without wishes.
function Filler.freePlaces()
    return ns.PartyCompose.freePlaces()
end

function Filler.trackInvite(name, role, class)
    if not state or queueProposalOpen() then
        return false
    end
    state.exclude[name] = true
    -- The caller sends the invite right away.
    state.pending[name] = { role = role, at = GetTime(), sentAt = GetTime(), class = class }
    state.invited[name] = role
    ns.RoleSync.expect(name, role)
    changed()
    return true
end

-- An invite trackInvite counted that did not go out after all.
function Filler.untrackInvite(name)
    if not state or not state.pending[name] then
        return
    end
    state.pending[name] = nil
    state.exclude[name] = nil
    state.invited[name] = nil
    ns.RoleSync.forget(name)
    changed()
end

-- Whether a fresh Group Finder search would help: roles are still open and
-- the results are used up or older than `age` seconds.
function Filler.wantsSearch(age)
    if not state or stillNeeded() == "" or LfgList.secondsSinceSearch() < 10 then
        return false
    end
    local _, updatedAt = LfgList.listings()
    return state.needSearch or not updatedAt or GetTime() - updatedAt > (age or STALE_RESULTS)
end

-- Searches if that would help; only from a click or key press.
function Filler.searchIfUseful(age)
    if Filler.wantsSearch(age) then
        -- A search held back for the server's limit goes out on a later
        -- input; until then it is still needed.
        local ok, why = LfgList.search()
        if ok then
            state.needSearch = false
        end
        return ok or why == "wait"
    end
    return false
end

-- A party member switched roles: the roles still open follow the party as it
-- is now (invites that are still out keep their role).
function Filler.recompute()
    local party = Party.members()
    if not state or party == nil then
        return
    end
    local me = ns.RoleSync.expected(ns.selfName) or (ns.engine and ns.engine.myEntry
        and ns.engine.myEntry.members[1].roles) or ns.charDb.lastRoles or "D"
    local members, counted = { { name = ns.selfName, roles = me } }, { [ns.selfName] = true }
    local inParty = {}
    for _, member in ipairs(party) do
        inParty[member.name] = true
    end
    for name, role in pairs(ns.RoleSync.all()) do
        local present = inParty[name] or ns.Group.isExpected(name)
        if present and not counted[name] and not state.pending[name] then
            counted[name] = true
            members[#members + 1] = { name = name, roles = role }
        end
    end
    for _, member in ipairs(party) do
        if not counted[member.name] and not state.pending[member.name] then
            counted[member.name] = true
            members[#members + 1] = { name = member.name, roles = ns.PartyRoles.rolesOf(member) }
        end
    end
    local missing = Filler.missingFor(members)
    if missing and missing ~= state.open then
        Log.detail("Roles changed; now looking for: %s.", missing ~= "" and describeLetters(missing) or "nobody")
        state.open = missing
        changed()
        Filler.step()
    end
end

-- One line for the status bar: who is invited, or what is still sought.
function Filler.summary()
    if not state then
        return nil
    end
    local invited = {}
    for name, pending in pairs(state.pending) do
        invited[#invited + 1] = name .. " (" .. Widgets.ROLE_NAMES[pending.role] .. ")"
    end
    table.sort(invited)
    if #invited > 0 then
        return "inviting " .. table.concat(invited, ", ")
    end
    if state.open ~= "" then
        return "looking for " .. describeLetters(state.open)
    end
    return nil
end

-- Roles of invites that are still out, e.g. "HD".
function Filler.reservedRoles()
    if not state then
        return ""
    end
    local counts = { T = 0, H = 0, D = 0 }
    for _, pending in pairs(state.pending) do
        counts[pending.role] = counts[pending.role] + 1
    end
    return Roles.fromCounts(counts)
end

-- Invites still out, as places, sorted by name: { { name, role, class } }
-- (class nil when not known).
function Filler.pendingPlaces()
    local list = {}
    for name, pending in pairs(state and state.pending or {}) do
        list[#list + 1] = { name = name, role = pending.role, class = pending.class }
    end
    table.sort(list, function(a, b)
        return a.name < b.name
    end)
    return list
end

-- What a /reload must not lose, or nil when not filling: the roles sought
-- and the invites still out, with their ages (GetTime is not kept over a
-- relog). An invite about to go out is left out: its timer is gone.
function Filler.saved()
    if not state then
        return nil
    end
    local now, pending, exclude = GetTime(), {}, {}
    for name, out in pairs(state.pending) do
        if out.sentAt then
            pending[name] = { role = out.role, class = out.class, age = now - out.at, sent = now - out.sentAt }
        end
    end
    for name in pairs(state.exclude) do
        exclude[#exclude + 1] = name
    end
    local outcomes = {}
    for name, out in pairs(state.outcomes) do
        outcomes[name] = { kind = out.kind, age = now - out.at, again = out.again }
    end
    return { open = state.open, dungeon = state.dungeon, dungeons = state.dungeons, pending = pending,
        exclude = exclude, invited = state.invited, startedAt = state.startedAt, variety = state.variety,
        outcomes = outcomes }
end

-- Fills on after a /reload from Filler.saved(), `away` seconds later; the
-- invites WoW no longer holds are dropped. Returns whether it did.
function Filler.restore(saved, away)
    if state or type(saved) ~= "table" or type(saved.open) ~= "string" or type(saved.dungeons) ~= "table" then
        return false
    end
    local now, pending, invited, exclude = GetTime(), {}, {}, { [ns.selfName] = true }
    for name, role in pairs(type(saved.invited) == "table" and saved.invited or {}) do
        if Widgets.ROLE_NAMES[role] then
            invited[name] = role
        end
    end
    for _, name in ipairs(type(saved.exclude) == "table" and saved.exclude or {}) do
        exclude[name] = true
    end
    local outcomes = {}
    for name, out in pairs(type(saved.outcomes) == "table" and saved.outcomes or {}) do
        if type(out) == "table" and type(out.kind) == "string" then
            outcomes[name] = { kind = out.kind, at = now - (tonumber(out.age) or 0) - away, again = out.again }
        end
    end
    for name, out in pairs(type(saved.pending) == "table" and saved.pending or {}) do
        local sent = (tonumber(out.sent) or INVITE_LIFETIME) + away
        if Widgets.ROLE_NAMES[out.role] and sent < INVITE_LIFETIME then
            pending[name] = { role = out.role, class = out.class, sentAt = now - sent,
                at = now - math.max(sent, (tonumber(out.age) or 0) + away) }
            invited[name], exclude[name] = out.role, true
            ns.RoleSync.expect(name, out.role)
        end
    end
    state = {
        open = saved.open, dungeon = saved.dungeon, dungeons = saved.dungeons,
        pending = pending, late = {}, exclude = exclude, invited = invited, outcomes = outcomes,
        startedAt = tonumber(saved.startedAt) or GetServerTime(), variety = saved.variety == true or nil,
    }
    if state.dungeon then
        ns.GroupView.track(state.dungeon)
    end
    Log.detail("Filling from the Group Finder again after the reload; still looking for: %s.",
        describeLetters(state.open))
    changed()
    Filler.step()
    return true
end

-- The role a player was invited for from the Group Finder, if any.
function Filler.roleOf(name)
    return state and state.invited[name]
end

function Filler.dungeon()
    return state and state.dungeon
end


-- The dungeon(s) this fill is for; empty when not filling.
function Filler.dungeonIds()
    if not state then
        return {}
    end
    return state.dungeon and { state.dungeon } or state.dungeons
end

function Filler.onChange(listener)
    changeListeners[#changeListeners + 1] = listener
end

-- A queue group formed around this party: from now on only the roles the
-- queue left open (`missing`) are filled from the Group Finder.
function Filler.adopt(view)
    if not state then
        return false
    end
    state.open = view.missing
    state.dungeon = view.dungeon
    for _, member in ipairs(view.members) do
        state.exclude[member.name] = true
    end
    state.message = nil
    Filler.step()
    return true
end

-- nil while a party member's name is still loading.
local function partyNames()
    local members = Party.members()
    if not members then
        return nil
    end
    local names = {}
    for _, member in ipairs(members) do
        names[member.name] = true
    end
    return names
end

-- Who of the invited players joined. Runs on roster changes and every tick,
-- so a join seen while names were still loading is picked up later.
local function checkJoins()
    if not state then
        return false
    end
    local partyState = Party.state()
    if partyState == "member" or partyState == "raid" then
        finish("You joined another group, so Forever Groups stopped inviting players.")
        return true
    end
    local inParty = partyNames()
    if not inParty then
        return false
    end
    local found = false
    for name, pending in pairs(state.pending) do
        if inParty[name] then
            state.pending[name] = nil
            state.open = removeLetter(state.open, pending.role)
            found = true
            Log.detail("%s joined as %s.", name, Widgets.ROLE_NAMES[pending.role])
        end
    end
    for name, late in pairs(state.late) do
        local role = late.role
        if inParty[name] then
            state.late[name] = nil
            found = true
            ns.RoleSync.expect(name, role)
            if string.find(state.open, role, 1, true) then
                state.open = removeLetter(state.open, role)
                Log.detail("%s joined after all, as %s.", name, Widgets.ROLE_NAMES[role])
            else
                Log.warn("%s joined after all, but the %s spot was given to someone else.", name,
                    Widgets.ROLE_NAMES[role])
            end
        end
    end
    return found
end

-- A place may have freed after "Your party is full" (onPartyFull): invite
-- again.
local function placeFreed()
    if state and state.fullAt then
        state.fullAt = nil
        changed()
        Filler.step()
    end
end

local function onRosterUpdate()
    if not state then
        return
    end
    local size = GetNumGroupMembers() or 0
    if size ~= state.groupSize then
        state.groupSize = size
        placeFreed()
        if not state then
            return
        end
    end
    checkJoins()
    if state then
        changed()
        Filler.step()
    end
end

local declinePatterns, declineKinds
local function patterns()
    if not declinePatterns then
        declinePatterns, declineKinds = {}, {}
        for _, key in ipairs(DECLINE_MESSAGES) do
            local format = _G[key]
            if type(format) == "string" then
                local pattern = string.gsub(format, "([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
                pattern = string.gsub(pattern, "%%s", "(.+)")
                declinePatterns[#declinePatterns + 1] = "^" .. pattern .. "$"
                declineKinds[#declinePatterns] = DECLINE_KINDS[key]
            end
        end
    end
    return declinePatterns
end

-- The player named in a "declines your invitation" (or similar) message.
function Filler.declinedName(text)
    if type(text) ~= "string" then
        return nil
    end
    for _, pattern in ipairs(patterns()) do
        local name = string.match(text, pattern)
        if name then
            return name
        end
    end
    return nil
end

-- WoW turned one of our invites down because the party is full
-- (wow/invites.lua tells which): it did not go out after all.
local function onRefused(name)
    if not state or not state.pending[name] then
        return
    end
    state.pending[name] = nil
    state.exclude[name] = nil
    ns.RoleSync.forget(name)
    ns.WhisperInvite.refused(name)
end

local function onPartyFull()
    state.fullAt = GetTime()
    Log.detail("WoW says the party is full: an invite not counted holds a place. Inviting again once one frees up.")
    changed()
end

local function onSystemMessage(text)
    if not state or type(text) ~= "string" then
        return
    end
    if type(ERR_GROUP_FULL) == "string" and text == ERR_GROUP_FULL then
        onPartyFull()
        return
    end
    for i, pattern in ipairs(patterns()) do
        local name = string.match(text, pattern)
        if name and state.pending[name] then
            local pending = state.pending[name]
            local expired = declineKinds[i] == "declined" and pending.sentAt
                and GetTime() - pending.sentAt >= INVITE_LIFETIME - 1
            state.pending[name] = nil
            setOutcome(name, expired and "noanswer" or declineKinds[i])
            ns.RoleSync.forget(name)
            Log.detail(expired and "%s did not answer the invite; trying someone else."
                or "%s did not join; trying someone else.", name)
            Log.debug("WoW said: %s", text)
            state.fullAt = nil
            changed()
            Filler.step()
            return
        elseif name and state.late[name] then
            -- Given up on already, but WoW still held the invite: its place
            -- is free now, and the answer counts.
            state.late[name] = nil
            setOutcome(name, declineKinds[i])
            Log.debug("WoW said: %s", text)
            state.fullAt = nil
            changed()
            Filler.step()
            return
        elseif name then
            placeFreed()
            return
        end
    end
end

-- An automatic away reply (AFK, DND) to the whisper before the invite: that
-- player is passed over, and before the invite went out not invited at all.
local function onAway(_, sender)
    local name = state and ns.Whispers.find(state.pending, sender)
    if not name then
        return
    end
    local pending = state.pending[name]
    state.pending[name] = nil
    setOutcome(name, "away")
    ns.RoleSync.forget(name)
    if pending.sentAt then
        state.late[name] = { role = pending.role, at = pending.sentAt }
    end
    Log.detail("%s is away; inviting someone else.", name)
    changed()
    Filler.step()
end

function Filler.tick()
    if not state then
        return
    end
    if state.waitingForPlace and freePlaces() > 0 then
        Filler.step()
        if not state then
            return
        end
    end
    if checkJoins() then
        if state then
            changed()
            Filler.step()
        end
        return
    end
    local now, expired = GetTime(), false
    for name, pending in pairs(state.pending) do
        if now - (pending.sentAt or pending.at) > INVITE_TIMEOUT then
            state.pending[name] = nil
            state.late[name] = { role = pending.role, at = pending.sentAt or pending.at }
            setOutcome(name, "noanswer")
            ns.RoleSync.forget(name)
            expired = true
            Log.detail("%s did not answer the invite; trying someone else.", name)
        end
    end
    if expired then
        -- An invite of ours ran out: whatever held a place after "Your party
        -- is full" may have been it, whether or not WoW's message came through.
        state.fullAt = nil
        changed()
        Filler.step()
    elseif state.message and not queueProposalOpen() and stillNeeded() ~= "" then
        Filler.step()
    end
end

-- The open roles a party could still need, leaving DPS open rather than a
-- tank or healer when its flexible players allow either. Also returns the
-- role each member then plays.
function Filler.missingFor(members)
    local best
    for _, option in ipairs(Roles.options(members, ns.Config.SLOTS)) do
        local open = {
            T = ns.Config.SLOTS.T - option.counts.T, H = ns.Config.SLOTS.H - option.counts.H,
            D = ns.Config.SLOTS.D - option.counts.D,
        }
        local score = open.T * 100 + open.H * 10 + open.D
        if not best or score < best.score then
            best = { score = score, letters = Roles.fromCounts(open), assignment = option.assignment }
        end
    end
    if best then
        return best.letters, best.assignment
    end
end

function Filler.init()
    ns.Invites.onRefused("filler", onRefused)
    ns.on("GROUP_ROSTER_UPDATE", onRosterUpdate)
    ns.on("CHAT_MSG_SYSTEM", onSystemMessage)
    ns.on("CHAT_MSG_AFK", onAway)
    ns.on("CHAT_MSG_DND", onAway)
    LfgList.onUpdate(Filler.step)
end

ns.Filler = Filler
