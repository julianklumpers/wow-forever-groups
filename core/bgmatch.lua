local _, ns = ...
ns = ns or {}

local Roles = ns.Roles or require("core.roles")
local Matchmaker = ns.Matchmaker or require("core.matchmaker")

-- Battleground groups: players waiting for the same battleground in the same
-- level bracket. Queue entries list battleground keys ("wsg-10") where
-- dungeon entries list dungeons. The longest waiting player anchors a group
-- for one of its keys; the others are taken by how many keys they share,
-- then by waiting time, up to a party of five. Two players are enough: the
-- leader fills the rest from WoW's Group Finder, and a battleground takes
-- any group. Parties never merge with each other, so at most one entry in a
-- group has more than one player; places a party keeps for players it
-- invited from the Group Finder count as players. Roles barely matter in a battleground:
-- each group gets a healer when one of them heals, everyone else plays DPS
-- when they can.
local BgMatch = {}

local MAX_PLAYERS = 5

local function has(entry, key)
    for _, other in ipairs(entry.dungeons) do
        if other == key then
            return true
        end
    end
    return false
end

local function overlap(a, b)
    local count = 0
    for _, key in ipairs(b.dungeons) do
        if has(a, key) then
            count = count + 1
        end
    end
    return count
end

local function names(entry, into)
    for _, member in ipairs(entry.members) do
        if member.name then
            into[member.name] = true
        end
    end
end

local function shares(entry, taken)
    for _, member in ipairs(entry.members) do
        if member.name and taken[member.name] then
            return true
        end
    end
    return false
end

local function groupFor(anchor, later, key, taken)
    local candidates = {}
    for _, entry in ipairs(later) do
        if has(entry, key) and not shares(entry, taken) then
            candidates[#candidates + 1] = { entry = entry, overlap = overlap(anchor, entry) }
        end
    end
    table.sort(candidates, function(a, b)
        if a.overlap ~= b.overlap then
            return a.overlap > b.overlap
        end
        return a.entry.rank < b.entry.rank
    end)
    local chosen, players, party = { anchor }, #anchor.members, #anchor.members > 1
    local total = 0
    for _, candidate in ipairs(candidates) do
        local entry = candidate.entry
        local big = #entry.members > 1
        if players + #entry.members <= MAX_PLAYERS and not (big and party) then
            chosen[#chosen + 1] = entry
            players = players + #entry.members
            party = party or big
            total = total + candidate.overlap
        end
    end
    if #chosen < 2 then
        return nil
    end
    return { key = key, entries = chosen, overlap = total, players = players }
end

-- One healer when someone can heal, then DPS where possible. Places kept
-- for Group Finder invites go into missing, as in a dungeon proposal.
local function assign(chosen)
    local healer, missing = false, ""
    local parts = {}
    for i, entry in ipairs(chosen) do
        local list = {}
        for _, member in ipairs(entry.members) do
            if member.reserved then
                missing = missing .. member.roles
            else
                local role
                if not healer and Roles.has(member.roles, "H") then
                    role, healer = "H", true
                elseif Roles.has(member.roles, "D") then
                    role = "D"
                else
                    role = string.sub(member.roles, 1, 1)
                end
                list[#list + 1] = { name = member.name, role = role }
            end
        end
        parts[i] = { id = entry.id, members = list, size = #entry.members, source = entry.source }
    end
    return parts, missing
end

-- A party in the group leads it, else the player who would like to lead.
local function finish(group)
    local parts, missing = assign(group.entries)
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

-- Same shape as Matchmaker.findGroups; slots are not used.
function BgMatch.findGroups(entries)
    local sorted = {}
    for i, entry in ipairs(Matchmaker.sortByPriority(entries)) do
        sorted[i] = { id = entry.id, dungeons = entry.dungeons, members = Roles.withReserved(entry.members,
            entry.reserved), rank = i, source = entry }
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
            local best
            if #anchor.members < MAX_PLAYERS and not shares(anchor, taken) then
                local later = { unpack(remaining, index + 1) }
                local keys = { unpack(anchor.dungeons) }
                table.sort(keys)
                for _, key in ipairs(keys) do
                    local group = groupFor(anchor, later, key, taken)
                    if group and (not best or group.players > best.players
                        or (group.players == best.players and group.overlap > best.overlap)) then
                        best = group
                    end
                end
            end
            if best then
                for _, entry in ipairs(best.entries) do
                    used[entry.id] = true
                    names(entry, taken)
                end
                groups[#groups + 1] = finish(best)
                progress = true
                break
            end
        end
    end
    return groups
end

function BgMatch.findPartialGroup()
    return nil
end

ns.BgMatch = BgMatch
return BgMatch
