local _, ns = ...

local Dungeons = ns.Dungeons

-- Where the members of a followed dungeon group are: inside the dungeon, or
-- how far from its entrance. WoW gives no map position of a party member
-- while one of the two is in an instance, so members with Forever Groups tell
-- the party where they are (PARTY addon messages).
local GroupPlaces = {}

local PREFIX = "v1|GP|"
local CHECK = 5
local HEARTBEAT = 30
local STALE = 75

local reports = {}
local sent
local ticks = 0

local function insideOf(dungeon)
    local inInstance = IsInInstance()
    if not inInstance then
        return false
    end
    for _, id in ipairs(Dungeons.forArea((GetInstanceInfo()))) do
        if id == dungeon then
            return true
        end
    end
    return false
end

-- "in", yards (rounded to 10), false when far away or elsewhere, or nil when
-- the entrance is not known.
function GroupPlaces.mine(dungeon)
    if insideOf(dungeon) then
        return "in"
    elseif IsInInstance() then
        return false
    end
    local yards = ns.Entrances.distance(dungeon, "player")
    if yards then
        return math.floor(yards / 10 + 0.5) * 10
    end
    return ns.Entrances.get(dungeon) and false or nil
end

local function call(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local ok, value = pcall(fn, ...)
    return ok and value or nil
end

-- While the player is inside: a member who is in sight, or on the same map
-- of the dungeon, is inside too. Works for members without Forever Groups.
local function seenInside(unit)
    local visible = call(UnitIsVisible, unit)
    if not ns.isSecret(visible) and visible == true then
        return true
    end
    local getMap = C_Map and C_Map.GetBestMapForUnit
    local mine, theirs = call(getMap, "player"), call(getMap, unit)
    if ns.isSecret(mine) or ns.isSecret(theirs) then
        return false
    end
    return type(mine) == "number" and mine == theirs
end

-- Where a member is, as GroupPlaces.mine; unit: the member's party unit.
function GroupPlaces.of(name, unit, dungeon)
    if name == ns.selfName then
        return GroupPlaces.mine(dungeon)
    end
    if unit and insideOf(dungeon) and seenInside(unit) then
        return "in"
    end
    if unit and not IsInInstance() then
        local yards = ns.Entrances.distance(dungeon, unit)
        if yards then
            return yards
        end
    end
    local report = reports[name]
    if report and report.dungeon == dungeon and GetTime() - report.at <= STALE then
        return report.place
    end
    return nil
end

local function encode(place)
    if place == "in" then
        return "in"
    end
    return place and tostring(place) or "far"
end

function GroupPlaces.tick()
    ticks = ticks + 1
    if ticks % CHECK ~= 0 then
        return
    end
    local dungeon = ns.GroupView.trackedDungeon()
    if not dungeon then
        sent = nil
        return
    end
    local place = GroupPlaces.mine(dungeon)
    if place == nil then
        return
    end
    local text = encode(place)
    if sent and sent.dungeon == dungeon and sent.text == text and GetTime() - sent.at < HEARTBEAT then
        return
    end
    sent = { dungeon = dungeon, text = text, at = GetTime() }
    ns.Comm.sendParty(PREFIX .. dungeon .. "|" .. text)
end

-- From the PARTY addon channel; returns true when the message was ours.
function GroupPlaces.onMessage(sender, text)
    if string.sub(text, 1, #PREFIX) ~= PREFIX then
        return false
    end
    local dungeon, place = string.match(text, "^v1|GP|([%w]+)|(%w+)$")
    if dungeon and Dungeons.get(dungeon) then
        if place == "in" then
            reports[sender] = { dungeon = dungeon, place = "in", at = GetTime() }
        elseif place == "far" then
            reports[sender] = { dungeon = dungeon, place = false, at = GetTime() }
        elseif tonumber(place) and tonumber(place) < 1000000 then
            reports[sender] = { dungeon = dungeon, place = tonumber(place), at = GetTime() }
        end
    end
    return true
end

function GroupPlaces.init()
    local function soon()
        sent = nil
    end
    ns.on("PLAYER_ENTERING_WORLD", soon)
    ns.on("GROUP_ROSTER_UPDATE", soon)
end

ns.GroupPlaces = GroupPlaces
