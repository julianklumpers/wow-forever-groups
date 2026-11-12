local _, ns = ...
ns = ns or {}

local Roles = ns.Roles or require("core.roles")

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

local function pickInOrder(listings, opts, order)
    local exclude = opts.exclude or {}
    local taken, picks, open = {}, {}, {}
    local counts = Roles.countLetters(opts.missing) or { T = 0, H = 0, D = 0 }
    for _, role in ipairs(order) do
        for _ = 1, counts[role] do
            local best
            for _, listing in ipairs(listings) do
                if listing.solo and not exclude[listing.name] and not taken[listing.name]
                    and Roles.has(listing.roles, role) and lists(listing, opts.dungeon)
                    and levelFits(listing, opts.range) and (not best or better(listing, best)) then
                    best = listing
                end
            end
            if best then
                taken[best.name] = true
                picks[#picks + 1] = { name = best.name, role = role }
            else
                open[role] = (open[role] or 0) + 1
            end
        end
    end
    return picks, Roles.fromCounts({ T = open.T or 0, H = open.H or 0, D = open.D or 0 })
end

-- opts: missing ("HDD"), dungeon (our id), exclude (set of names),
-- range ({ min, max } for the dungeon, optional).
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

-- For a group that may go to several dungeons: the dungeon whose listings
-- fill the most open roles (the first one on a tie).
-- opts: missing, dungeons ({ ids }), exclude, ranges ({ [id] = { min, max } }).
function Fill.plan(listings, opts)
    local best
    for _, dungeon in ipairs(opts.dungeons) do
        local picks, open = Fill.pick(listings, {
            missing = opts.missing, dungeon = dungeon, exclude = opts.exclude,
            range = opts.ranges and opts.ranges[dungeon],
        })
        if not best or #picks > #best.picks then
            best = { dungeon = dungeon, picks = picks, open = open }
        end
    end
    return best
end

ns.Fill = Fill
return Fill
