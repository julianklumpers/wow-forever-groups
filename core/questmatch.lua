local _, ns = ...
ns = ns or {}

local Roles = ns.Roles or require("core.roles")
local Matchmaker = ns.Matchmaker or require("core.matchmaker")

-- Questing groups: players who share at least one group or elite quest.
-- Playstyles do not apply to quests.
-- Queue entries list quest keys ("176-3": quest 176, for a group of 3) where
-- dungeon entries list dungeons. The longest waiting player anchors a group
-- for one of its quests; the others are taken by how many of the anchor's
-- quests they share, then healers first, then by waiting time. A group has at
-- most one tank and one healer and is complete at the quest's group size.
local QuestMatch = {}

local MIN_SIZE, MAX_SIZE = 2, 5

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

local function overlap(a, b)
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

local function has(entry, key)
    for _, other in ipairs(entry.dungeons) do
        if other == key then
            return true
        end
    end
    return false
end

local function canHeal(entry)
    for _, member in ipairs(entry.members) do
        if Roles.has(member.roles, "H") then
            return true
        end
    end
    return false
end

local function shares(entry, names)
    for _, member in ipairs(entry.members) do
        if member.name and names[member.name] then
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

-- The assignment that fills the tank and healer places when it can.
local function bestAssignment(chosen, size)
    local best
    for _, option in ipairs(Roles.options(allMembers(chosen), { T = 1, H = 1, D = size })) do
        if not best or option.counts.T + option.counts.H > best.counts.T + best.counts.H then
            best = option
        end
    end
    return best
end

local function addNames(entry, names)
    for _, member in ipairs(entry.members) do
        if member.name then
            names[member.name] = true
        end
    end
end

-- nil when no group of this size can be formed around the anchor; a party
-- that is already big enough for the quest needs nobody.
local function groupFor(anchor, later, key, size, taken)
    if #anchor.members >= size or not bestAssignment({ anchor }, size) then
        return nil
    end
    local candidates = {}
    for _, entry in ipairs(later) do
        if has(entry, key) and not shares(entry, taken) then
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
    local chosen, players = { anchor }, #anchor.members
    local names = {}
    addNames(anchor, names)
    for _, candidate in ipairs(candidates) do
        local entry = candidate.entry
        if players == size then
            break
        end
        if players + #entry.members <= size and not shares(entry, names) then
            chosen[#chosen + 1] = entry
            if bestAssignment(chosen, size) then
                players = players + #entry.members
                addNames(entry, names)
            else
                chosen[#chosen] = nil
            end
        end
    end
    if players < size then
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
        parts[i] = { id = entry.id, members = list, size = #entry.members, source = entry.source }
    end
    local leader = Matchmaker.chooseLeaderEntry(parts)
    local ordered = { leader }
    for _, part in ipairs(parts) do
        if part ~= leader then
            ordered[#ordered + 1] = part
        end
    end
    local assigned, members, sources = {}, {}, {}
    for i, part in ipairs(ordered) do
        assigned[i] = part.members
        sources[i] = part.source
        for _, member in ipairs(part.members) do
            members[#members + 1] = member
        end
    end
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
function QuestMatch.findGroups(entries)
    local sorted = {}
    for i, entry in ipairs(Matchmaker.sortByPriority(entries)) do
        local members = Roles.withReserved(entry.members, entry.reserved)
        sorted[i] = {
            id = entry.id, dungeons = entry.dungeons, members = members, rank = i,
            players = #members, source = entry,
        }
    end
    local groups, used, taken = {}, {}, {}
    local progress = true
    while progress do
        progress = false
        local remaining = {}
        for _, entry in ipairs(sorted) do
            if not used[entry.id] then
                remaining[#remaining + 1] = entry
            end
        end
        for index, anchor in ipairs(remaining) do
            local later = { unpack(remaining, index + 1) }
            local best
            if not shares(anchor, taken) then
                local keys = { unpack(anchor.dungeons) }
                table.sort(keys)
                for _, key in ipairs(keys) do
                    local _, size = QuestMatch.parse(key)
                    local group = size and groupFor(anchor, later, key, size, taken)
                    if group and (not best or group.overlap > best.overlap) then
                        best = group
                    end
                end
            end
            if best then
                for _, entry in ipairs(best.entries) do
                    used[entry.id] = true
                    addNames(entry, taken)
                end
                local _, size = QuestMatch.parse(best.key)
                groups[#groups + 1] = finish(best, size)
                progress = true
                break
            end
        end
    end
    return groups
end

function QuestMatch.findPartialGroup()
    return nil
end

ns.QuestMatch = QuestMatch
return QuestMatch
