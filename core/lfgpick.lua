local _, ns = ...
ns = ns or {}

local Roles = ns.Roles or require("core.roles")
local Fill = ns.Fill or require("core.fill")

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

-- The group's dungeon to ask for: of those the player wants, the first, or
-- with `score` (function(group, dungeon, role) -> Fill.score) the one that
-- suits best; nil when the player wants none. Also returns its score.
local function shared(group, wanted, score, role)
    local best, bestScore
    for _, id in ipairs(group.dungeons) do
        if wanted[id] then
            if not score then
                return id
            end
            local this = score(group, id, role)
            if not best or Fill.better(this, bestScore) then
                best, bestScore = id, this
            end
        end
    end
    return best, bestScore
end

local ASK_ORDER = { "T", "H", "D" }

-- Without known open places: the role groups lack most, and a tank last, as
-- battleground and questing groups have little use for one.
local UNKNOWN_ORDER = { "H", "D", "T" }

-- The one role to offer a group: of the player's roles ("HD"), the scarcest
-- it still needs (tank, then healer, then DPS); with its open places
-- unknown (or none of them fitting), healer, then DPS, then tank. The player
-- then joins with that role.
function LfgPick.askRole(roles, remaining)
    roles = roles or ""
    for _, role in ipairs(remaining and ASK_ORDER or {}) do
        if Roles.has(roles, role) and (remaining[role] or 0) > 0 then
            return role
        end
    end
    for _, role in ipairs(UNKNOWN_ORDER) do
        if Roles.has(roles, role) then
            return role
        end
    end
    return nil
end

-- opts: roles ("D", "TD"), dungeons (set of ids), exclude (set of group ids),
-- max, score (function(group, dungeon, role) -> Fill.score: how the group
-- would turn out with the player in it, from who is available now;
-- optional), steps (function(group, dungeon) -> zones between the group's
-- furthest member and the dungeon, or nil when not known; optional). Returns
-- up to max { id, role, tank, healer, dps, score }: the groups that need one
-- of the roles; listings up for half an hour or more last; then the group
-- that would turn out best, then the one closest to the dungeon, then the
-- nearest to full first (they start soonest), then the most recently listed.
-- role (and the one flag set) is the one role offered (LfgPick.askRole).
function LfgPick.groupsToApply(groups, opts)
    local exclude = opts.exclude or {}
    local candidates = {}
    for _, group in ipairs(groups) do
        local role = not exclude[group.id] and LfgPick.askRole(opts.roles, group.remaining)
        local dungeon, score
        if role and group.remaining[role] > 0 then
            dungeon, score = shared(group, opts.dungeons, opts.score, role)
        end
        if dungeon then
            candidates[#candidates + 1] = { group = group, role = role, offer = { [role] = true },
                dungeon = dungeon, score = score, steps = opts.steps and opts.steps(group, dungeon) or math.huge }
        end
    end
    table.sort(candidates, function(a, b)
        local oldA, oldB = LfgPick.isOld(a.group), LfgPick.isOld(b.group)
        if oldA ~= oldB then
            return oldB
        end
        if a.score and (Fill.better(a.score, b.score) or Fill.better(b.score, a.score)) then
            return Fill.better(a.score, b.score)
        end
        if a.steps ~= b.steps then
            return a.steps < b.steps
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
        result[i] = { id = c.group.id, leader = c.group.leader, dungeon = c.dungeon, role = c.role,
            tank = c.offer.T == true, healer = c.offer.H == true, dps = c.offer.D == true, score = c.score }
    end
    return result
end

-- The role to join a group with: of the player's roles ("TD"), DPS when
-- the group still has a DPS place, else tank, else healer. remaining: the
-- group's open places per role, or nil when unknown (then the first of the
-- player's roles in that order).
local JOIN_ORDER = { "D", "T", "H" }

-- The open places an invite asks for (PARTY_INVITE_REQUEST's tank, healer
-- and damage flags), or nil when it names none.
function LfgPick.inviteRoles(tank, healer, dps)
    if not (tank or healer or dps) then
        return nil
    end
    return { T = tank and 1 or 0, H = healer and 1 or 0, D = dps and 1 or 0 }
end

function LfgPick.joinRole(roles, remaining)
    roles = roles or ""
    for _, role in ipairs(JOIN_ORDER) do
        if Roles.has(roles, role) and (not remaining or (remaining[role] or 0) > 0) then
            return role
        end
    end
    for _, role in ipairs(JOIN_ORDER) do
        if Roles.has(roles, role) then
            return role
        end
    end
    return nil
end

ns.LfgPick = LfgPick
return LfgPick
