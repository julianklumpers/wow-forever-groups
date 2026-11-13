local _, ns = ...

local L = ns.L

local Playstyles = ns.Playstyles
local Log = ns.Log

-- The player's playstyle, and the link to the playstyles of WoW's Group
-- Finder: what a listing says, and what our own listing says.
local Playstyle = {}

local ANY = Playstyles.ANY

-- Any (no preference: grouped with everyone) until the player picks one,
-- and first in the list; then Relaxed and the rest in WoW's order.
Playstyle.DEFAULT = ANY
Playstyle.ORDER = { ANY, 2, 1, 3, 4 }

Playstyle.DESCRIPTIONS = ns.Locale.mark({
    [ANY] = "No preference: grouped with every playstyle.",
    [1] = "New to the dungeon; explanations are welcome.",
    [2] = "No rush, time for quests.",
    [3] = "Focused and efficient.",
    [4] = "You know the dungeon well and can carry others through it.",
})

local function isSecret(value)
    if canaccessvalue ~= nil then
        return not canaccessvalue(value)
    end
    return issecretvalue ~= nil and issecretvalue(value) == true
end

function Playstyle.wowValue(id)
    local style = Playstyles.LIST[id]
    if not style then
        return nil
    end
    local enum = Enum and Enum.LFGEntryGeneralPlaystyle
    return enum and enum[style.key] or id
end

-- Our id for a listing's generalPlaystyle, or nil when it has none or it
-- cannot be read.
function Playstyle.fromWoW(value)
    if value == nil or isSecret(value) or type(value) ~= "number" then
        return nil
    end
    for _, style in ipairs(Playstyles.LIST) do
        if Playstyle.wowValue(style.id) == value then
            return style.id
        end
    end
    return nil
end

-- WoW's own word for it, so it reads like the Group Finder.
function Playstyle.word(id)
    if id == ANY then
        return L["Any"]
    end
    local style = Playstyles.LIST[id]
    if not style then
        return "?"
    end
    if GetGeneralPlaystyleString then
        local ok, word = pcall(GetGeneralPlaystyleString, Playstyle.wowValue(id))
        if ok and type(word) == "string" and word ~= "" then
            return word
        end
    end
    return style.word
end

-- "Relaxed · Learning", or nil for none.
function Playstyle.describe(list, separator)
    if not list or #list == 0 then
        return nil
    end
    local words = {}
    for i, id in ipairs(list) do
        words[i] = Playstyle.word(id)
    end
    return table.concat(words, separator or " · ")
end

-- The line under the choice: who the player is grouped with.
function Playstyle.partnersText(id)
    if id == ANY then
        return L["Grouped with everyone."]
    end
    local words = { Playstyle.word(id) }
    for _, other in ipairs(Playstyles.partners(id)) do
        words[#words + 1] = Playstyle.word(other)
    end
    return string.format(L["Grouped with %s players."], table.concat(words, " " .. L["and"] .. " "))
end

function Playstyle.mine()
    local id = ns.charDb and ns.charDb.playstyle
    return Playstyles.isValid(id) and id or Playstyle.DEFAULT
end

function Playstyle.set(id)
    if not Playstyles.isValid(id) then
        return false
    end
    ns.charDb.playstyle = id
    if ns.engine then
        ns.engine:setPlaystyle(id)
    end
    return true
end

-- The playstyle the group being built goes with: the formed group's, else
-- the player's own.
function Playstyle.forGroup()
    local styles = ns.GroupView.playstyles()
    if #styles > 0 then
        return styles[1]
    end
    return Playstyle.mine()
end

-- Whether a Group Finder listing goes with the playstyle; one without a
-- readable playstyle is kept.
function Playstyle.fits(listingStyle, style)
    return listingStyle == nil or Playstyles.compatible(listingStyle, style)
end

function Playstyle.filter(listings, style)
    local kept = {}
    for _, listing in ipairs(listings) do
        if Playstyle.fits(listing.playstyle, style) then
            kept[#kept + 1] = listing
        end
    end
    return kept
end

-- The Enum value our own Group Finder listing gets: WoW requires one.
function Playstyle.listingValue()
    local style = Playstyle.forGroup()
    return Playstyle.wowValue(style ~= ANY and style or 2)
end

-- "relaxed", "expert" etc., for typed commands.
function Playstyle.parse(text)
    text = string.lower(text or "")
    if text == "any" then
        return ANY
    end
    for _, style in ipairs(Playstyles.LIST) do
        if text == string.lower(style.word) or text == string.lower(style.key)
            or text == string.lower(Playstyle.word(style.id)) then
            return style.id
        end
    end
    return nil
end

function Playstyle.command(rest)
    local id = Playstyle.parse(rest)
    if id == nil then
        Log.info("Your playstyle: %s. Change it with /fg style any | relaxed | learning | serious | expert.",
            Playstyle.word(Playstyle.mine()))
        return
    end
    Playstyle.set(id)
    Log.info("Playstyle: %s. %s", Playstyle.word(id), Playstyle.partnersText(id))
    ns.Window.refresh()
end

ns.Playstyle = Playstyle
