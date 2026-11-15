local _, ns = ...
ns = ns or {}

-- A leader's level limit for the players joining their group ("Limit
-- levels"): a lowest and a highest level, 0 for no limit on that side, until
-- `untilAt` (server time) after which anyone may join. On the wire it is one
-- field of the queue entry: "<until>:<min>:<max>".
local Levels = {}

local MAX_LEVEL = 99

function Levels.encode(range)
    if not range then
        return nil
    end
    local low, high = math.floor(range.min or 0), math.floor(range.max or 0)
    if low <= 0 and high <= 0 then
        return nil
    end
    return string.format("%d:%d:%d", math.floor(range.untilAt or 0), math.max(0, low), math.max(0, high))
end

function Levels.decode(text)
    if type(text) ~= "string" then
        return nil
    end
    local untilAt, low, high = string.match(text, "^(%d+):(%d+):(%d+)$")
    if not untilAt then
        return nil
    end
    low, high = tonumber(low), tonumber(high)
    if (low == 0 and high == 0) or low > MAX_LEVEL or high > MAX_LEVEL or (high > 0 and low > high) then
        return nil
    end
    return { untilAt = tonumber(untilAt), min = low, max = high }
end

function Levels.isValid(text)
    return Levels.decode(text) ~= nil
end

-- The limit still in force at `now`.
function Levels.active(text, now)
    local range = Levels.decode(text)
    if range and (range.untilAt == 0 or (type(now) == "number" and now < range.untilAt)) then
        return range
    end
    return nil
end

-- Whether a player of this level may join; an unknown level may not.
function Levels.fits(range, level)
    if not range then
        return true
    end
    level = tonumber(level)
    if not level then
        return false
    end
    return (range.min == 0 or level >= range.min) and (range.max == 0 or level <= range.max)
end

-- Whether every player of the entry fits (placeholders for invites on their
-- way have no level and are left out).
function Levels.entryFits(range, entry)
    for _, member in ipairs(entry.members) do
        if not member.reserved and not Levels.fits(range, member.level) then
            return false
        end
    end
    return true
end

-- Whether a level range (a dungeon's) shares a level with the limit.
function Levels.overlaps(range, low, high)
    if not range or not low or not high then
        return true
    end
    return (range.min == 0 or high >= range.min) and (range.max == 0 or low <= range.max)
end

ns.Levels = Levels
return Levels
