local _, ns = ...
ns = ns or {}

-- Ids go over the wire: never renumber or reuse one, only append.
-- lfg is the dungeon's activity id in WoW's Group Finder (read from the client
-- on 2026-11-11; The Stockade is not offered there). Level ranges are not
-- built in: WoW's Group Finder gives them when the addon loads
-- (Dungeons.setRange, from wow/lfglist.lua). bosses: how many bosses the
-- dungeon has without rare spawns, copied from ForeverDungeonJournal's data
-- (2026-11-11); the Adventure Guide's count wins when WoW gives one. screen:
-- the dungeon's loading screen in Forever's client, a classic one by name
-- (Interface\Glues\LoadingScreens\LoadScreen<screen>) or Forever's own by
-- file id; lfgArt: the dungeon finder's picture where the client has no
-- loading screen. Both seen in-game on 2026-11-12.
local LIST = {
    { id = "1", name = "Ragefire Chasm", short = "RFC", lfg = 798, bosses = 4, screen = "RagefireChasm" },
    { id = "2", name = "Hall of Thanes", short = "HoT", lfg = 1984, bosses = 4, screen = 7963781 },
    { id = "3", name = "Ruins of Lordaeron", short = "RoL", lfg = 1982, bosses = 6, screen = 7963782 },
    { id = "4", name = "Wailing Caverns", short = "WC", lfg = 796, bosses = 8, screen = "WailingCaverns" },
    { id = "5", name = "The Deadmines", short = "DM", lfg = 799, bosses = 8, screen = "Deadmines" },
    { id = "6", name = "Shadowfang Keep", short = "SFK", lfg = 800, bosses = 10, screen = "ShadowFangKeep" },
    { id = "7", name = "Blackfathom Deeps", short = "BFD", lfg = 801, bosses = 7, screen = "BlackFathomDeeps" },
    { id = "8", name = "The Stockade", short = "Stocks", bosses = 5, screen = "StormwindStockade" },
    { id = "9", name = "Excavation Site: Wetlands", short = "Excav", lfg = 1981, bosses = 3, screen = 7963777 },
    { id = "10", name = "City of Dalaran", short = "Dal", lfg = 1983, bosses = 7, screen = 7963775 },
    { id = "11", name = "Gnomeregan", short = "Gnomer", lfg = 803, bosses = 5, screen = "Gnomeregan" },
    { id = "12", name = "Razorfen Kraul", short = "RFK", lfg = 804, bosses = 6, screen = "RazorfenKraul" },
    { id = "13", name = "Scarlet Monastery: Graveyard", short = "SM GY", lfg = 805, bosses = 2, screen = "Monastery" },
    { id = "14", name = "Scarlet Monastery: Library", short = "SM Lib", lfg = 829, bosses = 2, screen = "Monastery" },
    { id = "15", name = "Scarlet Monastery: Armory", short = "SM Arm", lfg = 827, bosses = 1, screen = "Monastery" },
    { id = "16", name = "The Drowned City", short = "Drowned", lfg = 1985, bosses = 5 },
    { id = "17", name = "Scarlet Monastery: Cathedral", short = "SM Cath", lfg = 828, bosses = 3,
        screen = "Monastery" },
    { id = "18", name = "Razorfen Downs", short = "RFD", lfg = 806, bosses = 5, screen = "RazorfenDowns" },
    { id = "19", name = "Uldaman", short = "Ulda", lfg = 807, bosses = 8, screen = "Uldaman" },
    { id = "20", name = "Krol'dok Stronghold", short = "Krol'dok", lfg = 1986, bosses = 6, screen = 7963780 },
    { id = "21", name = "Zul'Farrak", short = "ZF", lfg = 808, bosses = 9, screen = "ZulFarrak" },
    { id = "22", name = "Maraudon", short = "Mara", lfg = 809, bosses = 8, screen = "Maraudon" },
    { id = "23", name = "Alcaz Prison", short = "Alcaz", lfg = 1980, bosses = 5 },
    { id = "24", name = "Sunken Temple", short = "ST", lfg = 810, bosses = 7, screen = "SunkenTemple" },
    { id = "25", name = "Blackrock Depths", short = "BRD", lfg = 811, bosses = 25, screen = "BlackrockDepths" },
    { id = "26", name = "Blackmaw Hold", short = "Blackmaw", lfg = 1979, bosses = 7, screen = 7963784 },
    { id = "27", name = "Dire Maul: East", short = "DM East", lfg = 813, bosses = 5, screen = "DireMaul" },
    { id = "28", name = "Lower Blackrock Spire", short = "LBRS", lfg = 812, bosses = 9, screen = "BlackrockSpire" },
    { id = "29", name = "Upper Blackrock Spire", short = "UBRS", lfg = 837, bosses = 7, screen = "BlackrockSpire" },
    { id = "30", name = "Dire Maul: North", short = "DM North", lfg = 815, bosses = 7, screen = "DireMaul" },
    { id = "31", name = "Dire Maul: West", short = "DM West", lfg = 814, bosses = 6, screen = "DireMaul" },
    { id = "32", name = "Scholomance", short = "Scholo", lfg = 797, bosses = 13, screen = "Scholomance" },
    { id = "33", name = "Shaper's Terrace", short = "Shaper's", lfg = 1978, bosses = 10, screen = 7963783 },
    { id = "34", name = "Stratholme: Living", short = "Strat Live", lfg = 816, bosses = 6, lfgArt = "STRATHOLME" },
    { id = "35", name = "Stratholme: Undead", short = "Strat UD", lfg = 1603, bosses = 6, lfgArt = "STRATHOLME" },
}

-- Dungeon entrances ({ map = uiMapID, x, y } in 0-1 map coordinates, and how
-- to get in, in our own words). The positions are from the ForeverDungeonJournal
-- addon by Exehn (2.0.1). Forever's client has no dungeon pins
-- (GetDungeonEntrancesForMap gave none on 2026-11-11), so these come after
-- WoW's own and before learned ones.
-- luacheck: push no max line length
local ENTRANCES = {
    ["1"] = { map = 1454, x = 0.526, y = 0.490,
        detail = "In the Cleft of Shadow, Orgrimmar" },
    ["2"] = { map = 1455, x = 0.435, y = 0.520,
        detail = "Under Ironforge" },
    ["3"] = { map = 1420, x = 0.634, y = 0.674,
        detail = "In the ruins of old Lordaeron, by the Undercity" },
    ["4"] = { map = 1413, x = 0.460, y = 0.364,
        detail = "A cave at Lushwater Oasis" },
    ["5"] = { map = 1436, x = 0.425, y = 0.717,
        detail = "Under Moonbrook" },
    ["6"] = { map = 1421, x = 0.448, y = 0.678,
        detail = "North of Pyrewood Village, up the hill" },
    ["7"] = { map = 1440, x = 0.145, y = 0.142,
        detail = "On the Zoram Strand coast" },
    ["8"] = { map = 1453, x = 0.524, y = 0.700,
        detail = "In Stormwind's Canal District" },
    ["9"] = { map = 1437, x = 0.477, y = 0.562,
        detail = "In the hills south-east of Whelgar's Excavation (via Thelgen Rock): a blue misty portal beneath a big tree" },
    ["10"] = { map = 1416, x = 0.085, y = 0.593,
        detail = "Via the sewers: go down a street grate and follow the Underbelly pipe to the portal" },
    ["11"] = { map = 1426, x = 0.243, y = 0.398,
        detail = "North-west Dun Morogh: ride the lift down, then stay left in the tunnels" },
    ["12"] = { map = 1413, x = 0.429, y = 0.902,
        detail = "Southern Barrens, where the thorny passage ends" },
    ["13"] = { map = 1420, x = 0.826, y = 0.338,
        detail = "In the Scarlet Monastery courtyard: the portal on the right" },
    ["14"] = { map = 1420, x = 0.826, y = 0.338,
        detail = "In the Scarlet Monastery: the Library's own door" },
    ["15"] = { map = 1420, x = 0.826, y = 0.338,
        detail = "In the Scarlet Monastery: the Armory door (needs The Scarlet Key from the Library)" },
    ["16"] = { map = 1434, x = 0.214, y = 0.279,
        detail = "Under water west of the Vile Reef: a cave at Sunken Hollow with a large stone tablet, near the island with water elementals" },
    ["17"] = { map = 1420, x = 0.826, y = 0.338,
        detail = "In the Scarlet Monastery: the Cathedral door (needs The Scarlet Key from the Library)" },
    ["18"] = { map = 1413, x = 0.500, y = 0.920,
        detail = "Deep south of the Barrens, near Thousand Needles: through the thorn tunnel" },
    ["19"] = { map = 1418, x = 0.443, y = 0.120,
        detail = "Northern Badlands, north of Angor Fortress: the stone door at the back of the dig site cave" },
    ["20"] = { map = 2548, x = 0.375, y = 0.373,
        detail = "Hill above Sunnyglade in the northern Riverglades: the small cave west of the fortress gates" },
    ["21"] = { map = 1446, x = 0.387, y = 0.200,
        detail = "North-west Tanaris, at the gates of the troll city" },
    ["22"] = { map = 1443, x = 0.291, y = 0.625,
        detail = "Western Desolace: through the Valley of Spears to the cave below the cliffs" },
    ["23"] = { map = 1445, x = 0.753, y = 0.141,
        detail = "Alcaz Island, north-east of Dustwallow Marsh: up the hill from the dock to the prison at the north end; the portal is in the cellar" },
    ["24"] = { map = 1435, x = 0.695, y = 0.535,
        detail = "Swamp of Sorrows: dive into the Pool of Tears and go down the stairs to the temple" },
    ["25"] = { map = 1427, x = 0.348, y = 0.840,
        detail = "Blackrock Mountain (Searing Gorge / Burning Steppes): down the chain from the Spire ledge, then the lower path to the Depths" },
    ["26"] = { map = 1447, x = 0.386, y = 0.332,
        detail = "Northern Azshara, past the old furbolg gate: the long tunnel into the mountain, near the Winterspring border" },
    ["27"] = { map = 1444, x = 0.590, y = 0.450,
        detail = "Eldre'Thalas, central Feralas: the east wing, through the Broken Commons and the eastern gate" },
    ["28"] = { map = 1427, x = 0.348, y = 0.840,
        detail = "Blackrock Mountain (Searing Gorge / Burning Steppes): up to the high ledge and the Spire portal" },
    ["29"] = { map = 1427, x = 0.348, y = 0.840,
        detail = "Blackrock Mountain: the Spire portal on the high ledge, then through Lower Blackrock Spire to the sealed door" },
    ["30"] = { map = 1444, x = 0.590, y = 0.450,
        detail = "Eldre'Thalas, central Feralas: the north (Gordok) wing door, opened with the Crescent Key" },
    ["31"] = { map = 1444, x = 0.590, y = 0.450,
        detail = "Eldre'Thalas, central Feralas: the west wing door, opened with the Crescent Key" },
    ["32"] = { map = 1422, x = 0.697, y = 0.732,
        detail = "Caer Darrow, the island in Darrowmere Lake (Western Plaguelands): the crypt door behind the keep" },
    ["33"] = { map = 1449, x = 0.481, y = 0.061,
        detail = "North edge of Un'Goro Crater, above Marshal's Refuge: up the stairs to the titan temple" },
    ["34"] = { map = 1423, x = 0.300, y = 0.150,
        detail = "Eastern Plaguelands, north-west: Stratholme's main gate" },
    ["35"] = { map = 1423, x = 0.440, y = 0.190,
        detail = "Eastern Plaguelands, north: the service gate on Stratholme's east side" },
}
-- luacheck: pop

local Dungeons = { list = LIST, byId = {}, byActivity = {} }

for _, dungeon in ipairs(LIST) do
    Dungeons.byId[dungeon.id] = dungeon
    if dungeon.lfg then
        Dungeons.byActivity[dungeon.lfg] = dungeon
    end
end

-- The built-in entrance, or nil.
function Dungeons.knownEntrance(id)
    return ENTRANCES[id]
end

function Dungeons.get(id)
    return Dungeons.byId[id]
end

-- Where the picture sits in each kind of texture: classic loading screens
-- carry the WoW logo and a gold frame, Forever's own are letterboxed, the
-- dungeon finder's fill the texture. Cropped to a banner of about 2.7:1.
local ART_CROP = {
    classic = { 0.115, 0.885, 0.25, 0.82 },
    forever = { 0.055, 0.945, 0.17, 0.83 },
    lfg = { 0.02, 0.98, 0.12, 0.84 },
}

-- The dungeon's picture (a texture path or file id) and its crop
-- { left, right, top, bottom }, or nil (no picture in the client).
function Dungeons.art(id)
    local dungeon = Dungeons.byId[id]
    if not dungeon then
        return nil
    end
    if type(dungeon.screen) == "number" then
        return dungeon.screen, ART_CROP.forever
    elseif dungeon.screen then
        return "Interface\\Glues\\LoadingScreens\\LoadScreen" .. dungeon.screen, ART_CROP.classic
    elseif dungeon.lfgArt then
        return "Interface\\LFGFrame\\UI-LFG-BACKGROUND-" .. dungeon.lfgArt, ART_CROP.lfg
    end
    return nil
end

function Dungeons.name(id)
    local dungeon = Dungeons.byId[id]
    return dungeon and dungeon.name or ("dungeon " .. tostring(id))
end

-- Sets a dungeon's level range, e.g. from WoW's Group Finder.
function Dungeons.setRange(id, min, max)
    local dungeon = Dungeons.byId[id]
    if dungeon and type(min) == "number" and type(max) == "number" and min > 0 and max >= min then
        dungeon.min, dungeon.max = min, max
        return true
    end
    return false
end

-- "13-18", or "?" while the range is not known.
function Dungeons.rangeText(dungeon)
    if dungeon.min and dungeon.max then
        return string.format("%d-%d", dungeon.min, dungeon.max)
    end
    return "?"
end

function Dungeons.forLevel(level)
    local result = {}
    for _, dungeon in ipairs(LIST) do
        if dungeon.min and level >= dungeon.min and level <= dungeon.max then
            result[#result + 1] = dungeon
        end
    end
    return result
end

local function withoutArticle(name)
    return (string.gsub(string.lower(name), "^the ", ""))
end

-- Accepts ids ("5"), short names ("dm", "sm gy"), full names with or without
-- "The", or an unambiguous part of a name ("deadmi"), case-insensitively.
function Dungeons.find(text)
    if Dungeons.byId[text] then
        return Dungeons.byId[text]
    end
    local wanted = string.lower(text)
    for _, dungeon in ipairs(LIST) do
        if string.lower(dungeon.short) == wanted or string.lower(dungeon.name) == wanted
            or withoutArticle(dungeon.name) == wanted then
            return dungeon
        end
    end
    local match
    for _, dungeon in ipairs(LIST) do
        local name = " " .. string.gsub(string.lower(dungeon.name), "[^%w]", " ")
        if wanted ~= "" and string.find(name, " " .. wanted, 1, true) then
            if match then
                return nil
            end
            match = dungeon
        end
    end
    return match
end

-- The dungeons an area name stands for: "The Deadmines" or "Deadmines" for
-- one dungeon, "Scarlet Monastery" or "Blackrock Spire" for all of its wings.
function Dungeons.forArea(area)
    local wanted = withoutArticle(area or "")
    local ids = {}
    if wanted == "" then
        return ids
    end
    for _, dungeon in ipairs(LIST) do
        local name = withoutArticle(dungeon.name)
        if name == wanted or string.sub(name, 1, #wanted + 1) == wanted .. ":"
            or string.sub(name, -(#wanted + 1)) == " " .. wanted then
            ids[#ids + 1] = dungeon.id
        end
    end
    return ids
end

ns.Dungeons = Dungeons
return Dungeons
