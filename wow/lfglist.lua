local _, ns = ...

local Dungeons = ns.Dungeons
local Log = ns.Log

-- Reads WoW's own Group Finder. Searching is protected: C_LFGList.Search only
-- works straight from a click or typed command, so LfgList.search must be
-- called from such a handler. Results of any search, including ones the
-- player starts in Blizzard's window, land in the cache below.
local LfgList = {}

local CATEGORY_DUNGEONS = 2
-- Forever's "Quests & Zones" category (one activity per zone); looked up by
-- name when the client numbers it differently.
local CATEGORY_ZONES = 116
-- Forever's "Battlegrounds" category.
local CATEGORY_BATTLEGROUNDS = 118
local SEARCH_TIMEOUT = 15
local EXPECTED = { T = 1, H = 1, D = 3 }
local ROLE_LETTERS = { TANK = "T", HEALER = "H", DAMAGER = "D" }
local ROLE_KEYS = { TANK = "T", HEALER = "H", DAMAGER = "D", DPS = "D" }

local listings = {}
local KEEP_LISTINGS = 120
-- Every search WoW was asked for, ours or another addon's (or Blizzard's own
-- window), not answered yet, oldest first: { at, mine, kind, languages,
-- generation, ... }. A refusal ("throttled") comes at once and is for the
-- newest. Only an answer while our own search is the only one out replaces
-- listings; any other answer is merged in: nothing is removed and it does
-- not count as a fresh search.
local open = {}
-- Our own search while it is being sent, so the hook knows it is ours.
local issuing
-- GetTime() of the last search seen: WoW allows one search per click or key
-- press, so a second one within the same frame is blocked and never sent.
local searchFrame = -math.huge
-- Our last dungeon search, so a late undo leaves a newer one alone.
local lastDungeonSearch
-- Goes up when the languages change: an answer to a search sent before
-- that is no fresh search for the new languages.
local generation = 0
local languagesChangedAt = -math.huge
-- The result set WoW has now (the last answer, whoever searched): its ids,
-- the kind of its listings, and whether it may bring in new leaders.
local resultSet = { ids = {}, newOk = false }
local languageFilter, undoOwn
-- The part to search again after a refusal.
local retryPart
local failures = 0
local totalResults = 0
local updatedAt
local searchedAt = -math.huge
local failedAt = -math.huge
local ownFailedAt = -math.huge
local listeners = {}

-- One failing listener must not keep the others from the new results.
local function notify()
    for _, listener in ipairs(listeners) do
        local ok, err = pcall(listener)
        if not ok then
            geterrorhandler()(err)
        end
    end
end
local loggedRoleKeys = false
-- Results go to the dungeon, zone or battleground cache, so a zone search
-- never replaces the dungeon listings. Which one is told by the results'
-- activities; an empty result goes by the kind of our own search.
local anySearchAt = -math.huge
-- Goes up whenever the cached listings change.
local version = 0
local zoneCategory = CATEGORY_ZONES
local zoneByActivity, activityByZone = {}, {}
local zoneListings = {}
-- The zones of the results we have from our own zone search.
local resultZones = {}
-- Each zone's level range as the Group Finder suggests it: name => { min, max }.
local zoneLevels = {}
local zoneUpdatedAt
local zoneSearchedAt = -math.huge
local battlegroundListings = {}
local battlegroundsUpdatedAt
local battlegroundsSearchedAt = -math.huge
-- The level bracket whose battleground activities were read; activities
-- found to be no battleground's.
local battlegroundBracket
local notBattleground = {}
-- WoW may not have its activities ready at login (0 zones then, 41 later in
-- the same session): an empty list is read again a few times, when the
-- Group Finder says it is available, and before it is needed.
local ZONE_RETRIES, ZONE_RETRY_DELAY, ZONE_LAZY_GAP = 6, 10, 5
local zoneTries, zoneRetryScheduled, zoneLoadedAt = 0, false, -math.huge
local zonesNeeded

local function isSecret(value)
    if canaccessvalue ~= nil then
        return not canaccessvalue(value)
    end
    return issecretvalue ~= nil and issecretvalue(value) == true
end

-- A zone name (areaName) that can be read, else nil.
local function readableText(text)
    return type(text) == "string" and not isSecret(text) and text ~= "" and text or nil
end

local function call(name, ...)
    local fn = C_LFGList and C_LFGList[name]
    if type(fn) ~= "function" then
        return nil
    end
    local ok, a, b = pcall(fn, ...)
    if ok then
        return a, b
    end
    return nil
end

local function rolesOf(leader)
    local found = {}
    if type(leader.lfgRoles) == "table" then
        if not loggedRoleKeys then
            loggedRoleKeys = true
            local keys = {}
            for key, value in pairs(leader.lfgRoles) do
                keys[#keys + 1] = tostring(key) .. "=" .. tostring(value)
            end
            Log.debug("lfgRoles looks like {%s}", table.concat(keys, ", "))
        end
        for key, value in pairs(leader.lfgRoles) do
            local letter = ROLE_KEYS[string.upper(tostring(key))]
            if letter and value and value ~= 0 then
                found[letter] = true
            end
        end
    end
    local assigned = ROLE_KEYS[tostring(leader.assignedRole)]
    if assigned then
        found[assigned] = true
    end
    local roles = ""
    for _, role in ipairs({ "T", "H", "D" }) do
        if found[role] then
            roles = roles .. role
        end
    end
    return roles
end

local function dungeonsOf(info)
    local ids = {}
    local activities = info.activityIDs or { info.activityID }
    for _, activity in ipairs(activities) do
        local dungeon = Dungeons.byActivity[activity]
        if dungeon then
            ids[#ids + 1] = dungeon.id
        end
    end
    return ids
end

local function zonesOf(info)
    local names = {}
    for _, activity in ipairs(info.activityIDs or { info.activityID }) do
        if zoneByActivity[activity] then
            names[#names + 1] = zoneByActivity[activity]
        end
    end
    return names
end

-- The battleground of an activity, also of another bracket than the
-- player's (WoW's own window shows those).
local function battlegroundOf(activity)
    if type(activity) ~= "number" or isSecret(activity) then
        return nil
    end
    local known = ns.Battlegrounds.byActivity[activity]
    if known or notBattleground[activity] then
        return known
    end
    local info = call("GetActivityInfoTable", activity)
    local map = type(info) == "table" and not isSecret(info.mapID) and info.mapID
    if type(map) ~= "number" then
        return nil
    end
    local battleground = ns.Battlegrounds.setActivity(activity, map, false)
    if not battleground then
        notBattleground[activity] = true
    end
    return battleground
end

-- WoW offers the battleground activities of the player's level bracket
-- only; they are read again when the bracket changes.
local function battlegroundsNeeded()
    local level = ns.Party.playerLevel()
    local bracket = ns.Battlegrounds.bracket(level)
    if bracket == battlegroundBracket then
        return
    end
    ns.Battlegrounds.clearOwnActivities()
    local activities = call("GetAvailableActivities", CATEGORY_BATTLEGROUNDS)
    local count = 0
    for _, activity in ipairs(type(activities) == "table" and activities or {}) do
        local info = call("GetActivityInfoTable", activity)
        if type(info) == "table" and not isSecret(activity) and not isSecret(info.mapID)
            and ns.Battlegrounds.setActivity(activity, info.mapID, true) then
            count = count + 1
        end
    end
    if count > 0 then
        battlegroundBracket = bracket
    end
    Log.debug("group finder battlegrounds: %d activities for level %s", count, tostring(level))
end

local function battlegroundsOf(info)
    local ids = {}
    for _, activity in ipairs(info.activityIDs or { info.activityID }) do
        local battleground = battlegroundOf(activity)
        if battleground then
            ids[#ids + 1] = battleground.id
        end
    end
    return ids
end

-- areasOf: dungeonsOf, zonesOf or battlegroundsOf; the listing keeps them
-- under `field`.
local function readResult(id, areasOf, field)
    areasOf, field = areasOf or dungeonsOf, field or "dungeons"
    local info = call("GetSearchResultInfo", id)
    if type(info) ~= "table" or isSecret(info.numMembers) or info.isDelisted or info.hasSelf then
        return nil
    end
    local name = info.leaderName
    if type(name) ~= "string" or isSecret(name) or name == "" then
        return nil
    end
    local leader = call("GetSearchResultLeaderInfo", id) or call("GetSearchResultPlayerInfo", id, 1)
    if type(leader) ~= "table" then
        return nil
    end
    local areas, roles = areasOf(info), rolesOf(leader)
    -- WoW lets anyone tick any role; a Warlock listed as tank or healer
    -- only plays DPS.
    local class = leader.classFilename
    if type(class) == "string" and not isSecret(class) then
        roles = ns.Classes.filter(roles, class) or ""
    end
    if #areas == 0 or roles == "" then
        return nil
    end
    local remaining
    if (info.numMembers or 1) > 1 then
        local counts = call("GetSearchResultMemberCounts", id)
        if type(counts) == "table" and not isSecret(counts) then
            remaining = {}
            for role, key in pairs({ T = "TANK", H = "HEALER", D = "DAMAGER" }) do
                local left = counts[key .. "_REMAINING"]
                if type(left) ~= "number" then
                    left = EXPECTED[role] - (tonumber(counts[key]) or 0)
                end
                remaining[role] = math.max(0, left)
            end
        end
    end
    -- Who is in a group: class, role and level per member, the leader first.
    local memberInfo
    if (info.numMembers or 1) > 1 then
        memberInfo = {}
        for i = 1, math.min(info.numMembers, 5) do
            local member = call("GetSearchResultPlayerInfo", id, i)
            local memberClass = type(member) == "table" and member.classFilename
            if type(memberClass) == "string" and not isSecret(memberClass) and not isSecret(member.assignedRole)
                and not isSecret(member.level) then
                memberInfo[#memberInfo + 1] = { leader = i == 1, classToken = memberClass,
                    role = ROLE_LETTERS[member.assignedRole],
                    level = tonumber(member.level), area = readableText(member.areaName) }
            end
        end
    end
    -- The listing's note is a protected string (|K...|k): it can be shown in
    -- a tooltip or font string, but its text cannot be read.
    local comment = info.comment
    if type(comment) ~= "string" or isSecret(comment) or comment == "" then
        comment = nil
    end
    return {
        id = id, name = name, leader = name, level = tonumber(leader.level), classToken = leader.classFilename,
        comment = comment,
        roles = roles, [field] = areas, age = tonumber(info.age) or 0, solo = info.numMembers == 1,
        members = tonumber(info.numMembers) or 1,
        remaining = remaining, playstyle = ns.Playstyle.fromWoW(info.generalPlaystyle), memberInfo = memberInfo,
        area = readableText(leader.areaName),
    }
end

-- During a boss fight the results are secret: such a result says nothing
-- about the listing, so what was read before stays.
local function unreadable(id)
    local info = call("GetSearchResultInfo", id)
    return type(info) == "table" and (isSecret(info.numMembers) or isSecret(info.leaderName))
end

-- How a result of each kind is read. A battleground listing's open places
-- are the battleground's size less its members (roles hardly matter there).
local READERS = {
    dungeons = function(id)
        return readResult(id)
    end,
    zones = function(id)
        return readResult(id, zonesOf, "zones")
    end,
    battlegrounds = function(id)
        local listing = readResult(id, battlegroundsOf, "battlegrounds")
        if listing then
            local battleground = ns.Battlegrounds.get(listing.battlegrounds[1])
            listing.remaining = nil
            listing.open = math.max(0, (battleground and battleground.size or 10) - listing.members)
        end
        return listing
    end,
}

local KINDS = { "dungeons", "zones", "battlegrounds" }

local function listOf(kind)
    if kind == "zones" then
        return zoneListings
    elseif kind == "battlegrounds" then
        return battlegroundListings
    end
    return listings
end

local function setList(kind, list)
    if kind == "zones" then
        zoneListings = list
    elseif kind == "battlegrounds" then
        battlegroundListings = list
    else
        listings = list
    end
end

-- The usable listings among these results, one per leader (a leader has one
-- listing; should a name come twice, the newest counts), and how many could
-- not be read (secret during a boss fight).
local function readAll(kind, ids)
    local result, byName, secret = {}, {}, 0
    local now = GetTime()
    for _, id in ipairs(ids) do
        local ok, listing = pcall(READERS[kind], id)
        if ok and listing then
            listing.seenAt = now
            local index = byName[listing.name]
            if not index then
                result[#result + 1] = listing
                byName[listing.name] = #result
            elseif (listing.age or 0) < (result[index].age or 0) then
                result[index] = listing
            end
        elseif unreadable(id) then
            secret = secret + 1
        end
    end
    return result, secret
end

-- A leader lists for one kind at a time: placed in one list, the same name
-- leaves the other two.
local function dropElsewhere(kind, placed)
    local names = {}
    for _, listing in ipairs(placed) do
        names[listing.name] = true
    end
    for _, other in ipairs(KINDS) do
        if other ~= kind then
            local kept, dropped = {}, 0
            for _, listing in ipairs(listOf(other)) do
                if names[listing.name] then
                    dropped = dropped + 1
                else
                    kept[#kept + 1] = listing
                end
            end
            if dropped > 0 then
                setList(other, kept)
                Log.debug("group finder: %d leaders moved from %s to %s", dropped, other, kind)
            end
        end
    end
end

local function refreshZones(ids, record)
    local result, secret = readAll("zones", ids)
    if #result == 0 and secret > 0 then
        return
    end
    zoneListings = result
    zoneUpdatedAt = GetTime()
    resultZones = record.zones or {}
    dropElsewhere("zones", result)
    version = version + 1
    Log.debug("group finder zones: %d usable listings of %d results", #result, #ids)
    notify()
end

local function refreshBattlegrounds(ids)
    local result, secret = readAll("battlegrounds", ids)
    if #result == 0 and secret > 0 then
        return
    end
    battlegroundListings = result
    battlegroundsUpdatedAt = GetTime()
    dropElsewhere("battlegrounds", result)
    version = version + 1
    Log.debug("group finder battlegrounds: %d usable listings of %d results", #result, #ids)
    notify()
end

-- The kind of these results by their activities; nil for results we can't
-- place (another category of WoW's window, or none at all).
local function kindOf(ids)
    local zones, dungeons, battlegrounds = 0, 0, 0
    for _, id in ipairs(ids) do
        local info = call("GetSearchResultInfo", id)
        local activities = type(info) == "table" and not isSecret(info.activityIDs) and info.activityIDs
        for _, activity in ipairs(type(activities) == "table" and activities or {}) do
            if zoneByActivity[activity] then
                zones = zones + 1
            elseif Dungeons.byActivity[activity] then
                dungeons = dungeons + 1
            elseif battlegroundOf(activity) then
                battlegrounds = battlegrounds + 1
            end
        end
    end
    if dungeons > 0 then
        return "dungeons"
    elseif zones > 0 then
        return "zones"
    elseif battlegrounds > 0 then
        return "battlegrounds"
    end
    return nil
end

local function coversListing(covered, listing)
    for _, id in ipairs(listing.dungeons or {}) do
        local dungeon = Dungeons.get(id)
        if dungeon and dungeon.lfg and covered[dungeon.lfg] then
            return true
        end
    end
    return false
end

-- The languages of a search as a set: nil is the player's own language
-- (what the server answers then); false when they could not be read.
local function languageSet(languages)
    if languages == nil then
        return { [ns.MatchLanguages.own()] = true }
    end
    return languages
end

-- An empty set may be all languages to the server: not within.
local function within(languages, allowed)
    if languages == false or (type(languages) == "table" and next(languages) == nil) then
        return false
    end
    local ok = languageSet(allowed)
    for code in pairs(languageSet(languages)) do
        if not ok[code] then
            return false
        end
    end
    return true
end

-- Whether an answer may bring in leaders we don't know yet: only when every
-- search it could be the answer to asked for languages the player groups
-- with, and the list was not cleared meanwhile.
local function mayAddLeaders(records)
    if #records == 0 then
        return false
    end
    local allowed = languageFilter()
    for _, record in ipairs(records) do
        if record.cleared or not within(record.languages, allowed) then
            return false
        end
    end
    return true
end

local function remember(ids, kind, newOk)
    local set = {}
    for _, id in ipairs(ids) do
        set[id] = true
    end
    resultSet = { ids = set, kind = kind, newOk = newOk }
end

-- An answer that is not to our own search (another addon's, Blizzard's
-- window, or ours overtaken by one of those): known leaders are updated and
-- new ones added when the languages allow it. Nothing is removed, and no
-- search time changes: these results may be filtered (one language, one
-- role) and say nothing about the listings they leave out.
local function merge(kind, ids, newOk, whose)
    local result, secret = readAll(kind, ids)
    if #result == 0 then
        if secret > 0 then
            Log.debug("group finder: %d results of %s unreadable right now", secret, whose)
        end
        return
    end
    local list = listOf(kind)
    local index = {}
    for i, listing in ipairs(list) do
        index[listing.name] = i
    end
    local placed, updated, added, skipped = {}, 0, 0, 0
    for _, listing in ipairs(result) do
        local i = index[listing.name]
        if i then
            list[i] = listing
            placed[#placed + 1] = listing
            updated = updated + 1
        elseif newOk then
            list[#list + 1] = listing
            index[listing.name] = #list
            placed[#placed + 1] = listing
            added = added + 1
        else
            skipped = skipped + 1
        end
    end
    dropElsewhere(kind, placed)
    version = version + 1
    Log.debug("group finder: %s results of %s merged in: %d new, %d updated, nothing removed%s", kind, whose,
        added, updated, skipped > 0 and string.format("; %d new leaders left out, as a search out asked for "
            .. "other languages than yours", skipped) or "")
    notify()
end

local function expireOpen()
    local now, kept = GetTime(), {}
    for _, record in ipairs(open) do
        if now - record.at < SEARCH_TIMEOUT then
            kept[#kept + 1] = record
        end
    end
    open = kept
end

-- Whether these results can be the answer to this search: the same kind,
-- and most listings have an activity the search asked for (a dungeon search
-- of the main part does not bring the rest's listings). Most, not all: it is
-- not known whether the server, with a role filter, keeps strictly to the
-- activities asked for.
local function fits(record, kind, ids)
    if kind and record.kind and record.kind ~= kind then
        return false
    end
    local wanted = record.activities
    if not wanted then
        return true
    end
    local readable, fitting = 0, 0
    for _, id in ipairs(ids) do
        local info = call("GetSearchResultInfo", id)
        local activities = type(info) == "table" and not isSecret(info.activityIDs) and info.activityIDs
        if type(activities) == "table" and #activities > 0 then
            readable = readable + 1
            for _, activity in ipairs(activities) do
                if wanted[activity] == true then
                    fitting = fitting + 1
                    break
                end
            end
        end
    end
    return fitting * 2 > readable or readable == 0
end

-- An answer belongs to the searches out that its results fit. One search of
-- ours alone replaces listings; anything else is merged in. With several
-- fitting (whether WoW answers each search or only the newest is not
-- known), all of them are settled and ours go again on a later input.
function LfgList.refresh()
    expireOpen()
    local found, ids = call("GetSearchResults")
    if type(ids) ~= "table" then
        return
    end
    local kind = kindOf(ids)
    local settled, rest = {}, {}
    for _, record in ipairs(open) do
        if fits(record, kind, ids) then
            settled[#settled + 1] = record
        else
            rest[#rest + 1] = record
        end
    end
    open = rest
    local record = #settled == 1 and settled[1] or nil
    local own = record ~= nil and record.mine and not record.undone and not record.cleared
        and record.generation == generation
    if not own then
        local whose = #settled == 0 and "a search not seen"
            or #settled > 1 and "one of " .. #settled .. " searches out at once"
            or not record.mine and "another addon's search"
            or record.cleared and "our search, after the list was cleared"
            or record.generation ~= generation and "our search from before the languages changed"
            or "our search, already undone"
        for _, other in ipairs(settled) do
            if other.mine then
                undoOwn(other, false)
            end
        end
        local newOk = mayAddLeaders(settled)
        remember(ids, kind, newOk)
        if not kind then
            Log.debug("group finder: %d results of %s, left alone", #ids, whose)
            return
        end
        merge(kind, ids, newOk, whose)
        return
    end
    -- Empty results of our own search are news too: that kind has nothing.
    kind = record.kind
    remember(ids, kind, true)
    if kind == "zones" then
        refreshZones(ids, record)
        return
    elseif kind == "battlegrounds" then
        refreshBattlegrounds(ids)
        return
    end
    local result, secret = readAll("dungeons", ids)
    if #result == 0 and secret > 0 then
        Log.debug("group finder: %d results unreadable right now; keeping the last ones", secret)
        return
    end
    -- Our searches cover part of the dungeons; the other part's listings
    -- stay. A listing for dungeons of both parts comes back in each search
    -- under a new id: one per leader, the newest.
    -- They are kept for KEEP_LISTINGS s, not forever: the other part may not
    -- be searched again (once queued, only the queued dungeons are).
    local covered = record.covered
    local now = GetTime()
    if covered then
        local fresh = {}
        for _, listing in ipairs(result) do
            fresh[listing.name] = true
        end
        for _, listing in ipairs(listings) do
            if not coversListing(covered, listing) and not fresh[listing.name]
                and now - (listing.seenAt or 0) < KEEP_LISTINGS then
                result[#result + 1] = listing
            end
        end
    end
    listings = result
    dropElsewhere("dungeons", result)
    retryPart, failures = nil, 0
    version = version + 1
    totalResults = #ids
    updatedAt = GetTime()
    Log.debug("group finder: %d results (%s found), %d listings kept, %.1f s after the search", #ids,
        tostring(found), #listings, updatedAt - record.at)
    notify()
end

-- WoW reports a change to one result between searches: someone delisted or
-- formed a group, or a leader's name arrived after the results did. Drop,
-- update or add just that listing.
-- The listeners hear of a group that delisted between searches, once for a
-- burst of updates: an ask to its leader is over without waiting for the
-- next search.
local notifyPending = false

local function notifySoon()
    if notifyPending or not (C_Timer and C_Timer.After) then
        return
    end
    notifyPending = true
    C_Timer.After(0.5, function()
        notifyPending = false
        notify()
    end)
end

-- Whether a result id is still this listing's: a listing keeps the id of
-- the search it was last seen in, and that id must not update or remove
-- another leader's listing.
local function sameLeader(id, listing)
    local info = call("GetSearchResultInfo", id)
    local name = type(info) == "table" and info.leaderName
    return type(name) ~= "string" or isSecret(name) or name == "" or name == listing.name
end

local function updateIn(kind, id)
    local list = listOf(kind)
    for i, listing in ipairs(list) do
        if listing.id == id and sameLeader(id, listing) then
            local ok, fresh = pcall(READERS[kind], id)
            if ok and fresh then
                fresh.seenAt = GetTime()
                list[i] = fresh
            else
                table.remove(list, i)
                Log.debug("group finder: %s is no longer listed", listing.name)
            end
            return true
        end
    end
    return false
end

local function onResultUpdated(id)
    if unreadable(id) then
        return
    end
    version = version + 1
    if LfgList.isDelisted(id) then
        notifySoon()
    end
    if updateIn("zones", id) or updateIn("battlegrounds", id) or updateIn("dungeons", id) then
        return
    end
    -- A result of the current set not placed yet: its leader's name came
    -- after the results did. It comes in like the rest of its set did.
    if not resultSet.ids[id] or resultSet.kind ~= "dungeons" then
        return
    end
    local ok, fresh = pcall(READERS.dungeons, id)
    if not (ok and fresh) then
        return
    end
    fresh.seenAt = GetTime()
    for i, listing in ipairs(listings) do
        if listing.name == fresh.name then
            listings[i] = fresh
            return
        end
    end
    if resultSet.newOk then
        listings[#listings + 1] = fresh
        dropElsewhere("dungeons", { fresh })
    end
end

local function activitiesOf(ids)
    local activities = {}
    for _, id in ipairs(ids) do
        local dungeon = Dungeons.get(id)
        if dungeon and dungeon.lfg then
            activities[#activities + 1] = dungeon.lfg
        end
    end
    return activities
end

-- What to search for, in two parts. WoW returns at most 100 results per
-- search, and five dungeons together already reach that, so the dungeons
-- that matter (being filled, else queued for, else ticked) are searched on
-- their own; the rest of the player's level, only for the window's numbers,
-- in a search of their own (only while browsing). Returns the main
-- activities and the rest's.
local function searchParts()
    local ids = ns.Filler and ns.Filler.dungeonIds() or nil
    if ids and #ids > 0 then
        return activitiesOf(ids), {}
    end
    local entry = ns.engine and ns.engine.myEntry
    if entry then
        return activitiesOf(entry.dungeons), {}
    end
    local ticked, seen = {}, {}
    for _, id in ipairs(ns.Window and ns.Window.selectedDungeonIds() or {}) do
        ticked[#ticked + 1], seen[id] = id, true
    end
    local rest = {}
    for _, dungeon in ipairs(Dungeons.forLevel(ns.Party.playerLevel())) do
        if not seen[dungeon.id] then
            rest[#rest + 1] = dungeon.id
        end
    end
    if #ticked == 0 then
        return activitiesOf(rest), {}
    end
    return activitiesOf(ticked), activitiesOf(rest)
end

local function wantedActivities()
    local main, rest = searchParts()
    for _, activity in ipairs(rest) do
        main[#main + 1] = activity
    end
    return main
end

-- With one role looked for, alone, the server returns only groups with a
-- place for it (and every solo player): WoW's advanced filter, which needs
-- the activities' groups. nil when that cannot be built.
local function roleFilter(activities)
    if not ns.Party or ns.Party.state() ~= "solo" then
        return nil
    end
    local entry = ns.engine and ns.engine.myEntry
    local roles = (entry and entry.members[1].roles) or (ns.charDb and ns.charDb.lastRoles)
    if type(roles) ~= "string" or #roles ~= 1 then
        return nil
    end
    local base = call("GetAdvancedFilter")
    if type(base) ~= "table" then
        return nil
    end
    local filter = {}
    for key, value in pairs(base) do
        if type(value) == "boolean" then
            filter[key] = false
        else
            filter[key] = value
        end
    end
    filter.minimumRating = 0
    local groups, seen = {}, {}
    for _, activity in ipairs(activities) do
        local info = call("GetActivityInfoTable", activity)
        local group = type(info) == "table" and info.groupFinderActivityGroupID
        if not group then
            return nil
        end
        if not seen[group] then
            groups[#groups + 1], seen[group] = group, true
        end
    end
    filter.activities = groups
    filter.needsTank, filter.needsHealer, filter.needsDamage = roles == "T", roles == "H", roles == "D"
    return filter
end

-- The languages the player is grouped with (wow/matchlanguages.lua) that
-- the Group Finder offers. Without a filter it returns only the player's
-- own language.
languageFilter = function()
    local offered = call("GetAvailableLanguageSearchFilter")
    if type(offered) ~= "table" or #offered == 0 then
        return nil
    end
    local accepted = ns.MatchLanguages.accepted()
    local filter = { [ns.MatchLanguages.own()] = true }
    for _, code in ipairs(offered) do
        if accepted[code] then
            filter[code] = true
        end
    end
    return filter
end

-- The dungeon activities searched for, and those of the last dungeon search
-- (nil for one from Blizzard's window).
local searchedActivities = {}

-- Whether the Group Finder numbers for a dungeon are known: it was in the
-- last dungeon search, or the Group Finder has nothing for it.
function LfgList.isSearched(dungeonId)
    local dungeon = Dungeons.get(dungeonId)
    if not ns.Features.groupFinder() or not dungeon or not dungeon.lfg then
        return true
    end
    return searchedActivities[dungeon.lfg] == true
end

-- From a click that changed the wanted dungeons: searches again only when
-- one of them was not in the last search (unticking needs no search).
function LfgList.searchIfMissing()
    for _, activity in ipairs(wantedActivities()) do
        if not searchedActivities[activity] then
            return LfgList.search()
        end
    end
    return false
end

local lastPart

-- The server allows about two searches (of any kind, from any addon) per
-- five seconds and refuses a third as "throttled"; refused tries don't count
-- (/fgp lfgapi gap). So the rest follows a main search quickly, a search
-- waits while two went out in the last BURST_WINDOW s, and a refused one is
-- tried again on input at least RETRY_GAP s later, at most MAX_RETRIES times
-- in a row. The times of every search come from the hook on
-- C_LFGList.Search below.
local REST_GAP = 1.5
local BURST, BURST_WINDOW = 2, 5.5
local RETRY_GAP, MAX_RETRIES = 3, 3
local sentAt = {}

local function roomToSearch()
    local now, recent = GetTime(), {}
    for _, at in ipairs(sentAt) do
        if now - at < BURST_WINDOW then
            recent[#recent + 1] = at
        end
    end
    sentAt = recent
    return #recent < BURST and now - failedAt >= RETRY_GAP and searchFrame ~= now
end

-- A search of ours that is not going to be answered as ours (refused by the
-- server, or overtaken by another search) counts as not done: its part
-- keeps its turn and goes again on a later input. Search times go back only
-- when no newer search of ours set them since.
undoOwn = function(record, refused)
    if record.undone then
        return
    end
    record.undone = true
    local undo = record.undo
    if anySearchAt == record.at then
        anySearchAt = undo.anySearchAt
    end
    if record.kind == "zones" then
        if zoneSearchedAt == record.at then
            zoneSearchedAt = undo.searchedAt
        end
        return
    elseif record.kind == "battlegrounds" then
        if battlegroundsSearchedAt == record.at then
            battlegroundsSearchedAt = undo.searchedAt
        end
        return
    end
    if lastDungeonSearch == record then
        for _, activity in ipairs(undo.new) do
            searchedActivities[activity] = nil
        end
        lastPart = undo.lastPart
        if searchedAt == record.at then
            searchedAt = undo.searchedAt
        end
    end
    local part = undo.part == "rest" and "rest" or "main"
    if refused then
        failures = failures + 1
        retryPart = failures < MAX_RETRIES and part or nil
    else
        retryPart = retryPart or part
    end
end

-- A copy of a search's languages, the ones set to true; nil stays nil (the
-- player's own language), false when they can't be read.
local function copyLanguages(languages)
    if languages == nil then
        return nil
    end
    local ok, set = pcall(function()
        if isSecret(languages) or type(languages) ~= "table" then
            return false
        end
        local copy = {}
        for code, on in pairs(languages) do
            if isSecret(code) or isSecret(on) then
                return false
            end
            if on == true and type(code) == "string" then
                copy[code] = true
            end
        end
        return copy
    end)
    return ok and set or false
end

local function languageText(languages)
    if languages == nil then
        return "own"
    elseif languages == false then
        return "unreadable"
    end
    local codes = {}
    for code in pairs(languages) do
        codes[#codes + 1] = code
    end
    table.sort(codes)
    return #codes > 0 and table.concat(codes, ",") or "none"
end

-- The kind of a search by its category; "other" for a category we don't
-- read, nil when it can't be read.
local function categoryKind(category)
    if isSecret(category) or type(category) ~= "number" then
        return nil
    elseif category == CATEGORY_DUNGEONS then
        return "dungeons"
    elseif category == zoneCategory then
        return "zones"
    elseif category == CATEGORY_BATTLEGROUNDS then
        return "battlegrounds"
    end
    return "other"
end

-- A set of a search's activities; nil for all of its category, or when they
-- can't be read.
local function activitySet(activities)
    local ok, set = pcall(function()
        if isSecret(activities) or type(activities) ~= "table" or #activities == 0 then
            return nil
        end
        local copy = {}
        for _, activity in ipairs(activities) do
            if isSecret(activity) then
                return nil
            end
            copy[activity] = true
        end
        return copy
    end)
    return ok and set or nil
end

-- Runs after every C_LFGList.Search, whoever calls it: our own searches
-- (issuing), another addon's, Blizzard's window.
local function onSearch(category, _, _, languages, _, _, activities)
    local now = GetTime()
    local record = issuing
    if record then
        record.seen = true
    end
    if now == searchFrame then
        if record then
            record.blocked = true
        end
        Log.debug("group finder: a second search in one input (%s), which WoW blocks; not counted",
            record and "ours" or "another addon's")
        return
    end
    searchFrame = now
    expireOpen()
    if record then
        -- A newer search of ours of the same kind takes the place of one
        -- still out: an answer to the older one is no longer awaited. One
        -- from before the languages changed stays, so its answer is not
        -- taken for the new search's.
        local kept = {}
        for _, other in ipairs(open) do
            if not (other.mine and other.kind == record.kind and other.generation == generation) then
                kept[#kept + 1] = other
            end
        end
        open = kept
    else
        record = { mine = false, kind = categoryKind(category), activities = activitySet(activities) }
    end
    record.at, record.generation = now, generation
    record.languages = copyLanguages(languages)
    open[#open + 1] = record
    sentAt[#sentAt + 1] = now
    if not record.mine then
        local count = type(activities) == "table" and not isSecret(activities) and #activities or "all"
        Log.debug("group finder: another addon or WoW's window searched (category %s, %s activities, languages %s)",
            isSecret(category) and "?" or tostring(category), tostring(count), languageText(record.languages))
    end
end

-- Another addon (or WoW's window) emptied the result list: answers to the
-- searches still out may be empty for that, not for an empty Group Finder.
local function onClear()
    for _, record in ipairs(open) do
        record.cleared = true
    end
    resultSet = { ids = {}, newOk = false }
    Log.debug("group finder: the result list was cleared by another addon or WoW's window")
end

-- Sends one search of ours. The hook notes it (or here, should the hook be
-- missing); a search WoW would block as the second of this input is not sent.
local function send(fn, record, ...)
    issuing = record
    local ok, err = pcall(fn, ...)
    if ok and not record.seen then
        pcall(onSearch, ...)
    end
    issuing = nil
    if ok and record.blocked then
        return false, "blocked"
    end
    return ok, err
end

local function restNeverSearched(rest)
    for _, activity in ipairs(rest) do
        if not searchedActivities[activity] then
            return true
        end
    end
    return false
end

-- The search that follows another, at least REST_GAP s later: after a first
-- search of everything ("all") the main part on its own; after a main search
-- the rest, while the main results are younger than `fresh` s. Only from a
-- click or key press.
function LfgList.searchRestIfDue(fresh)
    if retryPart and failures < MAX_RETRIES and roomToSearch() then
        return LfgList.search(retryPart)
    end
    local _, rest = searchParts()
    if #rest == 0 or GetTime() - anySearchAt < REST_GAP then
        return false
    end
    if lastPart == "all" then
        return LfgList.search()
    end
    if lastPart ~= "main" then
        return false
    end
    if not restNeverSearched(rest) and GetTime() - searchedAt >= fresh then
        return false
    end
    return LfgList.search("rest")
end

-- Only from a click or key press; returns false if WoW refused. Searches the
-- main part (searchParts), or with part "rest" the rest. While nothing is
-- known about the rest yet, a main search covers everything at once, so the
-- window has numbers for every dungeon right away (possibly cut at 100; the
-- main part on its own follows).
function LfgList.search(part)
    if ns.Demo.isOn() then
        return false
    end
    local fn = C_LFGList and C_LFGList.Search
    if type(fn) ~= "function" or not ns.Features.groupFinder() then
        return false
    end
    if not roomToSearch() then
        -- Goes out on the next input once the server has room again.
        retryPart = retryPart or (part == "rest" and "rest" or "main")
        return false, "wait"
    end
    retryPart = nil
    local mainPart, rest = searchParts()
    part = (part == "rest" and #rest > 0) and "rest" or "main"
    if part == "main" and #rest > 0 and restNeverSearched(rest) then
        part = "all"
        for _, activity in ipairs(rest) do
            mainPart[#mainPart + 1] = activity
        end
    end
    local activities = part == "rest" and rest or mainPart
    if #activities == 0 then
        -- Nothing the Group Finder lists (The Stockade has no activity): a
        -- search of everything would only bring 100 other results.
        return false
    end
    local now = GetTime()
    local record = { mine = true, kind = "dungeons", covered = {},
        undo = { part = part, lastPart = lastPart, searchedAt = searchedAt, anySearchAt = anySearchAt, new = {} } }
    record.activities = record.covered
    for _, activity in ipairs(activities) do
        record.covered[activity] = true
        if not searchedActivities[activity] then
            record.undo.new[#record.undo.new + 1] = activity
        end
    end
    anySearchAt = now
    if part ~= "rest" then
        searchedAt = now
    end
    lastDungeonSearch = record
    local filter = part ~= "rest" and roleFilter(activities) or nil
    local ok, err = send(fn, record, CATEGORY_DUNGEONS, 0, 0, languageFilter(), false, filter, activities)
    if err == "blocked" then
        record.at = now
        undoOwn(record, false)
        return false, "wait"
    end
    if not ok and filter then
        Log.debug("group finder search with a role filter failed (%s); without it", tostring(err))
        ok, err = send(fn, record, CATEGORY_DUNGEONS, 0, 0, languageFilter(), false, nil, activities)
    end
    Log.debug("group finder: searching %d dungeons (%s%s)", #activities, part, filter and ", role filter" or "")
    for _, activity in ipairs(activities) do
        searchedActivities[activity] = true
    end
    lastPart = part
    if not ok then
        if err then
            Log.debug("filtered group finder search failed (%s); searching everything", tostring(err))
        end
        -- Capped at 100 results: no dungeon counts as covered.
        record.covered, record.activities = nil, nil
        ok, err = send(fn, record, CATEGORY_DUNGEONS)
        searchedActivities = {}
    end
    if not ok then
        Log.debug("group finder search failed: %s", tostring(err))
    end
    return ok
end

-- Searches the "Quests & Zones" category for these zone names; only from a
-- click or key press.
function LfgList.searchZones(zones)
    if ns.Demo.isOn() then
        return false
    end
    local fn = C_LFGList and C_LFGList.Search
    local activities = {}
    for _, zone in ipairs(zones) do
        if activityByZone[zone] then
            activities[#activities + 1] = activityByZone[zone]
        end
    end
    if type(fn) ~= "function" or #activities == 0 or not ns.Features.groupFinder() or not roomToSearch() then
        return false
    end
    local record = { mine = true, kind = "zones", zones = {}, activities = activitySet(activities),
        undo = { searchedAt = zoneSearchedAt, anySearchAt = anySearchAt } }
    for _, zone in ipairs(zones) do
        record.zones[zone] = true
    end
    zoneSearchedAt, anySearchAt = GetTime(), GetTime()
    local ok, err = send(fn, record, zoneCategory, 0, 0, languageFilter(), false, nil, activities)
    if err == "blocked" then
        record.at = GetTime()
        undoOwn(record, false)
    elseif not ok then
        Log.debug("zone search failed: %s", tostring(err))
    end
    return ok
end

-- Only from a click or key press, like LfgList.search.
function LfgList.searchBattlegrounds()
    if ns.Demo.isOn() then
        return false
    end
    local fn = C_LFGList and C_LFGList.Search
    if type(fn) ~= "function" or not ns.Features.groupFinder() or not roomToSearch() then
        return false
    end
    battlegroundsNeeded()
    local activities = {}
    for _, battleground in ipairs(ns.Battlegrounds.list) do
        activities[#activities + 1] = battleground.lfg
    end
    if #activities == 0 then
        return false
    end
    local record = { mine = true, kind = "battlegrounds", activities = activitySet(activities),
        undo = { searchedAt = battlegroundsSearchedAt, anySearchAt = anySearchAt } }
    battlegroundsSearchedAt, anySearchAt = GetTime(), GetTime()
    local ok, err = send(fn, record, CATEGORY_BATTLEGROUNDS, 0, 0, languageFilter(), false, nil, activities)
    if err == "blocked" then
        record.at = GetTime()
        undoOwn(record, false)
    elseif not ok then
        Log.debug("battleground search failed: %s", tostring(err))
    end
    return ok
end

-- The Group Finder's activity of this battleground for the player's level
-- bracket; nil when it lists none.
function LfgList.battlegroundActivity(id)
    battlegroundsNeeded()
    local battleground = ns.Battlegrounds.get(id)
    return battleground and battleground.lfg
end

function LfgList.battlegroundListings()
    return battlegroundListings, battlegroundsUpdatedAt
end

-- Whether the battleground numbers are known: searched, or the Group Finder
-- is off (then only Forever Groups counts).
function LfgList.battlegroundsSearched()
    return battlegroundsUpdatedAt ~= nil or not ns.Features.groupFinder()
end

function LfgList.secondsSinceBattlegroundSearch()
    return GetTime() - battlegroundsSearchedAt
end

function LfgList.zoneListings()
    return zoneListings, zoneUpdatedAt
end

-- Whether the zone results we have cover this zone.
function LfgList.zoneSearched(zone)
    return zoneUpdatedAt ~= nil and resultZones[zone] == true
end

function LfgList.secondsSinceZoneSearch()
    return GetTime() - zoneSearchedAt
end

function LfgList.zoneCount()
    zonesNeeded()
    local count = 0
    for _ in pairs(activityByZone) do
        count = count + 1
    end
    return count
end

-- The zones whose suggested levels include this level, A-Z.
function LfgList.zonesForLevel(level)
    zonesNeeded()
    local zones = {}
    for name, range in pairs(zoneLevels) do
        if level >= range[1] and level <= range[2] then
            zones[#zones + 1] = name
        end
    end
    table.sort(zones)
    return zones
end

function LfgList.zoneActivity(zone)
    zonesNeeded()
    return activityByZone[zone]
end

-- The zone activities of the "Quests & Zones" category, by zone name.
function LfgList.loadZones()
    local ok, categories = pcall(C_LFGList.GetAvailableCategories)
    for _, id in ipairs(ok and type(categories) == "table" and categories or {}) do
        local info = call("GetLfgCategoryInfo", id)
        local name = type(info) == "table" and info.name
        if type(name) == "string" and not isSecret(name) and string.find(string.lower(name), "quest") then
            zoneCategory = id
        end
    end
    local actOk, activities = pcall(C_LFGList.GetAvailableActivities, zoneCategory)
    local count = 0
    for _, activity in ipairs(actOk and type(activities) == "table" and activities or {}) do
        local info = call("GetActivityInfoTable", activity)
        local name = type(info) == "table" and (info.fullName or info.shortName)
        if type(name) == "string" and not isSecret(name) then
            zoneByActivity[activity] = name
            activityByZone[name] = activity
            local min, max = tonumber(info.minLevelSuggestion), tonumber(info.maxLevelSuggestion)
            if min and max and min > 0 and max >= min then
                zoneLevels[name] = { min, max }
            end
            count = count + 1
        end
    end
    zoneLoadedAt = GetTime()
    Log.debug("group finder zones: %d in category %s", count, tostring(zoneCategory))
    if count == 0 and zoneTries < ZONE_RETRIES and not zoneRetryScheduled then
        zoneTries = zoneTries + 1
        zoneRetryScheduled = true
        C_Timer.After(ZONE_RETRY_DELAY, function()
            zoneRetryScheduled = false
            if next(activityByZone) == nil then
                LfgList.loadZones()
            end
        end)
    end
end

zonesNeeded = function()
    if next(activityByZone) == nil and GetTime() - zoneLoadedAt >= ZONE_LAZY_GAP then
        LfgList.loadZones()
    end
end

-- Searches when the last search is at least `age` seconds old; only from a
-- click or key press.
function LfgList.searchIfStale(age)
    if retryPart and failures < MAX_RETRIES and roomToSearch() then
        return LfgList.search(retryPart)
    end
    if LfgList.searchRestIfDue(age) then
        return true
    end
    if GetTime() - searchedAt >= age then
        return LfgList.search()
    end
    return false
end

-- A search was sent and its results have not arrived yet.
function LfgList.isSearching()
    return searchedAt > (updatedAt or -math.huge) and searchedAt > ownFailedAt
        and GetTime() - searchedAt < SEARCH_TIMEOUT
end

function LfgList.hasSearched()
    return updatedAt ~= nil
end

function LfgList.secondsSinceSearch()
    return GetTime() - searchedAt
end

-- Since any search of ours, dungeons or zones: the key press refresh waits
-- between searches of either kind.
function LfgList.secondsSinceAnySearch()
    return GetTime() - anySearchAt
end

-- Everything WoW's Group Finder returned for Dungeons, groups included.
function LfgList.totalResults()
    return totalResults
end

-- Listed groups (two or more players) with the roles they still need.
-- Whether a result is still listed, also when it could not be read (its
-- leader's name not there yet): asks wait for it instead of giving up.
function LfgList.isDelisted(id)
    local info = id ~= nil and call("GetSearchResultInfo", id)
    return type(info) == "table" and not isSecret(info.isDelisted) and info.isDelisted == true
end

function LfgList.stillListed(id)
    if id == nil then
        return false
    end
    local info = call("GetSearchResultInfo", id)
    return type(info) == "table" and not isSecret(info.isDelisted) and not info.isDelisted
end

function LfgList.groups()
    local groups = {}
    for _, listing in ipairs(listings) do
        if not listing.solo and listing.remaining then
            groups[#groups + 1] = listing
        end
    end
    return groups
end

function LfgList.version()
    return version
end

function LfgList.listings()
    return listings, updatedAt
end

function LfgList.onUpdate(listener)
    listeners[#listeners + 1] = listener
end

local rolesFailed = false

-- Sets the roles of WoW's Group Finder (Forever's C_LFGListRoles) to the ones
-- ticked here, so its sign-ups and invites go by the same roles. Only from a
-- click, as it may need one; after an error it stays off for the session.
function LfgList.syncRoles(roles)
    if ns.Demo.isOn() then
        return
    end
    local api = _G.C_LFGListRoles
    if rolesFailed or type(api) ~= "table" or type(api.SetRoles) ~= "function" or type(roles) ~= "string"
        or roles == "" then
        return
    end
    local wanted = {
        tank = string.find(roles, "T", 1, true) ~= nil,
        healer = string.find(roles, "H", 1, true) ~= nil,
        dps = string.find(roles, "D", 1, true) ~= nil,
    }
    local _, current = pcall(api.GetRoles)
    if type(current) == "table" and current.tank == wanted.tank and current.healer == wanted.healer
        and current.dps == wanted.dps then
        return
    end
    local ok, err = pcall(api.SetRoles, wanted)
    if not ok then
        rolesFailed = true
        Log.debug("Group Finder roles not set: %s", tostring(err))
        return
    end
    local _, after = pcall(api.GetRoles)
    Log.debug("Group Finder roles set to %s; it now has tank %s, healer %s, DPS %s", roles,
        tostring(type(after) == "table" and after.tank), tostring(type(after) == "table" and after.healer),
        tostring(type(after) == "table" and after.dps))
end

-- Takes each dungeon's level range from WoW's own Group Finder (the
-- suggested levels of its activity); the built-in ranges are a fallback.
function LfgList.loadLevelRanges()
    local loaded = 0
    local english = string.find(ns.Locale.code(), "^en") ~= nil
    for _, dungeon in ipairs(Dungeons.list) do
        local info = dungeon.lfg and call("GetActivityInfoTable", dungeon.lfg)
        if type(info) == "table" then
            local name = info.fullName or info.shortName
            if not english and type(name) == "string" and name ~= "" and not isSecret(name) then
                Dungeons.localNames[dungeon.id] = name
            end
            local min = tonumber(info.minLevelSuggestion) or 0
            local max = tonumber(info.maxLevelSuggestion) or 0
            if min <= 0 then
                min, max = tonumber(info.minLevel) or 0, tonumber(info.maxLevel) or 0
            end
            if Dungeons.setRange(dungeon.id, min, max) then
                loaded = loaded + 1
            end
        end
    end
    Log.debug("level ranges from the Group Finder: %d of %d dungeons", loaded, #Dungeons.list)
end

function LfgList.init()
    ns.on("LFG_LIST_SEARCH_RESULTS_RECEIVED", LfgList.refresh)
    ns.on("LFG_LIST_SEARCH_RESULT_UPDATED", onResultUpdated)
    ns.on("LFG_LIST_AVAILABILITY_UPDATE", function()
        if next(activityByZone) == nil then
            LfgList.loadZones()
        end
    end)
    ns.on("LFG_LIST_SEARCH_FAILED", function(reason)
        failedAt = GetTime()
        expireOpen()
        -- A refusal comes at once, so it is for the newest search; refused
        -- tries don't count against the server's limit.
        local record = table.remove(open)
        for i = #sentAt, 1, -1 do
            if record and sentAt[i] == record.at then
                table.remove(sentAt, i)
                break
            end
        end
        Log.debug("group finder search failed: %s (%s)", tostring(reason),
            record and (record.mine and "ours" or "another addon's") or "a search not seen")
        if record and record.mine then
            ownFailedAt = failedAt
            undoOwn(record, true)
        end
    end)
end

-- The player changed the languages they group with. Answers to searches
-- sent before no longer count as fresh. A language taken off: its groups
-- may be in the lists, which can't tell a listing's language, so the lists
-- go and the next input searches again. A language added: the lists are
-- still right, only incomplete, so they stay; the next input searches again
-- and an ask waits for that search before giving up on finding a group.
function LfgList.languagesChanged(removed)
    generation = generation + 1
    languagesChangedAt = GetTime()
    searchedAt, zoneSearchedAt, battlegroundsSearchedAt, anySearchAt = -math.huge, -math.huge, -math.huge, -math.huge
    if removed then
        listings, zoneListings, battlegroundListings = {}, {}, {}
        updatedAt, zoneUpdatedAt, battlegroundsUpdatedAt = nil, nil, nil
        searchedActivities, resultZones = {}, {}
        lastPart, lastDungeonSearch, retryPart, failures = nil, nil, nil, 0
        totalResults = 0
        resultSet = { ids = {}, newOk = false }
    end
    version = version + 1
    Log.debug("group finder: languages %s; searching again on the next input%s", removed and "taken off" or "added",
        removed and ", the listings found before are dropped" or "")
    notify()
end

function LfgList.languagesChangedAt()
    return languagesChangedAt
end

-- Every search and clear goes through these hooks, whichever addon calls
-- them. Installed when this file loads, before addons that load later keep
-- their own reference to the function. A hook never lets an error out:
-- that would land in the caller's search, Blizzard's window included.
if type(hooksecurefunc) == "function" and type(C_LFGList) == "table" then
    if type(C_LFGList.Search) == "function" then
        pcall(hooksecurefunc, C_LFGList, "Search", function(...)
            local ok, err = pcall(onSearch, ...)
            if not ok then
                Log.debug("group finder: noting a search failed: %s", tostring(err))
            end
        end)
    end
    if type(C_LFGList.ClearSearchResults) == "function" then
        pcall(hooksecurefunc, C_LFGList, "ClearSearchResults", function()
            pcall(onClear)
        end)
    end
end

ns.LfgList = LfgList
