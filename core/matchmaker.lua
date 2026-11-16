local _, ns = ...
ns = ns or {}

local Config = ns.Config or require("core.config")
local Roles = ns.Roles or require("core.roles")
local Playstyles = ns.Playstyles or require("core.playstyles")
local Specs = ns.Specs or require("core.specs")
local Compose = ns.Compose or require("core.compose")
local Levels = ns.Levels or require("core.levels")
local Languages = ns.Languages or require("core.languages")
local Fill = ns.Fill or require("core.fill")

local Matchmaker = {}

local SEARCH_BUDGET = 20000
-- One anchor no group can be formed for may search long; it gets at most
-- this share, so the anchors behind it still get their turn this round.
local ANCHOR_BUDGET, DUNGEON_MIN_BUDGET = 1000, 100
-- Leaders with class wishes may turn down many complete groups before one
-- fits; together they get at most this share of a round's search, so the
-- other players always keep the rest.
local WISH_BUDGET = 4000
-- Once a group that is not varied is found past VARIETY_TIME, a varied one is
-- looked for this much longer before taking it.
local PREFER_BUDGET = 200

-- An anchor takes the players closest to its level first; whoever waited
-- VARIETY_TIME counts as close (tools/simulate.lua turns it off to compare).
Matchmaker.levelPreference = true

function Matchmaker.comparePriority(a, b)
    if a.joinedAt ~= b.joinedAt then
        return a.joinedAt < b.joinedAt
    end
    return a.id < b.id
end

function Matchmaker.sortByPriority(entries)
    local sorted = {}
    for i, entry in ipairs(entries) do
        sorted[i] = entry
    end
    table.sort(sorted, Matchmaker.comparePriority)
    return sorted
end

local function wantsDungeon(entry, dungeon)
    for _, id in ipairs(entry.dungeons) do
        if id == dungeon then
            return true
        end
    end
    return false
end

local function fits(counts, need)
    return counts.T <= need.T and counts.H <= need.H and counts.D <= need.D
end

local function isComplete(need)
    return need.T == 0 and need.H == 0 and need.D == 0
end

-- States are the remaining-need vectors still reachable with the entries
-- chosen so far; flexible players make several of them possible at once.
local function apply(states, options)
    local result, seen = {}, {}
    for _, need in ipairs(states) do
        for _, option in ipairs(options) do
            if fits(option.counts, need) then
                local c = option.counts
                local rest = { T = need.T - c.T, H = need.H - c.H, D = need.D - c.D }
                local key = rest.T .. ":" .. rest.H .. ":" .. rest.D
                if not seen[key] then
                    seen[key] = true
                    result[#result + 1] = rest
                end
            end
        end
    end
    return result
end

local function anyComplete(states)
    for _, need in ipairs(states) do
        if isComplete(need) then
            return true
        end
    end
    return false
end

-- Role sets as bit masks: T = 1, H = 2, D = 4.
local ROLE_BITS = { T = 1, H = 2, D = 4 }

local function hasBit(mask, bit)
    return mask % (bit * 2) >= bit
end

local function bitAnd(a, b)
    local result = 0
    for _, bit in ipairs({ 1, 2, 4 }) do
        if hasBit(a, bit) and hasBit(b, bit) then
            result = result + bit
        end
    end
    return result
end

local function needIn(need, mask)
    local sum = 0
    for role, bit in pairs(ROLE_BITS) do
        if hasBit(mask, bit) then
            sum = sum + need[role]
        end
    end
    return sum
end

-- supply[mask] counts the players who can play at least one role of the set.
-- By Hall's theorem the open slots can still be filled exactly when, for
-- every set of roles, enough players can play one of them.
local function canStillComplete(states, supply)
    for _, need in ipairs(states) do
        local ok = true
        for mask = 1, 7 do
            if supply[mask] < needIn(need, mask) then
                ok = false
                break
            end
        end
        if ok then
            return true
        end
    end
    return false
end

local function overlaps(candidate, taken)
    for _, member in ipairs(candidate.members) do
        if member.name and taken[member.name] then
            return true
        end
    end
    return false
end

local function setTaken(candidate, taken, value)
    for _, member in ipairs(candidate.members) do
        if member.name then
            taken[member.name] = value
        end
    end
end

-- Depth-first, include-first search over candidates in priority order, so the
-- first complete group found is the lexicographically earliest set by
-- priority, whatever roles its flexible players end up with.
-- At most one premade per group: the premade then always leads, and no party
-- ever has to break up to accept an invite.
-- taken: names already in the group, so a player listed in two entries
-- (a stale solo entry and a party's) is never placed twice.
-- style: the group's playstyle so far; a candidate must go with it, and
-- with the language of everyone chosen.
-- accept(chosen): a complete group that fails it (a leader's class wishes)
-- is passed over and the search goes on. feasible(chosen): checked as each
-- candidate is added, so a set that can never fit the wishes is dropped at
-- once instead of after every way of completing it.
local function search(candidates, suffixSupply, start, states, chosen, budget, hasPremade, taken, style, accept,
                      feasible)
    if anyComplete(states) then
        return accept == nil or accept(chosen)
    end
    if not canStillComplete(states, suffixSupply[start]) then
        return false
    end
    for i = start, #candidates do
        budget.left = budget.left - 1
        if budget.left <= 0 then
            return false
        end
        local candidate = candidates[i]
        local isPremade = #candidate.members > 1
        if not (isPremade and hasPremade) and not overlaps(candidate, taken)
            and Playstyles.compatible(style, candidate.playstyle) and Languages.fitsAll(chosen, candidate) then
            local nextStates = apply(states, candidate.options)
            if #nextStates > 0 then
                chosen[#chosen + 1] = candidate
                if feasible and not feasible(chosen) then
                    chosen[#chosen] = nil
                else
                    setTaken(candidate, taken, true)
                    if search(candidates, suffixSupply, i + 1, nextStates, chosen, budget, hasPremade or isPremade,
                        taken, Playstyles.combine(style, candidate.playstyle), accept, feasible) then
                        return true
                    end
                    setTaken(candidate, taken, nil)
                    chosen[#chosen] = nil
                end
            end
        end
    end
    return false
end

local function roleMask(roles)
    local mask = 0
    for role, bit in pairs(ROLE_BITS) do
        if string.find(roles, role, 1, true) then
            mask = mask + bit
        end
    end
    return mask
end

local function buildSuffixSupply(candidates)
    local supply = {}
    local running = { 0, 0, 0, 0, 0, 0, 0 }
    supply[#candidates + 1] = running
    for i = #candidates, 1, -1 do
        local nextRunning = {}
        for mask = 1, 7 do
            nextRunning[mask] = running[mask]
        end
        for _, member in ipairs(candidates[i].members) do
            local playable = roleMask(member.roles)
            for mask = 1, 7 do
                if bitAnd(playable, mask) ~= 0 then
                    nextRunning[mask] = nextRunning[mask] + 1
                end
            end
        end
        running = nextRunning
        supply[i] = running
    end
    return supply
end

-- Picks one concrete option per entry so the group is exactly full; entries
-- earlier in the list get first pick of the scarce roles (T, then H, then D).
local function assign(entries, need, index, picked)
    if index > #entries then
        return isComplete(need)
    end
    for _, option in ipairs(entries[index].options) do
        if fits(option.counts, need) then
            local rest = { T = need.T - option.counts.T, H = need.H - option.counts.H, D = need.D - option.counts.D }
            picked[index] = option.assignment
            if assign(entries, rest, index + 1, picked) then
                return true
            end
        end
    end
    picked[index] = nil
    return false
end

-- A leader's class wishes (core/compose.lua): the leader's entry anchors the
-- group, only solo players join it, and each of them only in a role whose
-- places allow their class (known from their spec). The leader's own
-- players (the leader, the party, places held for open invites) have no
-- class here: the leader sends their places without a wish
-- (wow/partycompose.lua, Compose.seat), so they fit there and never take a
-- wished place. The finished group must give every player a place of their
-- own.

-- A copy of the entry with its members' roles narrowed to what the wishes
-- allow, or nil when a member has no role left. own: the leader's own entry.
local function restrictFor(rules, entry, slots, own)
    local members = {}
    for i, member in ipairs(entry.members) do
        local class = not own and i == 1 and not member.reserved and entry.class or nil
        local roles = Compose.rolesFor(rules, class, member.roles)
        if roles == "" then
            return nil
        end
        members[i] = { name = member.name, roles = roles, level = member.level, reserved = member.reserved,
            class = class }
    end
    local copy = {}
    for key, value in pairs(entry) do
        copy[key] = value
    end
    copy.members, copy.options = members, Roles.options(members, slots, true)
    copy.every = copy.options
    return copy
end

local function wishesCheck(rules)
    return function(members)
        return Compose.fits(rules, members)
    end
end

-- Varied classes (as the Group Finder side, Fill.avoided): no class twice in
-- one role, none more than twice. A member whose class is not known (a
-- party's other players, places held for invites) is not held to it.
local function varied(members)
    local seen = {}
    for _, member in ipairs(members) do
        if Fill.avoided(seen, {}, member.class, member.role) then
            return false
        end
        if member.class then
            Fill.addClass(seen, member.class, member.role)
        end
    end
    return true
end

-- Whether the players chosen so far can still end up varied, whatever roles
-- the flexible ones take: none of a class three times, none twice who can
-- only play the same single role.
local function canStayVaried(chosen)
    local count, single = {}, {}
    for _, entry in ipairs(chosen) do
        for _, member in ipairs(entry.members) do
            local class = member.class
            if class then
                count[class] = (count[class] or 0) + 1
                if count[class] > 2 then
                    return false
                end
                if #member.roles == 1 then
                    local key = class .. member.roles
                    if single[key] then
                        return false
                    end
                    single[key] = true
                end
            end
        end
    end
    return true
end

-- The check a group of this anchor must pass at `now`: the leader's class
-- wishes, else varied classes while the anchor (who waited longest) has
-- waited less than VARIETY_TIME; nil when anything goes.
local function checkFor(anchor, rules, now)
    if rules then
        return wishesCheck(rules)
    end
    if now and now - anchor.joinedAt < Config.VARIETY_TIME then
        return varied
    end
    return nil
end

-- One role per member (as assign), with exactly `target` filled, that
-- check(members) accepts ({ role, class } each); nil when there is none.
local function pickFor(entries, target, check)
    local picked = {}
    local function walk(index, need)
        if index > #entries then
            if not isComplete(need) then
                return false
            end
            local members = {}
            for i, entry in ipairs(entries) do
                for j, member in ipairs(entry.members) do
                    members[#members + 1] = { role = picked[i][j], class = member.class }
                end
            end
            return check(members)
        end
        for _, option in ipairs(entries[index].every or entries[index].options) do
            if fits(option.counts, need) then
                picked[index] = option.assignment
                local rest = { T = need.T - option.counts.T, H = need.H - option.counts.H,
                    D = need.D - option.counts.D }
                if walk(index + 1, rest) then
                    return true
                end
            end
        end
        picked[index] = nil
        return false
    end
    if walk(1, { T = target.T, H = target.H, D = target.D }) then
        return picked
    end
    return nil
end

-- The candidates an anchor may take: none with wishes or a level limit of
-- their own (they anchor their own group), and under the anchor's wishes or
-- limit only solo players, within the limit, narrowed to the roles their
-- class may take.
local function candidateFor(anchor, entry, slots)
    if entry.rules or entry.levels then
        return nil
    end
    if not anchor.rules and not anchor.levels then
        return entry
    end
    if #entry.members > 1 or (anchor.levels and not Levels.entryFits(anchor.levels, entry)) then
        return nil
    end
    return anchor.rules and restrictFor(anchor.rules, entry, slots) or entry
end

Matchmaker.candidateFor = candidateFor

local function isBetter(a, b)
    if not b then
        return true
    end
    for i = 1, math.max(#a.ranks, #b.ranks) do
        local x, y = a.ranks[i], b.ranks[i]
        if x == nil then
            return true
        elseif y == nil then
            return false
        elseif x ~= y then
            return x < y
        end
    end
    return false
end

local function sortedCopy(list)
    local copy = {}
    for i, value in ipairs(list) do
        copy[i] = value
    end
    table.sort(copy)
    return copy
end

-- The entries an anchor may take, in queue order: those after it, and for a
-- leader with wishes or a level limit also those before it, who cannot take
-- that leader into their own group.
local function candidateIndices(anchor, anchorIndex, count)
    local list = {}
    local first = (anchor.rules or anchor.levels) and 1 or anchorIndex + 1
    for i = first, count do
        if i ~= anchorIndex then
            list[#list + 1] = i
        end
    end
    return list
end

-- The average level of an entry's players whose level is known, or nil.
local function averageLevel(entry)
    local sum, count = 0, 0
    for _, member in ipairs(entry.members) do
        if type(member.level) == "number" and member.level > 0 then
            sum, count = sum + member.level, count + 1
        end
    end
    return count > 0 and sum / count or nil
end

local function anyRoles()
    return true
end

local function tryAnchor(sorted, anchorIndex, slots, budget, usedNames, now)
    local anchor = sorted[anchorIndex]
    if overlaps(anchor, usedNames) then
        return nil
    end
    local rules = anchor.rules
    if rules then
        anchor = restrictFor(rules, anchor, slots, true)
        if not anchor or budget.wishLeft <= 0 then
            return nil
        end
    end
    -- The players this anchor may take, restricted once (not per dungeon).
    local pool = {}
    for _, i in ipairs(candidateIndices(anchor, anchorIndex, #sorted)) do
        local candidate = not overlaps(sorted[i], usedNames) and candidateFor(anchor, sorted[i], slots)
        if candidate and Playstyles.compatible(anchor.playstyle, candidate.playstyle)
            and Languages.compatible(anchor.language, candidate.language) then
            pool[#pool + 1] = candidate
        end
    end
    if Matchmaker.levelPreference and now then
        local mine = averageLevel(anchor)
        local function closeness(entry)
            if not mine or now - entry.joinedAt >= Config.VARIETY_TIME then
                return 0
            end
            local theirs = averageLevel(entry)
            return theirs and math.abs(theirs - mine) or math.huge
        end
        table.sort(pool, function(a, b)
            local x, y = closeness(a), closeness(b)
            if x ~= y then
                return x < y
            end
            return a.rank < b.rank
        end)
    end
    local shared = budget
    local perDungeon = math.max(DUNGEON_MIN_BUDGET, math.floor(ANCHOR_BUDGET / math.max(1, #anchor.dungeons)))
    local picked, fallback, share
    local check = checkFor(anchor, rules, now)
    -- Past VARIETY_TIME (no wishes) a varied group is still preferred: the
    -- first group found that is not varied is kept in case none is, so the
    -- search costs no more where classes don't clash.
    local prefer = check == nil and now ~= nil and not rules
    if prefer then
        check = varied
    end
    local accept = check and function(chosen)
        picked = pickFor(chosen, slots, check)
        if picked then
            return true
        end
        if prefer and not fallback then
            local entries = {}
            for i, entry in ipairs(chosen) do
                entries[i] = entry
            end
            fallback = { entries = entries, picked = pickFor(chosen, slots, anyRoles) }
            share.left = math.min(share.left, PREFER_BUDGET)
        end
        return false
    end or nil
    local feasible = check == varied and function(chosen)
        return prefer or canStayVaried(chosen)
    end or rules and function(chosen)
        local members = {}
        for _, entry in ipairs(chosen) do
            for _, member in ipairs(entry.members) do
                members[#members + 1] = { roles = member.roles, class = member.class }
            end
        end
        return Compose.fits(rules, members)
    end or nil
    local best, bestFallback
    for _, dungeon in ipairs(sortedCopy(anchor.dungeons)) do
        fallback = nil
        local candidates = {}
        for _, candidate in ipairs(pool) do
            if wantsDungeon(candidate, dungeon) then
                candidates[#candidates + 1] = candidate
            end
        end
        -- Under wishes: first whether the places can be filled at all by
        -- these players; a wish for a class nobody here plays ends it at once.
        local fillable = true
        if rules then
            local everyone = {}
            for index = 0, #candidates do
                for _, member in ipairs((index == 0 and anchor or candidates[index]).members) do
                    everyone[#everyone + 1] = { roles = member.roles, class = member.class }
                end
            end
            fillable = Compose.canFill(rules, everyone)
        end
        local states = apply({ { T = slots.T, H = slots.H, D = slots.D } }, anchor.options)
        local chosen = { anchor }
        local taken = {}
        setTaken(anchor, taken, true)
        -- Each dungeon its own share: one that can never fill (players who
        -- don't take each other's language) must not use up the others'.
        share = { left = math.min(shared.left, rules and shared.wishLeft or perDungeon) }
        local start = share.left
        if fillable and #states > 0 and search(candidates, buildSuffixSupply(candidates), 1, states, chosen, share,
            #anchor.members > 1, taken, anchor.playstyle, accept, feasible) then
            local ranks = {}
            for i, entry in ipairs(chosen) do
                ranks[i] = entry.rank
            end
            local group = { dungeon = dungeon, entries = chosen, ranks = ranks, picked = picked }
            if isBetter(group, best) then
                best = group
            end
        elseif fallback then
            local ranks = {}
            for i, entry in ipairs(fallback.entries) do
                ranks[i] = entry.rank
            end
            local group = { dungeon = dungeon, entries = fallback.entries, ranks = ranks, picked = fallback.picked }
            if isBetter(group, bestFallback) then
                bestFallback = group
            end
        end
        local spent = start - share.left
        shared.left = shared.left - spent
        if rules then
            shared.wishLeft = shared.wishLeft - spent
        end
    end
    return best or bestFallback
end

-- entries: { id, members = { { name, role } }, source } with one assigned
-- role each. A party leads (it never breaks up), then a player who would like
-- to lead, then the tank, then the earliest entry.
function Matchmaker.chooseLeaderEntry(entries)
    for _, entry in ipairs(entries) do
        if entry.composer then
            return entry
        end
    end
    local best
    for _, entry in ipairs(entries) do
        local size, hasTank = entry.size or #entry.members, false
        for _, member in ipairs(entry.members) do
            hasTank = hasTank or member.role == "T"
        end
        local wants = size == 1 and entry.source ~= nil and entry.source.lead == true
        local better = not best or size > best.size
        if not better and size == best.size then
            if wants ~= best.wants then
                better = wants
            else
                better = hasTank and not best.hasTank
            end
        end
        if better then
            best = { entry = entry, size = size, hasTank = hasTank, wants = wants }
        end
    end
    return best.entry
end

-- Helpers the questing and battleground matchers share: entries list the
-- keys they wait for in `dungeons`.
function Matchmaker.wantsKey(entry, key)
    for _, other in ipairs(entry.dungeons) do
        if other == key then
            return true
        end
    end
    return false
end

-- How many keys two entries both wait for.
function Matchmaker.sharedKeys(a, b)
    local mine, count = {}, 0
    for _, key in ipairs(a.dungeons) do
        mine[key] = true
    end
    for _, key in ipairs(b.dungeons) do
        if mine[key] then
            count = count + 1
        end
    end
    return count
end

-- Whether a player of the entry is among names (already placed).
function Matchmaker.sharesPlayer(entry, names)
    for _, member in ipairs(entry.members) do
        if member.name and names[member.name] then
            return true
        end
    end
    return false
end

function Matchmaker.addNames(entry, names)
    for _, member in ipairs(entry.members) do
        if member.name then
            names[member.name] = true
        end
    end
end

-- parts: per entry { id, members (name, role), size, source }. Puts the
-- leader's part first (chooseLeaderEntry) and returns it, with per part its
-- members and queue entry, and every member in that order.
function Matchmaker.orderByLeader(parts)
    local leader = Matchmaker.chooseLeaderEntry(parts)
    local ordered = { leader }
    for _, part in ipairs(parts) do
        if part ~= leader then
            ordered[#ordered + 1] = part
        end
    end
    local assigned, sources, members = {}, {}, {}
    for i, part in ipairs(ordered) do
        assigned[i] = part.members
        sources[i] = part.source
        for _, member in ipairs(part.members) do
            members[#members + 1] = member
        end
    end
    return leader, assigned, sources, members
end

-- target: the roles the group's own players fill (all slots for a full group).
local function finishGroup(group, target)
    local picked = group.picked
    if not picked then
        picked = {}
        assign(group.entries, { T = target.T, H = target.H, D = target.D }, 1, picked)
    end
    local assigned = {}
    local reserved = { T = 0, H = 0, D = 0 }
    for i, entry in ipairs(group.entries) do
        local members = {}
        for j, member in ipairs(entry.members) do
            if member.reserved then
                reserved[picked[i][j]] = reserved[picked[i][j]] + 1
            else
                members[#members + 1] = { name = member.name, role = picked[i][j] }
            end
        end
        assigned[i] = { id = entry.id, members = members, size = #entry.members, source = entry.source,
            composer = entry.rules ~= nil or entry.levels ~= nil }
    end
    local leaderEntry, perEntry, sources, members = Matchmaker.orderByLeader(assigned)
    return {
        dungeon = group.dungeon,
        playstyles = Playstyles.mix(group.entries),
        entries = sources,
        assigned = perEntry,
        leader = leaderEntry.id,
        members = members,
        missing = Roles.fromCounts(reserved) .. (group.missing or ""),
    }
end

-- Forms as many complete groups as possible. Priority goes to whoever has
-- waited longest: the earliest entry that can be placed anchors the next group,
-- and the rest of that group is the earliest feasible set behind it.
-- Each group lists `entries` (queue entries, leader's first) and `assigned`
-- (per entry, its members with the single role each one gets).
-- Reserved roles (already invited from WoW's Group Finder) take part as
-- placeholder members, so they count as taken slots.
-- now: server time, for class wishes that end (prefer mode); without it
-- the wishes are left out.
local function wrapAll(entries, slots, now)
    local wrapped = {}
    for i, entry in ipairs(Matchmaker.sortByPriority(entries)) do
        local all = Roles.withReserved(entry.members, entry.reserved)
        local class = (Specs.decode(entry.spec))
        if class and all[1] and not all[1].reserved then
            local owner = {}
            for key, value in pairs(all[1]) do
                owner[key] = value
            end
            owner.class = class
            all[1] = owner
        end
        wrapped[i] = {
            id = entry.id,
            joinedAt = entry.joinedAt,
            dungeons = entry.dungeons,
            members = all,
            players = #entry.members,
            playstyle = entry.playstyle or Playstyles.ANY,
            options = Roles.options(all, slots),
            every = Roles.options(all, slots, true),
            rank = i,
            source = entry,
            class = class,
            rules = now and Compose.active(entry.compose, now) or nil,
            levels = now and Levels.active(entry.levels, now) or nil,
            language = Languages.decode(entry.language),
        }
    end
    return wrapped
end

function Matchmaker.findGroups(entries, slots, now)
    slots = slots or Config.SLOTS
    local wrapped = wrapAll(entries, slots, now)

    local groups, usedNames = {}, {}
    local budget = { left = SEARCH_BUDGET, wishLeft = WISH_BUDGET }
    local full = { T = slots.T, H = slots.H, D = slots.D }
    -- One pass is enough: the search is exhaustive and a group only takes
    -- players away, so an anchor that found nothing never finds a group later.
    -- Entries already placed are skipped through usedNames.
    for anchorIndex = 1, #wrapped do
        if budget.left <= 0 then
            break
        end
        local group = tryAnchor(wrapped, anchorIndex, slots, budget, usedNames, now)
        if group then
            for _, entry in ipairs(group.entries) do
                setTaken(entry, usedNames, true)
            end
            groups[#groups + 1] = finishGroup(group, full)
        end
    end
    return groups
end

-- Lower is better: leave DPS open rather than a tank or healer, which are
-- scarce in WoW's Group Finder too.
local function openScore(need)
    return need.T * 100 + need.H * 10 + need.D
end

local function playerCount(chosen)
    local count = 0
    for _, entry in ipairs(chosen) do
        count = count + entry.players
    end
    return count
end

-- For players who waited at least `waitAfter` seconds without a full group:
-- the largest group (at least two queue entries and minPlayers players) the
-- longest-waiting of them can form, with the remaining roles left open for
-- WoW's Group Finder. A lone entry fills itself from the Group Finder. Players
-- are taken in priority order. Returns nil when no such group exists.
-- The open roles (one of states) the chosen players can leave under the
-- anchor's check (checkFor), with their roles; the fewest scarce roles open
-- first.
local function partialPick(chosen, states, slots, check)
    local sorted = {}
    for i, need in ipairs(states) do
        sorted[i] = need
    end
    table.sort(sorted, function(a, b)
        return openScore(a) < openScore(b)
    end)
    for _, open in ipairs(sorted) do
        local target = { T = slots.T - open.T, H = slots.H - open.H, D = slots.D - open.D }
        local picked = not check and {} or pickFor(chosen, target, check)
        if picked then
            return open, check and picked or nil
        end
    end
    return nil
end

function Matchmaker.findPartialGroup(entries, slots, now, waitAfter, minPlayers)
    slots = slots or Config.SLOTS
    local wrapped = wrapAll(entries, slots, now)
    for anchorIndex, original in ipairs(wrapped) do
        if now - original.joinedAt < waitAfter then
            return nil
        end
        local rules = original.rules
        local anchor = rules and restrictFor(rules, original, slots, true) or (not rules and original) or nil
        local check = anchor and checkFor(anchor, rules, now)
        local best
        for _, dungeon in ipairs(anchor and sortedCopy(anchor.dungeons) or {}) do
            local states = apply({ { T = slots.T, H = slots.H, D = slots.D } }, anchor.options)
            local chosen, hasPremade, style = { anchor }, #anchor.members > 1, anchor.playstyle
            local names = {}
            setTaken(anchor, names, true)
            for _, i in ipairs(candidateIndices(anchor, anchorIndex, #wrapped)) do
                local candidate = candidateFor(anchor, wrapped[i], slots)
                local isPremade = candidate and #candidate.members > 1
                if candidate and #states > 0 and wantsDungeon(candidate, dungeon) and not (isPremade and hasPremade)
                    and Playstyles.compatible(style, candidate.playstyle) and not overlaps(candidate, names)
                    and Languages.fitsAll(chosen, candidate) then
                    local nextStates = apply(states, candidate.options)
                    chosen[#chosen + 1] = candidate
                    if #nextStates > 0 and (not check or partialPick(chosen, nextStates, slots, check)) then
                        states = nextStates
                        hasPremade = hasPremade or isPremade
                        style = Playstyles.combine(style, candidate.playstyle)
                        setTaken(candidate, names, true)
                    else
                        chosen[#chosen] = nil
                    end
                end
            end
            local players = playerCount(chosen)
            if #states > 0 and #chosen >= 2 and players >= minPlayers then
                local open, picked = partialPick(chosen, states, slots, check)
                if open and (not best or players > best.players
                    or (players == best.players and openScore(open) < openScore(best.open))) then
                    best = { dungeon = dungeon, entries = chosen, open = open, players = players, picked = picked }
                end
            end
        end
        if best then
            local target = { T = slots.T - best.open.T, H = slots.H - best.open.H, D = slots.D - best.open.D }
            local group = { dungeon = best.dungeon, entries = best.entries, missing = Roles.fromCounts(best.open),
                picked = best.picked }
            return finishGroup(group, target)
        end
    end
    return nil
end

ns.Matchmaker = Matchmaker
return Matchmaker
