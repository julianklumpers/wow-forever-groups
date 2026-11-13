local _, ns = ...
ns = ns or {}

-- The battlegrounds Forever Groups helps with. Ids go over the wire: never
-- renumber or reuse one, only append. lfg is the battleground's activity in
-- WoW's Group Finder (its Battlegrounds category, 118, offers only Warsong
-- Gulch); the others are found through the Forever Groups queue only. size: players per side. Battlegrounds
-- put players together by level bracket (10-19, 20-29, ...), so groups only
-- form within one bracket.
local LIST = {
    { id = "wsg", name = "Warsong Gulch", short = "WSG", lfg = 919, size = 10, minLevel = 10, pvp = 2 },
    { id = "ab", name = "Arathi Basin", short = "AB", size = 15, minLevel = 20, pvp = 3 },
    { id = "dsi", name = "Darkspear Islands", short = "DSI", size = 15, minLevel = 30, pvp = 1157 },
}

local Battlegrounds = { list = LIST, byId = {}, byActivity = {} }

for _, battleground in ipairs(LIST) do
    Battlegrounds.byId[battleground.id] = battleground
    if battleground.lfg then
        Battlegrounds.byActivity[battleground.lfg] = battleground
    end
end

function Battlegrounds.get(id)
    return Battlegrounds.byId[id]
end

-- The names in the player's language (C_PvP.GetBattlegroundInfo, by pvp
-- id), set at login on a client in another language than English.
Battlegrounds.localNames = {}

function Battlegrounds.name(id)
    return Battlegrounds.localNames[id] or Battlegrounds.englishName(id)
end

-- For whispers, which stay English.
function Battlegrounds.englishName(id)
    local battleground = Battlegrounds.byId[id]
    return battleground and battleground.name or tostring(id)
end

-- The first level of a level's bracket (17 -> 10), or nil below the first.
function Battlegrounds.bracket(level)
    level = tonumber(level)
    if not level or level < 10 then
        return nil
    end
    return math.floor(level / 10) * 10
end

function Battlegrounds.bracketText(level)
    local first = Battlegrounds.bracket(level)
    return first and string.format("%d-%d", first, first + 9) or "?"
end

function Battlegrounds.sameBracket(a, b)
    local first = Battlegrounds.bracket(a)
    return first ~= nil and first == Battlegrounds.bracket(b)
end

-- A battleground with a bracket, as the Forever Groups queue lists it:
-- "wsg-10" for Warsong Gulch at levels 10-19.
function Battlegrounds.key(id, level)
    local first = Battlegrounds.bracket(level)
    return first and Battlegrounds.byId[id] and (id .. "-" .. first) or nil
end

-- The battleground id and the bracket's first level of a key, or nil.
function Battlegrounds.parseKey(key)
    local id, first = string.match(type(key) == "string" and key or "", "^(%a+)%-(%d+)$")
    first = tonumber(first)
    if not id or not Battlegrounds.byId[id] or first < Battlegrounds.byId[id].minLevel then
        return nil
    end
    return id, first
end

-- The battlegrounds a player of this level can join.
function Battlegrounds.forLevel(level)
    local result = {}
    for _, battleground in ipairs(LIST) do
        if (tonumber(level) or 0) >= battleground.minLevel then
            result[#result + 1] = battleground
        end
    end
    return result
end

ns.Battlegrounds = Battlegrounds
return Battlegrounds
