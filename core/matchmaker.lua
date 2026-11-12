local _, ns = ...
ns = ns or {}

local Config = ns.Config or require("core.config")
local Roles = ns.Roles or require("core.roles")
local Playstyles = ns.Playstyles or require("core.playstyles")

local Matchmaker = {}

local SEARCH_BUDGET = 20000

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
-- style: the group's playstyle so far; a candidate must go with it.
local function search(candidates, suffixSupply, start, states, chosen, budget, hasPremade, taken, style)
    if anyComplete(states) then
        return true
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
            and Playstyles.compatible(style, candidate.playstyle) then
            local nextStates = apply(states, candidate.options)
            if #nextStates > 0 then
                chosen[#chosen + 1] = candidate
                setTaken(candidate, taken, true)
                if search(candidates, suffixSupply, i + 1, nextStates, chosen, budget, hasPremade or isPremade,
                    taken, Playstyles.combine(style, candidate.playstyle)) then
                    return true
                end
                setTaken(candidate, taken, nil)
                chosen[#chosen] = nil
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

local function tryAnchor(sorted, anchorIndex, slots, budget, usedNames)
    local anchor = sorted[anchorIndex]
    if overlaps(anchor, usedNames) then
        return nil
    end
    local best
    for _, dungeon in ipairs(sortedCopy(anchor.dungeons)) do
        local candidates = {}
        for i = anchorIndex + 1, #sorted do
            if wantsDungeon(sorted[i], dungeon) and not overlaps(sorted[i], usedNames)
                and Playstyles.compatible(anchor.playstyle, sorted[i].playstyle) then
                candidates[#candidates + 1] = sorted[i]
            end
        end
        local states = apply({ { T = slots.T, H = slots.H, D = slots.D } }, anchor.options)
        local chosen = { anchor }
        local taken = {}
        setTaken(anchor, taken, true)
        if #states > 0 and search(candidates, buildSuffixSupply(candidates), 1, states, chosen, budget,
            #anchor.members > 1, taken, anchor.playstyle) then
            local ranks = {}
            for i, entry in ipairs(chosen) do
                ranks[i] = entry.rank
            end
            local group = { dungeon = dungeon, entries = chosen, ranks = ranks }
            if isBetter(group, best) then
                best = group
            end
        end
    end
    return best
end

-- entries: { id, members = { { name, role } }, source } with one assigned
-- role each. A party leads (it never breaks up), then a player who would like
-- to lead, then the tank, then the earliest entry.
function Matchmaker.chooseLeaderEntry(entries)
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

-- target: the roles the group's own players fill (all slots for a full group).
local function finishGroup(group, target)
    local picked = {}
    assign(group.entries, { T = target.T, H = target.H, D = target.D }, 1, picked)
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
        assigned[i] = { id = entry.id, members = members, size = #entry.members, source = entry.source }
    end
    local leaderEntry = Matchmaker.chooseLeaderEntry(assigned)
    local ordered = { leaderEntry }
    for _, entry in ipairs(assigned) do
        if entry ~= leaderEntry then
            ordered[#ordered + 1] = entry
        end
    end
    local members, perEntry, sources = {}, {}, {}
    for i, entry in ipairs(ordered) do
        perEntry[i] = entry.members
        sources[i] = entry.source
        for _, member in ipairs(entry.members) do
            members[#members + 1] = member
        end
    end
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
local function wrapAll(entries, slots)
    local wrapped = {}
    for i, entry in ipairs(Matchmaker.sortByPriority(entries)) do
        local all = Roles.withReserved(entry.members, entry.reserved)
        wrapped[i] = {
            id = entry.id,
            joinedAt = entry.joinedAt,
            dungeons = entry.dungeons,
            members = all,
            players = #entry.members,
            playstyle = entry.playstyle or Playstyles.ANY,
            options = Roles.options(all, slots),
            rank = i,
            source = entry,
        }
    end
    return wrapped
end

function Matchmaker.findGroups(entries, slots)
    slots = slots or Config.SLOTS
    local wrapped = wrapAll(entries, slots)

    local groups, used, usedNames = {}, {}, {}
    local budget = { left = SEARCH_BUDGET }
    local full = { T = slots.T, H = slots.H, D = slots.D }
    local progress = true
    while progress do
        progress = false
        local remaining = {}
        for _, entry in ipairs(wrapped) do
            if not used[entry.id] then
                remaining[#remaining + 1] = entry
            end
        end
        for anchorIndex = 1, #remaining do
            local group = tryAnchor(remaining, anchorIndex, slots, budget, usedNames)
            if group then
                for _, entry in ipairs(group.entries) do
                    used[entry.id] = true
                    setTaken(entry, usedNames, true)
                end
                groups[#groups + 1] = finishGroup(group, full)
                progress = true
                break
            end
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
function Matchmaker.findPartialGroup(entries, slots, now, waitAfter, minPlayers)
    slots = slots or Config.SLOTS
    local wrapped = wrapAll(entries, slots)
    for anchorIndex, anchor in ipairs(wrapped) do
        if now - anchor.joinedAt < waitAfter then
            return nil
        end
        local best
        for _, dungeon in ipairs(sortedCopy(anchor.dungeons)) do
            local states = apply({ { T = slots.T, H = slots.H, D = slots.D } }, anchor.options)
            local chosen, hasPremade, style = { anchor }, #anchor.members > 1, anchor.playstyle
            local names = {}
            setTaken(anchor, names, true)
            for i = anchorIndex + 1, #wrapped do
                local candidate = wrapped[i]
                local isPremade = #candidate.members > 1
                if #states > 0 and wantsDungeon(candidate, dungeon) and not (isPremade and hasPremade)
                    and Playstyles.compatible(style, candidate.playstyle) and not overlaps(candidate, names) then
                    local nextStates = apply(states, candidate.options)
                    if #nextStates > 0 then
                        states = nextStates
                        chosen[#chosen + 1] = candidate
                        hasPremade = hasPremade or isPremade
                        style = Playstyles.combine(style, candidate.playstyle)
                        setTaken(candidate, names, true)
                    end
                end
            end
            local players = playerCount(chosen)
            if #states > 0 and #chosen >= 2 and players >= minPlayers then
                local open = states[1]
                for _, need in ipairs(states) do
                    if openScore(need) < openScore(open) then
                        open = need
                    end
                end
                if not best or players > best.players
                    or (players == best.players and openScore(open) < openScore(best.open)) then
                    best = { dungeon = dungeon, entries = chosen, open = open, players = players }
                end
            end
        end
        if best then
            local target = { T = slots.T - best.open.T, H = slots.H - best.open.H, D = slots.D - best.open.D }
            local group = { dungeon = best.dungeon, entries = best.entries, missing = Roles.fromCounts(best.open) }
            return finishGroup(group, target)
        end
    end
    return nil
end

ns.Matchmaker = Matchmaker
return Matchmaker
