local _, ns = ...
ns = ns or {}

local Roles = ns.Roles or require("core.roles")
local Matchmaker = ns.Matchmaker or require("core.matchmaker")
local Languages = ns.Languages or require("core.languages")

-- Battleground groups: players waiting for the same battleground in the same
-- level bracket. Queue entries list battleground keys ("wsg-10") where
-- dungeon entries list dungeons. The longest waiting player anchors a group
-- for one of its keys; the others are taken by how many keys they share,
-- then by waiting time, up to a party of five. Two players are enough: the
-- leader fills the rest from WoW's Group Finder, and a battleground takes
-- any group. Only players who take each other's language are grouped
-- (core/languages.lua). Parties never merge with each other, so at most one
-- entry in a group has more than one player; places a party keeps for
-- players it invited from the Group Finder count as players. Roles barely
-- matter in a battleground: each group gets a healer when one of them heals,
-- everyone else plays DPS when they can.
local BgMatch = {}

local MAX_PLAYERS = 5

local has, overlap = Matchmaker.wantsKey, Matchmaker.sharedKeys
local names, shares = Matchmaker.addNames, Matchmaker.sharesPlayer

-- The candidates are the entries after the anchor: list[from] onwards.
local function groupFor(anchor, list, from, key, taken)
    local candidates = {}
    for i = from, #list do
        local entry = list[i]
        if has(entry, key) and not shares(entry, taken) and Languages.compatible(anchor.language, entry.language) then
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
    local placed = {}
    names(anchor, placed)
    for _, candidate in ipairs(candidates) do
        local entry = candidate.entry
        local big = #entry.members > 1
        if players + #entry.members <= MAX_PLAYERS and not (big and party) and not shares(entry, placed)
            and Languages.fitsAll(chosen, entry) then
            chosen[#chosen + 1] = entry
            names(entry, placed)
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

-- Same shape as Matchmaker.findGroups; slots are not used.
function BgMatch.findGroups(entries)
    local sorted = {}
    for i, entry in ipairs(Matchmaker.sortByPriority(entries)) do
        sorted[i] = { id = entry.id, dungeons = entry.dungeons, members = Roles.withReserved(entry.members,
            entry.reserved), rank = i, source = entry, language = Languages.decode(entry.language) }
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
                local keys = {}
                for i, key in ipairs(anchor.dungeons) do
                    keys[i] = key
                end
                table.sort(keys)
                for _, key in ipairs(keys) do
                    local group = groupFor(anchor, remaining, index + 1, key, taken)
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
