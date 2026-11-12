local _, ns = ...
ns = ns or {}

-- The playstyles of WoW's Group Finder (Enum.LFGEntryGeneralPlaystyle), in
-- the order its Listing tab offers them. A player picks one, or none (ANY)
-- for no preference. Learning and Relaxed players go together, and so do
-- Serious and Expert ones; the two camps are never grouped.
local Playstyles = {}

Playstyles.ANY = 0
Playstyles.LIST = {
    { id = 1, key = "Learning", word = "Learning", camp = 1 },
    { id = 2, key = "FunRelaxed", word = "Relaxed", camp = 1 },
    { id = 3, key = "FunSerious", word = "Serious", camp = 2 },
    { id = 4, key = "Expert", word = "Expert", camp = 2 },
}
-- On a tie in a mixed group, the calmer playstyle of the camp names it.
local TIE_ORDER = { [2] = 1, [1] = 2, [3] = 3, [4] = 4 }

function Playstyles.isValid(id)
    return id == Playstyles.ANY or Playstyles.LIST[id] ~= nil
end

local function camp(id)
    local style = Playstyles.LIST[id or Playstyles.ANY]
    return style and style.camp or 0
end

function Playstyles.compatible(a, b)
    local ca, cb = camp(a), camp(b)
    return ca == 0 or cb == 0 or ca == cb
end

-- A playstyle standing for a group that has a and gets b.
function Playstyles.combine(a, b)
    if (a or Playstyles.ANY) ~= Playstyles.ANY then
        return a
    end
    return b or Playstyles.ANY
end

-- The other playstyles a player with this one is grouped with.
function Playstyles.partners(id)
    local list = {}
    for _, style in ipairs(Playstyles.LIST) do
        if style.id ~= id and camp(id) ~= 0 and style.camp == camp(id) then
            list[#list + 1] = style.id
        end
    end
    return list
end

-- The playstyles in a group, the one most players picked first.
-- entries: { { playstyle, players } }.
function Playstyles.mix(entries)
    local count = {}
    for _, entry in ipairs(entries) do
        local id = entry.playstyle or Playstyles.ANY
        if id ~= Playstyles.ANY then
            count[id] = (count[id] or 0) + (entry.players or 1)
        end
    end
    local list = {}
    for id in pairs(count) do
        list[#list + 1] = id
    end
    table.sort(list, function(a, b)
        if count[a] ~= count[b] then
            return count[a] > count[b]
        end
        return TIE_ORDER[a] < TIE_ORDER[b]
    end)
    return list
end

-- "21" for { 2, 1 }; nil when the list is not a valid mix.
function Playstyles.encode(list)
    local text = ""
    for _, id in ipairs(list or {}) do
        if not Playstyles.LIST[id] or not Playstyles.compatible(id, list[1])
            or string.find(text, tostring(id), 1, true) then
            return nil
        end
        text = text .. id
    end
    return text
end

function Playstyles.decode(text)
    if text == nil or text == "" then
        return {}
    end
    if not string.find(text, "^%d+$") then
        return nil
    end
    local list = {}
    for digit in string.gmatch(text, "%d") do
        list[#list + 1] = tonumber(digit)
    end
    if Playstyles.encode(list) ~= text then
        return nil
    end
    return list
end

ns.Playstyles = Playstyles
return Playstyles
