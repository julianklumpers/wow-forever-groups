local _, ns = ...
ns = ns or {}

local Roles = ns.Roles or require("core.roles")

-- Chooses groups listed in WoW's Group Finder to apply to.
-- A group: { id, leader, dungeons = { ... }, remaining = { T, H, D }, age }.
local LfgPick = {}

-- A listing up this long and still not full is often left by an away
-- leader: those are asked last.
LfgPick.OLD_LISTING = 30 * 60

function LfgPick.isOld(group)
    return (group.age or 0) >= LfgPick.OLD_LISTING
end

local function openSlots(group)
    return group.remaining.T + group.remaining.H + group.remaining.D
end

-- The first of the group's dungeons that the player wants, or nil.
local function shared(group, wanted)
    for _, id in ipairs(group.dungeons) do
        if wanted[id] then
            return id
        end
    end
    return nil
end

-- opts: roles ("D", "TD"), dungeons (set of ids), exclude (set of group ids),
-- max. Returns up to max { id, tank, healer, dps }: the groups that need one
-- of the roles; listings up for half an hour or more last; then the nearest
-- to full first (they start soonest), then the most recently listed. The
-- flags offer only roles the group still needs.
function LfgPick.groupsToApply(groups, opts)
    local exclude = opts.exclude or {}
    local candidates = {}
    for _, group in ipairs(groups) do
        local dungeon = not exclude[group.id] and shared(group, opts.dungeons)
        if dungeon then
            local offer = {}
            for _, role in ipairs(Roles.ORDER) do
                offer[role] = Roles.has(opts.roles, role) and group.remaining[role] > 0
            end
            if offer.T or offer.H or offer.D then
                candidates[#candidates + 1] = { group = group, offer = offer, dungeon = dungeon }
            end
        end
    end
    table.sort(candidates, function(a, b)
        local oldA, oldB = LfgPick.isOld(a.group), LfgPick.isOld(b.group)
        if oldA ~= oldB then
            return oldB
        end
        local sa, sb = openSlots(a.group), openSlots(b.group)
        if sa ~= sb then
            return sa < sb
        end
        if (a.group.age or 0) ~= (b.group.age or 0) then
            return (a.group.age or 0) < (b.group.age or 0)
        end
        return a.group.id < b.group.id
    end)
    local result = {}
    for i = 1, math.min(opts.max or #candidates, #candidates) do
        local c = candidates[i]
        result[i] = { id = c.group.id, leader = c.group.leader, dungeon = c.dungeon,
            tank = c.offer.T, healer = c.offer.H, dps = c.offer.D }
    end
    return result
end

ns.LfgPick = LfgPick
return LfgPick
