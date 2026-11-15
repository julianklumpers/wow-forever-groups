local _, ns = ...
ns = ns or {}

local Roles = ns.Roles or require("core.roles")
local Compose = ns.Compose or require("core.compose")
local Levels = ns.Levels or require("core.levels")

-- Picks players from WoW's Group Finder listings for a group's open roles.
-- A listing: { name, level, roles = "TD", dungeons = { "5", ... }, age, solo }.
local Fill = {}

local function lists(listing, dungeon)
    for _, id in ipairs(listing.dungeons) do
        if id == dungeon then
            return true
        end
    end
    return false
end

local function levelFits(listing, range)
    return not range or not listing.level or (listing.level >= range.min and listing.level <= range.max)
end

-- A leader's level limit (core/levels.lua): an unknown level does not fit.
local function limitFits(listing, limit)
    return not limit or Levels.fits(limit, listing.level)
end

-- Players who can play only the open role come first, so flexible players
-- stay available for scarcer roles; then whoever has been listed longest.
local function better(a, b)
    if #a.roles ~= #b.roles then
        return #a.roles < #b.roles
    end
    if (a.age or 0) ~= (b.age or 0) then
        return (a.age or 0) > (b.age or 0)
    end
    return a.name < b.name
end

local ROLE_ORDERS = {
    { "T", "H", "D" }, { "T", "D", "H" }, { "H", "T", "D" }, { "H", "D", "T" }, { "D", "T", "H" }, { "D", "H", "T" },
}

-- places: the group's free places with a leader's class wishes ({ role,
-- mask }, core/compose.lua), or nil. A player is taken when everyone picked so
-- far and they still all fit those places (Compose.fitsPlaces), without
-- deciding a place for anyone yet: a Mage picked after a Rogue still gets the
-- Mage place the Rogue could also have taken.
local function fitsWith(places, picks, role, class)
    if not places then
        return true
    end
    local members = { { role = role, class = class } }
    for _, pick in ipairs(picks) do
        members[#members + 1] = { role = pick.role, class = pick.class }
    end
    return Compose.fitsPlaces(places, members)
end

local function pickInOrder(listings, opts, order)
    local exclude = opts.exclude or {}
    local taken, picks, open = {}, {}, {}
    local counts = Roles.countLetters(opts.missing) or { T = 0, H = 0, D = 0 }
    local places = opts.places
    for _, role in ipairs(order) do
        for _ = 1, counts[role] do
            local best
            for _, listing in ipairs(listings) do
                if listing.solo and not exclude[listing.name] and not taken[listing.name]
                    and Roles.has(listing.roles, role) and lists(listing, opts.dungeon)
                    and levelFits(listing, opts.range) and limitFits(listing, opts.levels)
                    and (not best or better(listing, best)) and fitsWith(places, picks, role, listing.classToken) then
                    best = listing
                end
            end
            if best then
                taken[best.name] = true
                picks[#picks + 1] = { name = best.name, role = role, class = best.classToken }
            else
                open[role] = (open[role] or 0) + 1
            end
        end
    end
    return picks, Roles.fromCounts({ T = open.T or 0, H = open.H or 0, D = open.D or 0 })
end

-- opts: missing ("HDD"), dungeon (our id), exclude (set of names),
-- range ({ min, max } for the dungeon, optional), places (class wishes,
-- optional), levels (a leader's level limit, optional).
-- Returns picks { { name, role } } and the roles still open ("D").
-- Roles are tried in every order and the order that fills the most roles
-- wins, so a flexible player is not spent on a role someone else could take.
function Fill.pick(listings, opts)
    local bestPicks, bestOpen
    for _, order in ipairs(ROLE_ORDERS) do
        local picks, open = pickInOrder(listings, opts, order)
        if not bestPicks or #open < #bestOpen then
            bestPicks, bestOpen = picks, open
        end
    end
    return bestPicks, bestOpen
end

-- Why the solo players listed in a role for one of the dungeons were not
-- picked, for the log. opts: dungeons ({ ids }), ranges ({ [id] = range }),
-- exclude, levels, places. Returns { listed, excluded, level, limit, class }
-- (a player counts for the first reason only).
function Fill.skipped(listings, opts, role)
    local why = { listed = 0, excluded = 0, level = 0, limit = 0, class = 0 }
    local exclude = opts.exclude or {}
    local ranges = opts.ranges or {}
    for _, listing in ipairs(listings) do
        local dungeon, inRange
        for _, id in ipairs(opts.dungeons) do
            if lists(listing, id) then
                dungeon = dungeon or id
                inRange = inRange or levelFits(listing, ranges[id])
            end
        end
        if listing.solo and dungeon and Roles.has(listing.roles, role) then
            why.listed = why.listed + 1
            if exclude[listing.name] then
                why.excluded = why.excluded + 1
            elseif not inRange then
                why.level = why.level + 1
            elseif not limitFits(listing, opts.levels) then
                why.limit = why.limit + 1
            elseif not fitsWith(opts.places, {}, role, listing.classToken) then
                why.class = why.class + 1
            end
        end
    end
    return why
end

-- For a group that may go to several dungeons: the dungeon whose listings
-- fill the most open roles (the first one on a tie).
-- opts: missing, dungeons ({ ids }), exclude, ranges ({ [id] = { min, max } }).
function Fill.plan(listings, opts)
    local best
    for _, dungeon in ipairs(opts.dungeons) do
        local picks, open = Fill.pick(listings, {
            missing = opts.missing, dungeon = dungeon, exclude = opts.exclude,
            range = opts.ranges and opts.ranges[dungeon], places = opts.places, levels = opts.levels,
        })
        if not best or #picks > #best.picks then
            best = { dungeon = dungeon, picks = picks, open = open }
        end
    end
    return best
end

ns.Fill = Fill
return Fill
