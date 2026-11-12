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
local SEARCH_TIMEOUT = 15
local EXPECTED = { T = 1, H = 1, D = 3 }
local ROLE_KEYS = { TANK = "T", HEALER = "H", DAMAGER = "D", DPS = "D" }

local listings = {}
local resultIds = {}
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
-- Each zone's level range as the Group Finder suggests it: name => { min, max }.
local zoneLevels = {}
local zoneUpdatedAt
local zoneSearchedAt = -math.huge
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

-- areasOf: dungeonsOf or zonesOf; the listing keeps them under `field`.
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
    return {
        id = id, name = name, leader = name, level = tonumber(leader.level), classToken = leader.classFilename,
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
    version = version + 1
    Log.debug("group finder zones: %d usable listings of %d results", #result, #ids)
    for _, listener in ipairs(listeners) do
        listener()
    end
end

local function kindOf(ids)
    local zones, dungeons = 0, 0
    for _, id in ipairs(ids) do
        local info = call("GetSearchResultInfo", id)
        local activities = type(info) == "table" and not isSecret(info.activityIDs) and info.activityIDs
        for _, activity in ipairs(type(activities) == "table" and activities or {}) do
            if zoneByActivity[activity] then
                zones = zones + 1
            elseif Dungeons.byActivity[activity] then
                dungeons = dungeons + 1
            end
        end
    end
    if dungeons > 0 then
        return "dungeons"
    elseif zones > 0 then
        return "zones"
    end
    return lastKind
end

function LfgList.refresh()
    local _, ids = call("GetSearchResults")
    if type(ids) ~= "table" then
        return
    end
    if kindOf(ids) == "zones" then
        refreshZones(ids)
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
    listings = result
    version = version + 1
    resultIds = {}
    for _, id in ipairs(ids) do
        resultIds[id] = true
    end
    totalResults = #ids
    updatedAt = GetTime()
    Log.debug("group finder: %d usable listings of %d results", #result, #ids)
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
    if lastKind == "zones" then
        return
    end
    local ok, fresh = pcall(readResult, id)
    fresh = ok and fresh or nil
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

-- The Group Finder activities to search for: the dungeon(s) being filled,
-- else the queue entry's, else the ones ticked in the window.
local function wantedActivities()
    local ids = ns.Filler and ns.Filler.dungeonIds() or nil
    if not ids or #ids == 0 then
        local entry = ns.engine and ns.engine.myEntry
        ids = entry and entry.dungeons or (ns.Window and ns.Window.selectedDungeonIds()) or {}
    end
    local activities = {}
    for _, id in ipairs(ids) do
        local dungeon = Dungeons.get(id)
        if dungeon and dungeon.lfg then
            activities[#activities + 1] = dungeon.lfg
        end
    end
    return activities
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

-- Only from a click or key press; returns false if WoW refused. Searches only
-- for the wanted dungeons (WoW returns at most 100 results per search, so an
-- unfiltered search can miss them at busy times).
function LfgList.search()
    local fn = C_LFGList and C_LFGList.Search
    if type(fn) ~= "function" or not ns.Features.groupFinder() then
        return false
    end
    searchedAt, anySearchAt = GetTime(), GetTime()
    lastKind = "dungeons"
    local activities = wantedActivities()
    local ok, err
    if #activities > 0 then
        ok, err = pcall(fn, CATEGORY_DUNGEONS, 0, 0, languageFilter(), false, nil, activities)
    end
    if not ok then
        if err then
            Log.debug("filtered group finder search failed (%s); searching everything", tostring(err))
        end
        ok, err = pcall(fn, CATEGORY_DUNGEONS)
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
    if type(fn) ~= "function" or #activities == 0 or not ns.Features.groupFinder() then
        return false
    end
    zoneSearchedAt, anySearchAt = GetTime(), GetTime()
    lastKind = "zones"
    local ok, err = pcall(fn, zoneCategory, 0, 0, languageFilter(), false, nil, activities)
    if not ok then
        Log.debug("zone search failed: %s", tostring(err))
    end
    return ok
end

function LfgList.zoneListings()
    return zoneListings, zoneUpdatedAt
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

-- Takes each dungeon's level range from WoW's own Group Finder (the
-- suggested levels of its activity); the built-in ranges are a fallback.
function LfgList.loadLevelRanges()
    local loaded = 0
    for _, dungeon in ipairs(Dungeons.list) do
        local info = dungeon.lfg and call("GetActivityInfoTable", dungeon.lfg)
        if type(info) == "table" then
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
        Log.debug("group finder search failed: %s", tostring(reason))
    end)
end

ns.LfgList = LfgList
