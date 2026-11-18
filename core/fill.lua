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

-- With `steps` (zones between the player and the dungeon, wow/zonemap.lua)
-- whoever is closest to the dungeon comes first; then players who can play
-- only the open role, so flexible players stay available for scarcer roles;
-- then, with `near` (the group's level), whoever is closest to it; then
-- whoever has been listed longest.
local function distance(listing, near)
    return listing.level and math.abs(listing.level - near) or math.huge
end

local function zoneSteps(listing, opts)
    return opts.steps and opts.steps(listing, opts.dungeon) or math.huge
end

local function better(a, b, opts)
    local near = opts.near
    if opts.steps and zoneSteps(a, opts) ~= zoneSteps(b, opts) then
        return zoneSteps(a, opts) < zoneSteps(b, opts)
    end
    if #a.roles ~= #b.roles then
        return #a.roles < #b.roles
    end
    if near and distance(a, near) ~= distance(b, near) then
        return distance(a, near) < distance(b, near)
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

-- While a group should get varied classes (wow/filler.lua): at most this
-- many of one class, and never two of one class in the same role.
local MAX_OF_CLASS = 2

-- avoid: the group's classes, { [class] = { count, roles = { [role] = true } } };
-- picked: the same for the picks so far. A player whose class is not known
-- is not held back.
function Fill.avoided(avoid, picked, class, role)
    if not avoid or not class then
        return false
    end
    local had, new = avoid[class], picked[class]
    local count = (had and had.count or 0) + (new and new.count or 0)
    local sameRole = (had and had.roles[role]) or (new and new.roles[role])
    return count >= MAX_OF_CLASS or sameRole == true
end

local function addClass(set, class, role)
    local entry = set[class] or { count = 0, roles = {} }
    entry.count = entry.count + 1
    if role then
        entry.roles[role] = true
    end
    set[class] = entry
end
Fill.addClass = addClass

local function pickInOrder(listings, opts, order)
    local exclude = opts.exclude or {}
    local taken, picks, open, picked = {}, {}, {}, {}
    local counts = Roles.countLetters(opts.missing) or { T = 0, H = 0, D = 0 }
    local places = opts.places
    for _, role in ipairs(order) do
        for _ = 1, counts[role] do
            local best
            for _, listing in ipairs(listings) do
                if listing.solo and not exclude[listing.name] and not taken[listing.name]
                    and Roles.has(listing.roles, role) and lists(listing, opts.dungeon)
                    and levelFits(listing, opts.range) and limitFits(listing, opts.levels)
                    and not (opts.held and opts.held(listing, opts.dungeon))
                    and (not best or better(listing, best, opts))
                    and fitsWith(places, picks, role, listing.classToken)
                    and not Fill.avoided(opts.avoid, picked, listing.classToken, role) then
                    best = listing
                end
            end
            if best then
                taken[best.name] = true
                picks[#picks + 1] = { name = best.name, role = role, class = best.classToken }
                if best.classToken then
                    addClass(picked, best.classToken, role)
                end
            else
                open[role] = (open[role] or 0) + 1
            end
        end
    end
    return picks, Roles.fromCounts({ T = open.T or 0, H = open.H or 0, D = open.D or 0 })
end

-- A copy of opts whose steps and held ask once per listing (Fill.pick tries
-- every role order, and they look up zones).
local function remembered(opts)
    local copy = { remembered = true }
    for key, value in pairs(opts) do
        copy[key] = value
    end
    for _, key in ipairs({ "steps", "held" }) do
        local ask = opts[key]
        if ask then
            local answers = {}
            copy[key] = function(listing, dungeon)
                if answers[listing] == nil then
                    answers[listing] = { ask(listing, dungeon) }
                end
                return answers[listing][1]
            end
        end
    end
    return copy
end

-- opts: missing ("HDD"), dungeon (our id), exclude (set of names),
-- range ({ min, max } for the dungeon, optional), places (class wishes,
-- optional), levels (a leader's level limit, optional), avoid (the group's
-- classes while it should get varied ones, optional; Fill.avoided), prefer
-- (the same, as a preference: the roles nobody of another class can fill go
-- to anyone who fits; never with class wishes, `places`), steps
-- (function(listing, dungeon) -> zones away, or nil when not known; the
-- closest first), held (function(listing, dungeon) -> true while a player
-- further away still waits for someone closer).
-- Returns picks { { name, role } } and the roles still open ("D").
-- Roles are tried in every order and the order that fills the most roles
-- wins, so a flexible player is not spent on a role someone else could take.
function Fill.pick(listings, opts)
    if not opts.remembered then
        opts = remembered(opts)
    end
    if opts.prefer and not opts.avoid then
        local varied = {}
        for key, value in pairs(opts) do
            varied[key] = value
        end
        varied.avoid, varied.prefer = opts.prefer, nil
        local picks, open = Fill.pick(listings, varied)
        if open == "" then
            return picks, open
        end
        local rest, exclude = {}, {}
        for key, value in pairs(opts) do
            rest[key] = value
        end
        for name in pairs(opts.exclude or {}) do
            exclude[name] = true
        end
        for _, pick in ipairs(picks) do
            exclude[pick.name] = true
        end
        rest.missing, rest.exclude, rest.prefer = open, exclude, nil
        local more, still = Fill.pick(listings, rest)
        for _, pick in ipairs(more) do
            picks[#picks + 1] = pick
        end
        return picks, still
    end
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
-- exclude, levels, places, avoid, held. Returns { listed, excluded, level,
-- limit, class, variety, held }
-- (a player counts for the first reason only).
function Fill.skipped(listings, opts, role)
    local why = { listed = 0, excluded = 0, level = 0, limit = 0, class = 0, variety = 0, held = 0 }
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
            elseif Fill.avoided(opts.avoid, {}, listing.classToken, role) then
                why.variety = why.variety + 1
            elseif opts.held and opts.held(listing, dungeon) then
                why.held = why.held + 1
            end
        end
    end
    return why
end

-- How well a dungeon suits a group, from who is available now (places: how
-- many were open): the tank and
-- healer places nobody can fill (open: the roles left open, "HD"), then all
-- places nobody can fill, then the zones between the dungeon and the group's
-- furthest player (math.huge when nobody's zone is known), then how far the
-- group's levels are from the middle of the dungeon's level range, on
-- average. opts: steps (the group's furthest member now, or nil), levels
-- ({ level, ... } of the group now), range ({ min, max }, optional); picks:
-- the players it would invite, { level, steps } each.
function Fill.score(open, picks, opts)
    local scarce = select(2, string.gsub(open, "[TH]", ""))
    local steps = opts.steps
    local levels = {}
    for _, level in ipairs(opts.levels or {}) do
        levels[#levels + 1] = level
    end
    for _, pick in ipairs(picks) do
        if pick.steps then
            steps = math.max(steps or 0, pick.steps)
        end
        levels[#levels + 1] = pick.level
    end
    local apart = 0
    local range = opts.range
    if range and #levels > 0 then
        local middle = (range.min + range.max) / 2
        for _, level in ipairs(levels) do
            apart = apart + math.abs(level - middle)
        end
        apart = apart / #levels
    end
    return { scarce = scarce, open = #open, steps = steps or math.huge, apart = apart, places = #open + #picks }
end

-- Whether score a suits the group better than b (Fill.score).
function Fill.better(a, b)
    for _, key in ipairs({ "scarce", "open", "steps", "apart" }) do
        if a[key] ~= b[key] then
            return a[key] < b[key]
        end
    end
    return false
end

-- For a group that may go to several dungeons: the dungeon that suits it
-- best with the players available now (Fill.score; the first one on a tie).
-- opts: missing, dungeons ({ ids }), exclude, ranges ({ [id] = { min, max } }),
-- groupSteps (function(dungeon) -> zones to the group's furthest member now,
-- or nil), groupLevels ({ level, ... }). Returns { dungeon, picks, open, score }.
function Fill.plan(listings, opts)
    local best, byName = nil, {}
    for _, listing in ipairs(listings) do
        byName[listing.name] = listing
    end
    for _, dungeon in ipairs(opts.dungeons) do
        local range = opts.ranges and opts.ranges[dungeon]
        local picks, open = Fill.pick(listings, {
            missing = opts.missing, dungeon = dungeon, exclude = opts.exclude,
            range = range, places = opts.places, levels = opts.levels,
            avoid = opts.avoid, prefer = opts.prefer, near = opts.near, steps = opts.steps, held = opts.held,
        })
        local invited = {}
        for i, pick in ipairs(picks) do
            local listing = byName[pick.name]
            invited[i] = { level = listing.level, steps = opts.steps and opts.steps(listing, dungeon) or nil }
        end
        local score = Fill.score(open, invited, {
            steps = opts.groupSteps and opts.groupSteps(dungeon), levels = opts.groupLevels, range = range,
        })
        if not best or Fill.better(score, best.score) then
            best = { dungeon = dungeon, picks = picks, open = open, score = score }
        end
    end
    return best
end

ns.Fill = Fill
return Fill
