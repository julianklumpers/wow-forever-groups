local _, ns = ...
ns = ns or {}

local Roles = ns.Roles or require("core.roles")
local Matchmaker = ns.Matchmaker or require("core.matchmaker")
local Levels = ns.Levels or require("core.levels")
local Languages = ns.Languages or require("core.languages")

-- Questing groups: players who share at least one group or elite quest.
-- Playstyles do not apply to quests; languages do, as for dungeons.
-- Queue entries list quest keys ("176-3": quest 176, for a group of 3) where
-- dungeon entries list dungeons. The longest waiting player anchors a group
-- for one of its quests; the others are taken by how many of the anchor's
-- quests they share, then healers first, then by waiting time, passing
-- over players only when the group cannot be filled with them. Any mix of
-- roles may group (the players decide); a group is complete at the quest's
-- group size. At most one party per group, as for dungeons.
local QuestMatch = {}

local MIN_SIZE, MAX_SIZE = 2, 5
-- Search steps per round, and at most this share for one anchor, as in
-- core/matchmaker.lua.
local SEARCH_BUDGET, ANCHOR_BUDGET, KEY_MIN_BUDGET = 20000, 1000, 100

function QuestMatch.key(questId, size)
    return questId .. "-" .. size
end

-- questID (string) and group size of a quest key, or nil.
function QuestMatch.parse(key)
    local id, size = string.match(key or "", "^(%d+)%-(%d)$")
    size = tonumber(size)
    if not id or size < MIN_SIZE or size > MAX_SIZE then
        return nil
    end
    return id, size
end

local overlap, has = Matchmaker.sharedKeys, Matchmaker.wantsKey
local shares, addNames = Matchmaker.sharesPlayer, Matchmaker.addNames

local function canHeal(entry)
    for _, member in ipairs(entry.members) do
        if Roles.has(member.roles, "H") then
            return true
        end
    end
    return false
end

local function allMembers(chosen)
    local all = {}
    for _, entry in ipairs(chosen) do
        for _, member in ipairs(entry.members) do
            all[#all + 1] = member
        end
    end
    return all
end

-- One role per player, with a tank and a healer when the players allow it
-- (no role is required or limited).
local function score(counts)
    return (counts.T > 0 and 1 or 0) + (counts.H > 0 and 1 or 0)
end

local function bestAssignment(chosen, size)
    local best
    for _, option in ipairs(Roles.options(allMembers(chosen), { T = size, H = size, D = size })) do
        if not best or score(option.counts) > score(best.counts) then
            best = option
        end
    end
    return best
end

local function removeNames(entry, names)
    for _, member in ipairs(entry.members) do
        if member.name then
            names[member.name] = nil
        end
    end
end

-- nil when no group of this size can be formed around the anchor; a party
-- that is already big enough for the quest needs nobody.
-- The candidates are the entries after the anchor: list[from] onwards; for a
-- leader with a level limit every entry, since those before cannot take that
-- leader in (Matchmaker.candidateFor leaves the leader itself out).
-- Depth-first, include-first over the candidates in that order, so the
-- first set that fills the quest's size wins. At most one party per group:
-- a player still in another party cannot accept the invite.
-- budget.left: search steps this anchor may still take.
local function groupFor(anchor, list, from, key, size, taken, budget)
    local anchorParty = #anchor.members > 1
    if #anchor.members >= size or not bestAssignment({ anchor }, size) then
        return nil
    end
    local candidates = {}
    for i = (anchor.levels or anchor.rules) and 1 or from, #list do
        local entry = Matchmaker.candidateFor(anchor, list[i])
        if entry and has(entry, key) and not shares(entry, taken) and not (anchorParty and #entry.members > 1)
            and Languages.compatible(anchor.language, entry.language) then
            candidates[#candidates + 1] = { entry = entry, overlap = overlap(anchor, entry), heals = canHeal(entry) }
        end
    end
    table.sort(candidates, function(a, b)
        if a.overlap ~= b.overlap then
            return a.overlap > b.overlap
        end
        if a.heals ~= b.heals then
            return a.heals
        end
        return a.entry.rank < b.entry.rank
    end)
    local chosen = { anchor }
    local names = {}
    addNames(anchor, names)
    local function search(start, players, party)
        if players == size then
            return true
        end
        for i = start, #candidates do
            budget.left = budget.left - 1
            if budget.left <= 0 then
                return false
            end
            local entry = candidates[i].entry
            local big = #entry.members > 1
            if players + #entry.members <= size and not (big and party) and not shares(entry, names)
                and Languages.fitsAll(chosen, entry) then
                chosen[#chosen + 1] = entry
                if bestAssignment(chosen, size) then
                    addNames(entry, names)
                    if search(i + 1, players + #entry.members, party or big) then
                        return true
                    end
                    removeNames(entry, names)
                end
                chosen[#chosen] = nil
            end
        end
        return false
    end
    if not search(1, #anchor.members, anchorParty) then
        return nil
    end
    local total = 0
    for i = 2, #chosen do
        total = total + overlap(anchor, chosen[i])
    end
    return { key = key, entries = chosen, overlap = total }
end

-- A party in the group leads it, so no party has to break up. Places a party
-- reserved for players it invited from WoW's Group Finder go into `missing`,
-- as in a dungeon proposal.
local function finish(group, size)
    local option = bestAssignment(group.entries, size)
    local parts, at, missing = {}, 0, ""
    for i, entry in ipairs(group.entries) do
        local list = {}
        for _, member in ipairs(entry.members) do
            at = at + 1
            if member.reserved then
                missing = missing .. option.assignment[at]
            else
                list[#list + 1] = { name = member.name, role = option.assignment[at] }
            end
        end
        parts[i] = { id = entry.id, members = list, size = #entry.members, source = entry.source,
            composer = entry.levels ~= nil }
    end
    local leader, assigned, sources, members = Matchmaker.orderByLeader(parts)
    return {
        dungeon = group.key,
        entries = sources,
        assigned = assigned,
        leader = leader.id,
        members = members,
        missing = Roles.fromCounts(Roles.countLetters(missing)),
    }
end

-- Same shape as Matchmaker.findGroups; slots are not used (the quest key
-- sets the size).
-- now: server time, for a leader's level limit (core/levels.lua).
function QuestMatch.findGroups(entries, _, now)
    local sorted = {}
    for i, entry in ipairs(Matchmaker.sortByPriority(entries)) do
        local members = Roles.withReserved(entry.members, entry.reserved)
        sorted[i] = {
            id = entry.id, dungeons = entry.dungeons, members = members, rank = i,
            players = #members, source = entry, levels = now and Levels.active(entry.levels, now) or nil,
            language = Languages.decode(entry.language),
        }
    end
    local groups, taken = {}, {}
    local budget = { left = SEARCH_BUDGET }
    -- One pass is enough: the search is exhaustive and a group only takes
    -- players away, so an anchor that found nothing never finds a group later.
    for index, anchor in ipairs(sorted) do
        if budget.left <= 0 then
            break
        end
        local best
        if not shares(anchor, taken) then
            local keys = {}
            for i, key in ipairs(anchor.dungeons) do
                keys[i] = key
            end
            table.sort(keys)
            local perKey = math.max(KEY_MIN_BUDGET, math.floor(ANCHOR_BUDGET / math.max(1, #keys)))
            for _, key in ipairs(keys) do
                local _, size = QuestMatch.parse(key)
                local share = { left = math.min(budget.left, perKey) }
                local start = share.left
                local group = size and start > 0 and groupFor(anchor, sorted, index + 1, key, size, taken, share)
                budget.left = budget.left - (start - share.left)
                if group and (not best or group.overlap > best.overlap) then
                    best = group
                end
            end
        end
        if best then
            for _, entry in ipairs(best.entries) do
                addNames(entry, taken)
            end
            local _, size = QuestMatch.parse(best.key)
            groups[#groups + 1] = finish(best, size)
        end
    end
    return groups
end

function QuestMatch.findPartialGroup()
    return nil
end

ns.QuestMatch = QuestMatch
return QuestMatch
