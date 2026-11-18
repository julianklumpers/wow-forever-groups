local _, ns = ...

local Dungeons = ns.Dungeons
local Log = ns.Log
local Zones = ns.Zones

-- Which zones border each other, read from WoW's map: a grid of points over
-- each continent, each named by the zone it lies in (C_Map.GetMapInfoAtPosition,
-- /fgp zonegraph on 2026-11-18: 15-17 ms per continent). Two zones on
-- neighbouring points border each other; sea between them does not count,
-- except a strait narrower than the grid. Built once, the first time a
-- distance is asked for.
local ZoneMap = {}

local CONTINENTS = { 1414, 1415 }
local GRID_W, GRID_H = 150, 100
local ZONE_TYPE, CONTINENT_TYPE = 3, 2

-- { near = { [zone] = { [zone] = true } }, names = { [name] = zone },
--   starts = { [dungeon] = { zone, ... } } (optional, for tests) }
local graph
local built = false
local perDungeon = {}

local function mapTypes()
    local types = Enum and Enum.UIMapType
    return types and types.Zone or ZONE_TYPE, types and types.Continent or CONTINENT_TYPE
end

-- The zone a map lies in (a city's or a cave's map climbs to its zone).
local function zoneOf(map)
    local zoneType, continentType = mapTypes()
    local guard = 0
    while map and map ~= 0 and guard < 6 do
        local ok, info = pcall(C_Map.GetMapInfo, map)
        if not ok or type(info) ~= "table" or info.mapType == continentType then
            return nil
        end
        if info.mapType == zoneType then
            return map
        end
        map, guard = info.parentMapID, guard + 1
    end
    return nil
end

local function zoneAt(continent, x, y)
    local ok, info = pcall(C_Map.GetMapInfoAtPosition, continent, x, y)
    return ok and type(info) == "table" and zoneOf(info.mapID) or nil
end

local function build()
    if not (C_Map and C_Map.GetMapInfoAtPosition and C_Map.GetMapInfo) then
        return nil
    end
    local near, names = {}, {}
    local function link(a, b)
        near[a] = near[a] or {}
        near[b] = near[b] or {}
        near[a][b], near[b][a] = true, true
    end
    for _, continent in ipairs(CONTINENTS) do
        local previous = {}
        for gy = 1, GRID_H do
            local row = {}
            for gx = 1, GRID_W do
                local zone = zoneAt(continent, (gx - 0.5) / GRID_W, (gy - 0.5) / GRID_H)
                row[gx] = zone
                if zone then
                    near[zone] = near[zone] or {}
                    if row[gx - 1] and row[gx - 1] ~= zone then
                        link(zone, row[gx - 1])
                    end
                    if previous[gx] and previous[gx] ~= zone then
                        link(zone, previous[gx])
                    end
                end
            end
            previous = row
        end
    end
    local count = 0
    for zone in pairs(near) do
        local ok, info = pcall(C_Map.GetMapInfo, zone)
        if ok and type(info) == "table" and type(info.name) == "string" then
            names[info.name] = zone
            count = count + 1
        end
    end
    if count == 0 then
        return nil
    end
    Log.debug("zone map: %d zones", count)
    return { near = near, names = names }
end

local function current()
    if not built then
        built = true
        local ok, result = pcall(build)
        graph = ok and result or nil
    end
    return graph
end

-- Replaces the zone map (tests; a fresh build after a /reload otherwise).
function ZoneMap.setGraph(newGraph)
    graph, built, perDungeon = newGraph, true, {}
end

-- The dungeon's own zones: the zone of its entrance's map, and the zone (a
-- city) at the entrance's very spot when that is another one.
local function startsOf(dungeon)
    local map = current()
    if map and map.starts then
        return map.starts[dungeon]
    end
    local entrance = ns.Entrances.get(dungeon)
    local own = entrance and zoneOf(entrance.map)
    if not own then
        return nil
    end
    local starts = { own }
    local ok, info = pcall(C_Map.GetMapInfo, own)
    local continent = ok and type(info) == "table" and info.parentMapID
    local okRect, minX, maxX, minY, maxY = pcall(C_Map.GetMapRectOnMap, entrance.map, continent or 0)
    if okRect and minX and maxX then
        local spot = zoneAt(continent, minX + entrance.x * (maxX - minX), minY + entrance.y * (maxY - minY))
        if spot and spot ~= own then
            starts[2] = spot
        end
    end
    return starts
end

-- { steps = { [zone] = steps }, most } for a dungeon, or nil when its place
-- or the map is not known (then distance plays no part).
local function forDungeon(dungeon)
    if perDungeon[dungeon] == nil then
        local map, starts = current(), dungeon and startsOf(dungeon)
        if map and starts and #starts > 0 then
            local steps, most = Zones.steps(map.near, starts)
            perDungeon[dungeon] = { steps = steps, most = most }
        else
            perDungeon[dungeon] = false
        end
    end
    return perDungeon[dungeon] or nil
end

-- The zone a Group Finder area name stands for: a zone of the map, or a
-- dungeon's name (a player inside it), which counts as its entrance's zone.
function ZoneMap.zoneOfArea(area)
    local map = current()
    if not map or type(area) ~= "string" or area == "" then
        return nil
    end
    if map.names[area] then
        return map.names[area]
    end
    for _, id in ipairs(Dungeons.forArea(area)) do
        local starts = startsOf(id)
        if starts then
            return starts[1]
        end
    end
    return nil
end

-- How far a zone is from a dungeon: steps (nil for another continent or a
-- zone not on the map) and the furthest ring; nothing at all when the
-- dungeon's place or the map is not known.
function ZoneMap.distance(dungeon, zone)
    local info = forDungeon(dungeon)
    if not info then
        return
    end
    return zone and info.steps[zone] or nil, info.most
end

-- The same for a Group Finder area name. With no name at all (an older
-- client, a secret value) nothing is known.
function ZoneMap.areaDistance(dungeon, area)
    if type(area) ~= "string" or area == "" then
        return
    end
    local info = forDungeon(dungeon)
    if not info then
        return
    end
    local zone = ZoneMap.zoneOfArea(area)
    return zone and info.steps[zone] or nil, info.most
end

-- The zone a party member is in (a party unit), or nil when not known.
function ZoneMap.unitZone(unit)
    if not current() then
        return nil
    end
    local ok, map = pcall(C_Map.GetBestMapForUnit, unit)
    return ok and not ns.isSecret(map) and type(map) == "number" and zoneOf(map) or nil
end

-- The zone the player is in: inside a dungeon, its entrance's zone.
function ZoneMap.myZone()
    if not current() then
        return nil
    end
    if IsInInstance() then
        local name = GetInstanceInfo()
        local ids = type(name) == "string" and Dungeons.forArea(name) or {}
        local starts = ids[1] and startsOf(ids[1])
        return starts and starts[1] or nil
    end
    local ok, map = pcall(C_Map.GetBestMapForUnit, "player")
    return ok and not ns.isSecret(map) and type(map) == "number" and zoneOf(map) or nil
end

ns.ZoneMap = ZoneMap
