local _, ns = ...

local Dungeons = ns.Dungeons
local Log = ns.Log

-- Where each dungeon's entrance is, to put a waypoint there once the group is
-- complete. WoW's own entrances (the dungeon pins of the world map) come
-- first, then the built-in ones (core/dungeons.lua). For a dungeon with
-- neither, the spot a Forever Groups player stood on just before walking in is
-- saved and shared over the channel.
local Entrances = {}

local PREFIX = "v1|E|"
local REQUEST = "v1|E?|"
local FRESH = 30
local ANSWER_DELAY = 4
local AT_ENTRANCE = 40

local last
local asked = {}
local answering = {}
local fromWoW = {}
-- The cosmic map, then Kalimdor and the Eastern Kingdoms in case the client
-- has no cosmic map; children are looked up with all descendants.
local WORLD_ROOTS = { 946, 1414, 1415 }

local function learned()
    ns.db.entrances = ns.db.entrances or {}
    return ns.db.entrances
end

-- Every zone and city map of the world, to look for dungeon pins on.
local function worldMaps()
    local maps, seen = {}, {}
    local function add(map)
        if map and not seen[map] then
            seen[map] = true
            maps[#maps + 1] = map
        end
    end
    local zone = Enum and Enum.UIMapType and Enum.UIMapType.Zone
    for _, root in ipairs(WORLD_ROOTS) do
        local ok, children = pcall(C_Map.GetMapChildrenInfo, root, zone, true)
        for _, child in ipairs(ok and type(children) == "table" and children or {}) do
            add(child.mapID)
        end
    end
    for _, entrance in pairs(learned()) do
        add(entrance.map)
    end
    return maps
end

-- Reads the dungeon entrances WoW shows on the world map for every map
-- that has a dungeon; also gives each dungeon's Adventure Guide id.
function Entrances.loadFromWoW()
    local api = C_EncounterJournal and C_EncounterJournal.GetDungeonEntrancesForMap
    if type(api) ~= "function" then
        Log.debug("dungeon entrances from WoW: not available")
        return
    end
    local found, pins, maps, unknown = 0, 0, worldMaps(), {}
    for _, map in ipairs(maps) do
        local ok, list = pcall(api, map)
        for _, pin in ipairs(ok and type(list) == "table" and list or {}) do
            pins = pins + 1
            local x, y
            if type(pin.position) == "table" and pin.position.GetXY then
                x, y = pin.position:GetXY()
            end
            local ids = x and Dungeons.forArea(pin.name) or {}
            if #ids == 0 then
                unknown[#unknown + 1] = tostring(pin.name)
            end
            for _, id in ipairs(ids) do
                if not fromWoW[id] then
                    found = found + 1
                end
                fromWoW[id] = { map = map, x = x, y = y, journal = pin.journalInstanceID }
            end
        end
    end
    Log.debug("dungeon entrances from WoW: %d dungeons (%d maps, %d pins%s)", found, #maps, pins,
        #unknown > 0 and ("; not ours: " .. table.concat(unknown, ", ")) or "")
end

-- The dungeon's id in WoW's Adventure Guide, when WoW gave one.
function Entrances.journalInstance(id)
    return fromWoW[id] and fromWoW[id].journal
end

-- { map, x, y, detail, learned = true|false } or nil.
function Entrances.get(id)
    local known = Dungeons.knownEntrance(id)
    local wow = fromWoW[id]
    if wow then
        return { map = wow.map, x = wow.x, y = wow.y, detail = known and known.detail, learned = false }
    end
    if known then
        return { map = known.map, x = known.x, y = known.y, detail = known.detail, learned = false }
    end
    local saved = learned()[id]
    if saved then
        return { map = saved.map, x = saved.x, y = saved.y, learned = true }
    end
    return nil
end

local function encode(id, entrance)
    return string.format("%s%s|%d|%d|%d", PREFIX, id, entrance.map, math.floor(entrance.x * 1000 + 0.5),
        math.floor(entrance.y * 1000 + 0.5))
end

local function store(id, map, x, y)
    learned()[id] = { map = map, x = x, y = y }
end

local function playerPosition()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then
        return nil
    end
    local map = C_Map.GetBestMapForUnit("player")
    local position = map and C_Map.GetPlayerMapPosition(map, "player")
    if not position then
        return nil
    end
    local x, y = position:GetXY()
    if not x or (x == 0 and y == 0) then
        return nil
    end
    return map, x, y
end

-- Every tick outside instances: remember where the player stands.
function Entrances.tick()
    if IsInInstance() then
        return
    end
    local map, x, y = playerPosition()
    if map then
        last = { map = map, x = x, y = y, at = GetTime() }
    end
end

local function onEnteringWorld()
    local inInstance, kind = IsInInstance()
    if not inInstance or kind ~= "party" or not last or GetTime() - last.at > FRESH then
        return
    end
    local name = GetInstanceInfo()
    for _, id in ipairs(Dungeons.forArea(name)) do
        if not learned()[id] and not fromWoW[id] and not Dungeons.knownEntrance(id) then
            store(id, last.map, last.x, last.y)
            Log.debug("learned the entrance of %s", Dungeons.name(id))
            ns.Comm.send(encode(id, learned()[id]))
        end
    end
end

-- From the Forever Groups channel; returns true when the message was ours.
function Entrances.onMessage(sender, text)
    if string.sub(text, 1, #REQUEST) == REQUEST then
        local id = string.sub(text, #REQUEST + 1)
        if learned()[id] and not Dungeons.knownEntrance(id) and sender ~= ns.selfName and not answering[id] then
            answering[id] = true
            C_Timer.After(math.random() * ANSWER_DELAY, function()
                if answering[id] then
                    answering[id] = nil
                    ns.Comm.send(encode(id, learned()[id]))
                end
            end)
        end
        return true
    end
    if string.sub(text, 1, #PREFIX) ~= PREFIX then
        return false
    end
    local id, map, x, y = string.match(text, "^v1|E|([%w]+)|(%d+)|(%d+)|(%d+)$")
    answering[id or ""] = nil
    map, x, y = tonumber(map), tonumber(x), tonumber(y)
    if id and Dungeons.get(id) and map and map > 0 and x <= 1000 and y <= 1000 and not learned()[id] then
        store(id, map, x / 1000, y / 1000)
        Log.debug("%s shared the entrance of %s", sender, Dungeons.name(id))
    end
    return true
end

-- Asks the channel once for an entrance nobody here has learned yet.
function Entrances.request(id)
    if learned()[id] or Dungeons.knownEntrance(id) or asked[id] or not ns.Comm.selfName then
        return
    end
    asked[id] = true
    ns.Comm.send(REQUEST .. id)
end

function Entrances.setWaypoint(id)
    local entrance = Entrances.get(id)
    if not entrance or not (C_Map and C_Map.SetUserWaypoint and UiMapPoint) then
        return false
    end
    local ok = pcall(C_Map.SetUserWaypoint, UiMapPoint.CreateFromCoordinates(entrance.map, entrance.x, entrance.y))
    if not ok then
        return false
    end
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
        pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
    end
    Log.info("Waypoint set to the entrance of %s.%s", Dungeons.name(id),
        entrance.detail and (" " .. entrance.detail .. ".") or "")
    return true
end

-- Yards from a party unit to the entrance, or nil when that cannot be told
-- (another map, inside an instance, or the client hides the position).
function Entrances.distance(id, unit)
    local entrance = Entrances.get(id)
    if not entrance or not (C_Map and C_Map.GetPlayerMapPosition and C_Map.GetMapWorldSize) then
        return nil
    end
    local ok, position = pcall(C_Map.GetPlayerMapPosition, entrance.map, unit)
    if not ok or not position then
        return nil
    end
    local x, y = position:GetXY()
    local width, height = C_Map.GetMapWorldSize(entrance.map)
    if not x or not width or width == 0 then
        return nil
    end
    local dx, dy = (x - entrance.x) * width, (y - entrance.y) * height
    return math.sqrt(dx * dx + dy * dy)
end

function Entrances.isAt(yards)
    return yards ~= nil and yards <= AT_ENTRANCE
end

function Entrances.init()
    ns.on("PLAYER_ENTERING_WORLD", onEnteringWorld)
    ns.on("ZONE_CHANGED_NEW_AREA", onEnteringWorld)
end

ns.Entrances = Entrances
