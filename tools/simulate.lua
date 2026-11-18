-- Simulates the dungeon queue outside the game to compare matchmaking
-- variants, second by second: Forever Groups players arrive and others see
-- their entry 1-2 s later (the channel), the real matchmaker
-- (core/matchmaker.lua) runs every MATCH_INTERVAL at a moment of its own, and
-- a player without a group invites simulated Group Finder listings with the
-- real picking (core/fill.lua). A player with a possible Forever Groups
-- partner waits `grace` seconds first (one matchmaking round, wow/autofill.lua);
-- with `hold` a group that builds leaves a role a queued Forever Groups player
-- can play to them for `holdFor` seconds (one round, wow/filler.lua); one who invited
-- anyone counts as a party (its invites are reserved roles), two parties
-- never merge, and one whose invites fill the group leaves the matchmaker
-- until a place opens again (wow/main.lua). Every variant replays the same arrivals and the same
-- answers to invites, so the differences come from the variant alone.
--
-- Usage: .lua51/bin/lua tools/simulate.lua [scenario] [minutes] [seed] [runs] [set]
--   scenarios: quiet, normal, busy (see SCENARIOS); runs: seeds to average
--   over (default 5); set: which variants (VARIANT_SETS, default "main").
--
-- As in the addon, a group that fills from the Group Finder stays in the
-- queue with the players it got from there as reserved roles, so later
-- Forever Groups players can still join it. Simplified on purpose (see
-- ASSUMPTIONS): no levels, playstyles, languages or class wishes; a lone
-- player builds at once (no asking listed groups first); open invites are
-- dropped when the group takes Forever Groups players; a proposal is
-- accepted PROPOSAL_DELAY after it is made.
package.path = "./?.lua;" .. package.path

local Matchmaker = require("core.matchmaker")
local Fill = require("core.fill")
local Roles = require("core.roles")
local Classes = require("core.classes")
local Config = require("core.config")

local Sim = {}

local SLOTS = Config.SLOTS
local ROUND = Config.MATCH_INTERVAL
local PROPOSAL_DELAY = 10
local INVITE_TIMEOUT = 62
local PARTNER_GRACE = Config.MATCH_ROUND
-- With `hold` and no `holdFor`: how long a building group leaves a role to a
-- Forever Groups player in the queue who can play it.
local ADDON_GRACE = Config.MATCH_ROUND
-- A builder picks from the Group Finder this often (it resolves answers
-- every second).
local PICK_EVERY = 5
local DUNGEONS = { "A", "B", "C", "D", "E", "F" }
-- Each dungeon's levels; a player picks only dungeons their level fits, and
-- the Group Finder side invites only players within them.
local RANGES = {
    A = { min = 15, max = 21 }, B = { min = 17, max = 23 }, C = { min = 19, max = 25 },
    D = { min = 21, max = 27 }, E = { min = 23, max = 29 }, F = { min = 25, max = 31 },
}
local LOWEST, HIGHEST = 15, 31
local CLASSES = { "WARRIOR", "PALADIN", "DRUID", "SHAMAN", "PRIEST", "HUNTER", "ROGUE", "MAGE", "WARLOCK" }

Sim.ASSUMPTIONS = "6 dungeons (levels 15-31), 1-3 wanted each that fit the level; no playstyles, languages or "
    .. "class wishes; a lone player builds at once (no asking groups)"

Sim.SCENARIOS = {
    quiet = { queuePerMinute = 1, listedPerMinute = 4 },
    normal = { queuePerMinute = 3, listedPerMinute = 10 },
    busy = { queuePerMinute = 10, listedPerMinute = 25 },
}

-- Shared by every scenario: who arrives, and how listed players answer.
local QUEUE_ROLES = { { "D", 0.6 }, { "T", 0.1 }, { "H", 0.12 }, { "TD", 0.08 }, { "HD", 0.1 } }
local LISTED_ROLES = { { "D", 0.65 }, { "T", 0.1 }, { "H", 0.12 }, { "TD", 0.06 }, { "HD", 0.07 } }
local DUO_SHARE = 0.1
local ACCEPT_CHANCE = 0.6
local LISTED_MINUTES = 20

Sim.VARIANT_SETS = {
    main = {
        { name = "current", partial = true, variety = true, grace = PARTNER_GRACE, hold = true },
        { name = "no-partial", partial = false, variety = true, grace = PARTNER_GRACE, hold = true },
        { name = "no-variety", partial = true, variety = false, grace = PARTNER_GRACE, hold = true },
        { name = "no-grace", partial = true, variety = true, grace = 0, hold = true },
    },
    hold = {
        { name = "current", partial = true, variety = true, grace = PARTNER_GRACE, hold = true },
        { name = "hold 20", partial = true, variety = true, grace = PARTNER_GRACE, hold = true, holdFor = 20 },
        { name = "no-hold", partial = true, variety = true, grace = PARTNER_GRACE },
    },
    level = {
        { name = "current", partial = true, variety = true, grace = PARTNER_GRACE, hold = true },
        { name = "no-near", partial = true, variety = true, grace = PARTNER_GRACE, hold = true, near = false },
    },
    adaptive = {
        { name = "fixed 5m", partial = true, variety = true, grace = PARTNER_GRACE, hold = true },
        { name = "fixed 2m", partial = true, variety = true, grace = PARTNER_GRACE, hold = true, strict = 120 },
        { name = "fixed 1m", partial = true, variety = true, grace = PARTNER_GRACE, hold = true, strict = 60 },
        { name = "adaptive", partial = true, variety = true, grace = PARTNER_GRACE, hold = true, adaptive = true },
    },
    grace = {
        { name = "grace 20", partial = true, variety = true, grace = 20, hold = true },
        { name = "grace 15", partial = true, variety = true, grace = 15, hold = true },
        { name = "grace 10", partial = true, variety = true, grace = 10, hold = true },
        { name = "grace 8", partial = true, variety = true, grace = 8, hold = true },
        { name = "grace 5", partial = true, variety = true, grace = 5, hold = true },
        { name = "grace 0", partial = true, variety = true, grace = 0, hold = true },
    },
}
Sim.VARIANTS = Sim.VARIANT_SETS.main

-- The adaptive variant (Group Finder side only; the matchmaker keeps
-- Config.VARIETY_TIME): the strict time grows with the listed players
-- available (ADAPTIVE_STEP s each), between ADAPTIVE_MIN and the default.
-- Measured 2026-11-16: shorter strict times save at most ~30 s and give 2-3x
-- the groups with a class twice in one role, so the addon keeps 5 minutes.
local ADAPTIVE_STEP, ADAPTIVE_MIN = 15, 60
local VARIETY_DEFAULT = Config.VARIETY_TIME

local function adaptiveTime(candidates)
    return math.max(ADAPTIVE_MIN, math.min(VARIETY_DEFAULT, candidates * ADAPTIVE_STEP))
end

local function rng(seed)
    local state = seed
    return function()
        state = (state * 1103515245 + 12345) % 2147483648
        return state / 2147483648
    end
end

local function weighted(random, list)
    local roll, sum = random(), 0
    for _, item in ipairs(list) do
        sum = sum + item[2]
        if roll < sum then
            return item[1]
        end
    end
    return list[#list][1]
end

local function classFor(random, roles)
    local fitting = {}
    for _, class in ipairs(CLASSES) do
        if Classes.filter(roles, class) == roles then
            fitting[#fitting + 1] = class
        end
    end
    return fitting[1 + math.floor(random() * #fitting)]
end

local function someDungeons(random, level)
    local fitting = {}
    for _, dungeon in ipairs(DUNGEONS) do
        if level >= RANGES[dungeon].min and level <= RANGES[dungeon].max then
            fitting[#fitting + 1] = dungeon
        end
    end
    local count, list, seen = math.min(#fitting, 1 + math.floor(random() * 3)), {}, {}
    while #list < count do
        local dungeon = fitting[1 + math.floor(random() * #fitting)]
        if not seen[dungeon] then
            seen[dungeon] = true
            list[#list + 1] = dungeon
        end
    end
    table.sort(list)
    return list
end

local function someLevel(random)
    return LOWEST + math.floor(random() * (HIGHEST - LOWEST + 1))
end

local function arrivals(random, perMinute)
    local expected = perMinute / 60
    local count = math.floor(expected)
    if random() < expected - count then
        count = count + 1
    end
    return count
end

-- Everything that happens regardless of the variant, per second; and the
-- second within MATCH_INTERVAL the matchmaker runs at.
local function timeline(scenario, minutes, seed)
    local random = rng(seed)
    local ticks, queued, listed = { phase = math.floor(random() * ROUND) }, 0, 0
    for tick = 1, minutes * 60 do
        local at = tick
        local events = { queue = {}, listed = {} }
        for _ = 1, arrivals(random, scenario.queuePerMinute) do
            queued = queued + 1
            local members, level = {}, someLevel(random)
            for i = 1, random() < DUO_SHARE and 2 or 1 do
                local roles = weighted(random, QUEUE_ROLES)
                members[i] = { name = "Q" .. queued .. "-" .. i, roles = roles, class = classFor(random, roles),
                    level = math.min(HIGHEST, level + i - 1) }
            end
            if #Roles.options(members, SLOTS) == 0 then
                members[2] = nil
            end
            events.queue[#events.queue + 1] = { id = "Q" .. queued, joinedAt = at,
                dungeons = someDungeons(random, level), members = members,
                visibleAt = at + 1 + math.floor(random() * 2) }
        end
        for _ = 1, arrivals(random, scenario.listedPerMinute) do
            listed = listed + 1
            local roles, level = weighted(random, LISTED_ROLES), someLevel(random)
            events.listed[#events.listed + 1] = {
                name = "L" .. listed, roles = roles, classToken = classFor(random, roles),
                dungeons = someDungeons(random, level),
                solo = true, level = level, listedAt = at, leaveAt = at + random() * 2 * LISTED_MINUTES * 60,
                accepts = random() < ACCEPT_CHANCE, delay = 5 + random() * 15,
            }
        end
        ticks[tick] = events
    end
    return ticks, queued, listed
end

-- The open roles of a group whose players are these, leaving DPS open
-- rather than a tank or healer (as Filler.missingFor), with each player's role.
local function missingFor(members)
    local best
    for _, option in ipairs(Roles.options(members, SLOTS)) do
        local open = { T = SLOTS.T - option.counts.T, H = SLOTS.H - option.counts.H, D = SLOTS.D - option.counts.D }
        local score = open.T * 100 + open.H * 10 + open.D
        if not best or score < best.score then
            best = { score = score, letters = Roles.fromCounts(open), assignment = option.assignment }
        end
    end
    return best
end

local function removeLetter(letters, role)
    local at = string.find(letters, role, 1, true)
    return at and (string.sub(letters, 1, at - 1) .. string.sub(letters, at + 1)) or letters
end

local function percentile(sorted, share)
    if #sorted == 0 then
        return 0
    end
    return sorted[math.max(1, math.ceil(#sorted * share))]
end

local function groupQuality(members, stats)
    local perRole, perClass = {}, {}
    local sameRole, triple = false, false
    for _, member in ipairs(members) do
        local key = member.class .. ":" .. member.role
        perRole[key] = (perRole[key] or 0) + 1
        perClass[member.class] = (perClass[member.class] or 0) + 1
        sameRole = sameRole or perRole[key] > 1
        triple = triple or perClass[member.class] > 2
    end
    stats.sameRole = stats.sameRole + (sameRole and 1 or 0)
    stats.triple = stats.triple + (triple and 1 or 0)
end

-- The open roles once these players ({ role }) are in: "HDD".
local function openRoles(members)
    local counts = { T = SLOTS.T, H = SLOTS.H, D = SLOTS.D }
    for _, member in ipairs(members) do
        counts[member.role] = math.max(0, counts[member.role] - 1)
    end
    return Roles.fromCounts(counts)
end

function Sim.run(variant, ticks)
    -- queue: matchmaker entries; an entry that builds has `build` and its
    -- Group Finder players as `reserved` roles. pool: listed players free.
    local queue, pool, classOf, levelOf = {}, {}, {}, {}
    local stats = { groups = 0, viaQueue = 0, partial = 0, solo = 0, waits = {}, sameRole = 0, triple = 0,
        matchSeconds = 0, rounds = 0, ownPlayers = 0, spread = 0 }

    local function complete(members, now, kind)
        stats.groups = stats.groups + 1
        stats[kind] = stats[kind] + 1
        for _, member in ipairs(members) do
            if member.joinedAt then
                stats.waits[#stats.waits + 1] = now - member.joinedAt
                stats.ownPlayers = stats.ownPlayers + 1
            end
        end
        groupQuality(members, stats)
        local low, high
        for _, member in ipairs(members) do
            local level = levelOf[member.name]
            if level then
                low, high = math.min(low or level, level), math.max(high or level, level)
            end
        end
        stats.spread = stats.spread + (low and high - low or 0)
    end

    local function dropPending(entry, now)
        for name, out in pairs(entry.build and entry.build.pending or {}) do
            if out.listing.leaveAt > now then
                pool[name] = out.listing
            end
        end
    end

    -- As wow/autofill.lua: another entry seen, for a shared dungeon, not two
    -- parties, roles that fit together.
    local function hasPartner(entry, now)
        local mine = Roles.withReserved(entry.members, entry.reserved)
        for _, other in ipairs(queue) do
            local theirs = Roles.withReserved(other.members, other.reserved)
            if other ~= entry and other.visibleAt <= now and #theirs < 5 and not (#mine > 1 and #theirs > 1)
                and #mine + #theirs <= 5 then
                local shares = false
                for _, x in ipairs(other.dungeons) do
                    for _, y in ipairs(entry.dungeons) do
                        shares = shares or x == y
                    end
                end
                local together = {}
                for _, member in ipairs(mine) do
                    together[#together + 1] = member
                end
                for _, member in ipairs(theirs) do
                    together[#together + 1] = member
                end
                if shares and #Roles.options(together, SLOTS) > 0 then
                    return true
                end
            end
        end
        return false
    end

    -- Everyone of a group the matchmaker formed: its queue players in their
    -- roles and the Group Finder players its builders already had.
    local function membersOf(group, byId, joinedOf)
        local members = {}
        for _, member in ipairs(group.members) do
            members[#members + 1] = { name = member.name, role = member.role, class = classOf[member.name],
                joinedAt = joinedOf[member.name] }
        end
        for _, source in ipairs(group.entries) do
            local entry = byId[source.id]
            for _, extra in ipairs(entry.build and entry.build.extra or {}) do
                members[#members + 1] = extra
            end
        end
        return members
    end

    -- The needed roles a solo Forever Groups player in the queue (seen, no
    -- invites out) can play, for a dungeon of this group (as addonRoles in
    -- wow/filler.lua).
    local function addonRoles(entry, needed, now)
        local dungeons = entry.build.dungeon and { entry.build.dungeon } or entry.dungeons
        local left, covered = needed, ""
        for _, other in ipairs(queue) do
            local shares = false
            for _, x in ipairs(other.dungeons) do
                for _, y in ipairs(dungeons) do
                    shares = shares or x == y
                end
            end
            if other ~= entry and other.visibleAt <= now and #other.members == 1 and other.reserved == ""
                and shares then
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

    local function stepBuild(entry, now)
        local build = entry.build
        for name, out in pairs(build.pending) do
            local listing = out.listing
            if listing.accepts and now >= out.sentAt + listing.delay then
                build.pending[name] = nil
                build.extra[#build.extra + 1] = { name = name, role = out.role, class = listing.classToken }
            elseif not listing.accepts and now >= out.sentAt + INVITE_TIMEOUT then
                build.pending[name] = nil
                pool[name] = listing.leaveAt > now and listing or nil
            end
        end
        local function reserve()
            local roles = ""
            for _, member in ipairs(build.extra) do
                roles = roles .. member.role
            end
            for _, out in pairs(build.pending) do
                roles = roles .. out.role
            end
            entry.reserved = roles
        end
        local everyone = {}
        for _, member in ipairs(build.own) do
            everyone[#everyone + 1] = member
        end
        for _, member in ipairs(build.extra) do
            everyone[#everyone + 1] = member
        end
        local needed = openRoles(everyone)
        if needed == "" then
            return everyone
        end
        if build.pickedAt and now - build.pickedAt < PICK_EVERY then
            reserve()
            return nil
        end
        build.pickedAt = now
        local avoid, prefer
        if variant.variety then
            local classes = {}
            for _, member in ipairs(everyone) do
                Fill.addClass(classes, member.class, member.role)
            end
            local limit = variant.strict or Config.VARIETY_TIME
            if variant.adaptive then
                local candidates = 0
                local dungeons = build.dungeon and { build.dungeon } or entry.dungeons
                for name, listing in pairs(pool) do
                    local forDungeon, forRole = false, false
                    for _, dungeon in ipairs(dungeons) do
                        for _, id in ipairs(listing.dungeons) do
                            forDungeon = forDungeon or id == dungeon
                        end
                    end
                    for letter in string.gmatch(needed, ".") do
                        forRole = forRole or string.find(listing.roles, letter, 1, true) ~= nil
                    end
                    if forDungeon and forRole and not build.exclude[name] then
                        candidates = candidates + 1
                    end
                end
                limit = adaptiveTime(candidates)
            end
            if now - build.startedAt < limit then
                avoid = classes
            else
                prefer = classes
            end
        end
        for _, out in pairs(build.pending) do
            needed = removeLetter(needed, out.role)
            if avoid or prefer then
                Fill.addClass(avoid or prefer, out.listing.classToken, out.role)
            end
        end
        if variant.hold then
            local forAddon = needed ~= "" and addonRoles(entry, needed, now) or ""
            if forAddon == "" then
                build.addonSince = nil
            else
                build.addonSince = build.addonSince or now
                if now - build.addonSince < (variant.holdFor or ADDON_GRACE) then
                    for letter in string.gmatch(forAddon, ".") do
                        needed = removeLetter(needed, letter)
                    end
                end
            end
        end
        if needed == "" then
            reserve()
            return nil
        end
        local listings = {}
        for _, listing in pairs(pool) do
            listing.age = now - listing.listedAt
            listings[#listings + 1] = listing
        end
        table.sort(listings, function(a, b)
            return a.name < b.name
        end)
        local near
        if variant.near ~= false then
            local sum, count = 0, 0
            for _, member in ipairs(everyone) do
                if levelOf[member.name] then
                    sum, count = sum + levelOf[member.name], count + 1
                end
            end
            near = count > 0 and sum / count or nil
        end
        local picks
        if build.dungeon then
            picks = Fill.pick(listings, { missing = needed, dungeon = build.dungeon, exclude = build.exclude,
                avoid = avoid, prefer = prefer, range = RANGES[build.dungeon], near = near })
        else
            local plan = Fill.plan(listings, { missing = needed, dungeons = entry.dungeons, exclude = build.exclude,
                avoid = avoid, prefer = prefer, ranges = RANGES, near = near })
            picks = plan.picks
            if #picks > 0 then
                build.dungeon = plan.dungeon
                entry.dungeons = { plan.dungeon }
            end
        end
        for _, pick in ipairs(picks) do
            local listing = pool[pick.name]
            pool[pick.name] = nil
            build.exclude[pick.name] = true
            build.pending[pick.name] = { role = pick.role, sentAt = now, listing = listing }
        end
        reserve()
        return nil
    end

    for tick, events in ipairs(ticks) do
        local now = tick
        for _, entry in ipairs(events.queue) do
            local copy = { id = entry.id, joinedAt = entry.joinedAt, dungeons = entry.dungeons, members = {},
                reserved = "", spec = variant.variety and entry.members[1].class or nil, visibleAt = entry.visibleAt }
            for i, member in ipairs(entry.members) do
                copy.members[i] = { name = member.name, roles = member.roles, joinedAt = entry.joinedAt,
                    level = member.level }
                classOf[member.name] = member.class
                levelOf[member.name] = member.level
            end
            queue[#queue + 1] = copy
        end
        for _, listing in ipairs(events.listed) do
            pool[listing.name] = listing
            levelOf[listing.name] = listing.level
        end
        for name, listing in pairs(pool) do
            if listing.leaveAt <= now then
                pool[name] = nil
            end
        end

        local byId, joinedOf, seen = {}, {}, {}
        for _, entry in ipairs(queue) do
            byId[entry.id] = entry
            for _, member in ipairs(entry.members) do
                joinedOf[member.name] = member.joinedAt
            end
            if entry.visibleAt <= now and #entry.members + #entry.reserved < 5 then
                seen[#seen + 1] = entry
            end
        end
        local groups, partial = {}, nil
        Matchmaker.levelPreference = variant.near ~= false
        Config.VARIETY_TIME = variant.strict or VARIETY_DEFAULT
        if now % ROUND == ticks.phase then
            local started = os.clock()
            groups = Matchmaker.findGroups(seen, SLOTS, now)
            partial = #groups == 0 and variant.partial
                and Matchmaker.findPartialGroup(seen, SLOTS, now, Config.PARTIAL_AFTER, Config.PARTIAL_MIN_PLAYERS)
            stats.matchSeconds = stats.matchSeconds + os.clock() - started
            stats.rounds = stats.rounds + 1
        end
        local gone = {}
        for _, group in ipairs(groups) do
            for _, source in ipairs(group.entries) do
                gone[source.id] = true
                dropPending(byId[source.id], now)
            end
            complete(membersOf(group, byId, joinedOf), now + PROPOSAL_DELAY, "viaQueue")
        end
        local fresh
        if partial then
            local members = membersOf(partial, byId, joinedOf)
            local own, extra, reserved, joinedAt = {}, {}, "", now
            for _, member in ipairs(members) do
                if member.joinedAt then
                    own[#own + 1] = member
                    joinedAt = math.min(joinedAt, member.joinedAt)
                else
                    extra[#extra + 1] = member
                    reserved = reserved .. member.role
                end
            end
            for _, source in ipairs(partial.entries) do
                gone[source.id] = true
                dropPending(byId[source.id], now)
            end
            local queueMembers = {}
            for i, member in ipairs(own) do
                queueMembers[i] = { name = member.name, roles = member.role, joinedAt = member.joinedAt,
                    level = levelOf[member.name] }
            end
            fresh = { id = partial.leader, joinedAt = joinedAt, dungeons = { partial.dungeon },
                members = queueMembers, reserved = reserved, kind = "partial", visibleAt = now + PROPOSAL_DELAY,
                build = { own = own, extra = extra, pending = {}, exclude = {}, startedAt = now + PROPOSAL_DELAY,
                    dungeon = partial.dungeon } }
            queue[#queue + 1] = fresh
        end
        local keep = {}
        for _, entry in ipairs(queue) do
            if entry == fresh or not gone[entry.id] then
                keep[#keep + 1] = entry
            end
        end
        queue = keep

        for _, entry in ipairs(queue) do
            if not entry.build then
                if hasPartner(entry, now) then
                    entry.partnerSince = entry.partnerSince or now
                else
                    entry.partnerSince = nil
                end
                if not entry.partnerSince or now - entry.partnerSince >= variant.grace then
                    local best = missingFor(entry.members)
                    local own = {}
                    for i, member in ipairs(entry.members) do
                        own[i] = { name = member.name, role = best.assignment[i], class = classOf[member.name],
                            joinedAt = entry.joinedAt }
                    end
                    entry.kind = "solo"
                    entry.build = { own = own, extra = {}, pending = {}, exclude = {}, startedAt = now,
                        dungeon = #entry.dungeons == 1 and entry.dungeons[1] or nil }
                end
            end
        end

        keep = {}
        for _, entry in ipairs(queue) do
            local full = entry.build and now >= entry.build.startedAt and stepBuild(entry, now)
            if full then
                complete(full, now, entry.kind)
            else
                keep[#keep + 1] = entry
            end
        end
        queue = keep
    end

    local waiting = 0
    for _, entry in ipairs(queue) do
        waiting = waiting + #entry.members
    end
    table.sort(stats.waits)
    local sum = 0
    for _, wait in ipairs(stats.waits) do
        sum = sum + wait
    end
    stats.waiting = waiting
    stats.average = #stats.waits > 0 and sum / #stats.waits or 0
    stats.median = percentile(stats.waits, 0.5)
    stats.p90 = percentile(stats.waits, 0.9)
    stats.max = stats.waits[#stats.waits] or 0
    Config.VARIETY_TIME = VARIETY_DEFAULT
    return stats
end

local function clock(seconds)
    seconds = math.floor(seconds + 0.5)
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local SUMMED = { "groups", "viaQueue", "partial", "solo", "average", "median", "p90", "max", "waiting", "sameRole",
    "triple", "matchSeconds", "rounds", "ownPlayers", "spread" }

-- runs: how many seeds (seed, seed + 1, ...) to average over.
function Sim.report(name, minutes, seed, runs, variants)
    local scenario = assert(Sim.SCENARIOS[name], "unknown scenario " .. tostring(name))
    runs = runs or 1
    local timelines, queued, listed = {}, 0, 0
    for run = 1, runs do
        local ticks, q, l = timeline(scenario, minutes, seed + run - 1)
        timelines[run] = ticks
        queued, listed = queued + q, listed + l
    end
    local lines = {
        string.format("scenario %s, %d min, seeds %d-%d (averages): %.0f queue entries, %.0f listed players", name,
            minutes, seed, seed + runs - 1, queued / runs, listed / runs),
        "assumes: " .. Sim.ASSUMPTIONS,
        "",
        string.format("%-11s %6s %6s %7s %5s %8s %7s %6s %6s %7s %8s %8s %8s %6s %8s", "variant", "groups", "queue",
            "partial", "solo", "avg", "median", "p90", "max", "waiting", "2x-role", "3x-class", "FG/group", "levels",
            "ms/round"),
    }
    local results = {}
    for _, variant in ipairs(variants or Sim.VARIANTS) do
        local mean = {}
        for _, key in ipairs(SUMMED) do
            mean[key] = 0
        end
        for run = 1, runs do
            local stats = Sim.run(variant, timelines[run])
            for _, key in ipairs(SUMMED) do
                mean[key] = mean[key] + stats[key] / runs
            end
        end
        results[variant.name] = mean
        lines[#lines + 1] = string.format(
            "%-11s %6.1f %6.1f %7.1f %5.1f %8s %7s %6s %6s %7.1f %8.1f %8.1f %8.2f %6.2f %8.2f",
            variant.name, mean.groups, mean.viaQueue, mean.partial, mean.solo, clock(mean.average),
            clock(mean.median), clock(mean.p90), clock(mean.max), mean.waiting, mean.sameRole, mean.triple,
            mean.groups > 0 and mean.ownPlayers / mean.groups or 0, mean.groups > 0 and mean.spread / mean.groups or 0,
            mean.rounds > 0 and mean.matchSeconds * 1000 / mean.rounds or 0)
    end
    return table.concat(lines, "\n"), results
end

if arg and type(arg[0]) == "string" and string.find(arg[0], "simulate%.lua$") then
    local set = Sim.VARIANT_SETS[arg[5] or "main"]
    print((Sim.report(arg[1] or "normal", tonumber(arg[2]) or 60, tonumber(arg[3]) or 1, tonumber(arg[4]) or 5,
        set)))
end

return Sim
