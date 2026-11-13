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
local ROLE_KEYS = { TANK = "T", HEALER = "H", DAMAGER = "D", DPS = "D" }

local listings = {}
local resultIds = {}
local coveredActivities
local KEEP_LISTINGS = 120
-- The dungeon search on its way, to undo when the server refuses it, and the
-- part to search again after a refusal.
local pending
local retryPart
local failures = 0
local totalResults = 0
local updatedAt
local searchedAt = -math.huge
local failedAt = -math.huge
local listeners = {}
local loggedRoleKeys = false
-- Results go to the dungeon or the zone cache, so a zone search never
-- replaces the dungeon listings. Which one is told by the results' activities
-- (searches from Blizzard's own window included); an empty result goes by
-- the kind of our last search.
local lastKind = "dungeons"
local anySearchAt = -math.huge
-- Goes up whenever the cached listings change.
local version = 0
local zoneCategory = CATEGORY_ZONES
local zoneByActivity, activityByZone = {}, {}
local zoneListings = {}
-- The zones of the last zone search, and of the results we have.
local searchingZones, resultZones = {}, {}
-- Each zone's level range as the Group Finder suggests it: name => { min, max }.
local zoneLevels = {}
local zoneUpdatedAt
local zoneSearchedAt = -math.huge
local battlegroundListings = {}
local battlegroundsUpdatedAt
local battlegroundsSearchedAt = -math.huge
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

local function battlegroundsOf(info)
    local ids = {}
    for _, activity in ipairs(info.activityIDs or { info.activityID }) do
        local battleground = ns.Battlegrounds.byActivity[activity]
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
        remaining = remaining, playstyle = ns.Playstyle.fromWoW(info.generalPlaystyle),
    }
end

-- During a boss fight the results are secret: such a result says nothing
-- about the listing, so what was read before stays.
local function unreadable(id)
    local info = call("GetSearchResultInfo", id)
    return type(info) == "table" and (isSecret(info.numMembers) or isSecret(info.leaderName))
end

local function refreshZones(ids)
    local result, secret = {}, 0
    for _, id in ipairs(ids) do
        local ok, listing = pcall(readResult, id, zonesOf, "zones")
        if ok and listing then
            result[#result + 1] = listing
        elseif unreadable(id) then
            secret = secret + 1
        end
    end
    if #result == 0 and secret > 0 then
        return
    end
    zoneListings = result
    zoneUpdatedAt = GetTime()
    resultZones = searchingZones
    version = version + 1
    Log.debug("group finder zones: %d usable listings of %d results", #result, #ids)
    for _, listener in ipairs(listeners) do
        listener()
    end
end

-- A battleground listing's open places: the battleground's size less its
-- members (roles hardly matter there).
local function refreshBattlegrounds(ids)
    local result, secret = {}, 0
    for _, id in ipairs(ids) do
        local ok, listing = pcall(readResult, id, battlegroundsOf, "battlegrounds")
        if ok and listing then
            local battleground = ns.Battlegrounds.get(listing.battlegrounds[1])
            listing.remaining = nil
            listing.open = math.max(0, (battleground and battleground.size or 10) - listing.members)
            result[#result + 1] = listing
        elseif unreadable(id) then
            secret = secret + 1
        end
    end
    if #result == 0 and secret > 0 then
        return
    end
    battlegroundListings = result
    battlegroundsUpdatedAt = GetTime()
    version = version + 1
    Log.debug("group finder battlegrounds: %d usable listings of %d results", #result, #ids)
    for _, listener in ipairs(listeners) do
        listener()
    end
end

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
            elseif ns.Battlegrounds.byActivity[activity] then
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
    return lastKind
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

function LfgList.refresh()
    local found, ids = call("GetSearchResults")
    if lastKind ~= "dungeons" then
        coveredActivities = nil
    end
    if type(ids) ~= "table" then
        return
    end
    local kind = kindOf(ids)
    if kind == "zones" then
        refreshZones(ids)
        return
    elseif kind == "battlegrounds" then
        refreshBattlegrounds(ids)
        return
    end
    local result, secret = {}, 0
    for _, id in ipairs(ids) do
        local ok, listing = pcall(readResult, id)
        if ok and listing then
            result[#result + 1] = listing
        elseif unreadable(id) then
            secret = secret + 1
        end
    end
    if #result == 0 and secret > 0 then
        Log.debug("group finder: %d results unreadable right now; keeping the last ones", secret)
        return
    end
    -- Our searches cover part of the dungeons; the other part's listings
    -- stay (a search from Blizzard's window replaces them all). A listing
    -- for dungeons of both parts comes back in each search under a new id:
    -- one per leader, the newest.
    -- They are kept for KEEP_LISTINGS s, not forever: the other part may not
    -- be searched again (once queued, only the queued dungeons are).
    local covered = coveredActivities
    local now = GetTime()
    for _, listing in ipairs(result) do
        listing.seenAt = now
    end
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
    pending, retryPart, failures = nil, nil, 0
    version = version + 1
    resultIds = {}
    for _, id in ipairs(ids) do
        resultIds[id] = true
    end
    totalResults = #ids
    updatedAt = GetTime()
    Log.debug("group finder: %d results (%s found), %d listings kept, %.1f s after the search", #ids,
        tostring(found), #listings, updatedAt - searchedAt)
    for _, listener in ipairs(listeners) do
        listener()
    end
end

-- WoW reports a change to one result between searches: someone delisted or
-- formed a group, or a leader's name arrived after the results did. Drop,
-- update or add just that listing.
local function onResultUpdated(id)
    if unreadable(id) then
        return
    end
    version = version + 1
    for i, listing in ipairs(zoneListings) do
        if listing.id == id then
            local ok, fresh = pcall(readResult, id, zonesOf, "zones")
            if ok and fresh then
                zoneListings[i] = fresh
            else
                table.remove(zoneListings, i)
            end
            return
        end
    end
    for i, listing in ipairs(battlegroundListings) do
        if listing.id == id then
            local ok, fresh = pcall(readResult, id, battlegroundsOf, "battlegrounds")
            if ok and fresh then
                fresh.remaining, fresh.open = nil, math.max(0, listing.open + listing.members - fresh.members)
                battlegroundListings[i] = fresh
            else
                table.remove(battlegroundListings, i)
            end
            return
        end
    end
    if lastKind == "zones" or lastKind == "battlegrounds" then
        return
    end
    local ok, fresh = pcall(readResult, id)
    fresh = ok and fresh or nil
    if fresh then
        fresh.seenAt = GetTime()
    end
    for i, listing in ipairs(listings) do
        if listing.id == id then
            if fresh then
                listings[i] = fresh
            else
                table.remove(listings, i)
                Log.debug("group finder: %s is no longer listed", listing.name)
            end
            return
        end
    end
    if fresh and resultIds[id] then
        listings[#listings + 1] = fresh
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
    for _, dungeon in ipairs(Dungeons.forLevel(UnitLevel("player"))) do
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

-- Without a language filter the server only returns listings in the
-- player's own language; more players means groups form sooner.
local function languageFilter()
    if ns.db.ownLanguageOnly then
        return nil
    end
    local offered = call("GetAvailableLanguageSearchFilter")
    if type(offered) ~= "table" or #offered == 0 then
        return nil
    end
    local filter = {}
    for _, code in ipairs(offered) do
        if type(code) == "string" then
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

-- The server allows about two searches (of any kind) per five seconds and
-- refuses a third as "throttled"; refused tries don't count (/fgp lfgapi gap).
-- So the rest follows a main search quickly, a search waits while two went
-- out in the last BURST_WINDOW s, and a refused one is tried again on input
-- at least RETRY_GAP s later, at most MAX_RETRIES times in a row.
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
    return #recent < BURST and now - failedAt >= RETRY_GAP
end

local function noteSearch()
    sentAt[#sentAt + 1] = GetTime()
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
    pending = { part = part, lastPart = lastPart, covered = coveredActivities, searchedAt = searchedAt,
        anySearchAt = anySearchAt, new = {} }
    for _, activity in ipairs(activities) do
        if not searchedActivities[activity] then
            pending.new[#pending.new + 1] = activity
        end
    end
    anySearchAt = GetTime()
    if part ~= "rest" then
        searchedAt = GetTime()
    end
    lastKind = "dungeons"
    local ok, err
    if #activities > 0 then
        local filter = part ~= "rest" and roleFilter(activities) or nil
        ok, err = pcall(fn, CATEGORY_DUNGEONS, 0, 0, languageFilter(), false, filter, activities)
        noteSearch()
        if not ok and filter then
            Log.debug("group finder search with a role filter failed (%s); without it", tostring(err))
            ok, err = pcall(fn, CATEGORY_DUNGEONS, 0, 0, languageFilter(), false, nil, activities)
        end
        Log.debug("group finder: searching %d dungeons (%s%s)", #activities, part, filter and ", role filter" or "")
        coveredActivities = {}
        for _, activity in ipairs(activities) do
            searchedActivities[activity] = true
            coveredActivities[activity] = true
        end
        lastPart = part
    end
    if not ok then
        if err then
            Log.debug("filtered group finder search failed (%s); searching everything", tostring(err))
        end
        ok, err = pcall(fn, CATEGORY_DUNGEONS)
        noteSearch()
        -- Capped at 100 results: no dungeon counts as covered.
        searchedActivities, coveredActivities = {}, nil
    end
    if not ok then
        Log.debug("group finder search failed: %s", tostring(err))
    end
    return ok
end

-- Searches the "Quests & Zones" category for these zone names; only from a
-- click or key press.
function LfgList.searchZones(zones)
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
    zoneSearchedAt, anySearchAt = GetTime(), GetTime()
    lastKind = "zones"
    pending = nil
    searchingZones = {}
    for _, zone in ipairs(zones) do
        searchingZones[zone] = true
    end
    local ok, err = pcall(fn, zoneCategory, 0, 0, languageFilter(), false, nil, activities)
    noteSearch()
    if not ok then
        Log.debug("zone search failed: %s", tostring(err))
    end
    return ok
end

-- Only from a click or key press, like LfgList.search.
function LfgList.searchBattlegrounds()
    local fn = C_LFGList and C_LFGList.Search
    if type(fn) ~= "function" or not ns.Features.groupFinder() or not roomToSearch() then
        return false
    end
    local activities = {}
    for _, battleground in ipairs(ns.Battlegrounds.list) do
        activities[#activities + 1] = battleground.lfg
    end
    battlegroundsSearchedAt, anySearchAt = GetTime(), GetTime()
    lastKind = "battlegrounds"
    pending = nil
    local ok, err = pcall(fn, CATEGORY_BATTLEGROUNDS, 0, 0, languageFilter(), false, nil, activities)
    noteSearch()
    if not ok then
        Log.debug("battleground search failed: %s", tostring(err))
    end
    return ok
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
    return searchedAt > (updatedAt or -math.huge) and searchedAt > failedAt
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
        sentAt[#sentAt] = nil
        Log.debug("group finder search failed: %s", tostring(reason))
        local undo = lastKind == "dungeons" and pending
        pending = nil
        if not undo then
            return
        end
        -- Not searched after all: its part keeps its turn and goes again on
        -- input a little later.
        for _, activity in ipairs(undo.new) do
            searchedActivities[activity] = nil
        end
        coveredActivities, lastPart = undo.covered, undo.lastPart
        searchedAt, anySearchAt = undo.searchedAt, undo.anySearchAt
        failures = failures + 1
        retryPart = failures < MAX_RETRIES and (undo.part == "rest" and "rest" or "main") or nil
    end)
end

ns.LfgList = LfgList
