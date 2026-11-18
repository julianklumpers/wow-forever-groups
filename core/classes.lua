local _, ns = ...
ns = ns or {}

local Roles = ns.Roles or require("core.roles")

-- Roles each class can play on Forever, keyed by the locale-independent class
-- token from UnitClass. A class missing here is not restricted.
local CLASS_ROLES = {
    WARRIOR = "TD",
    PALADIN = "THD",
    DRUID = "THD",
    SHAMAN = "HD",
    PRIEST = "HD",
    HUNTER = "D",
    ROGUE = "D",
    MAGE = "D",
    WARLOCK = "D",
}

local Classes = {}

function Classes.allowed(classToken)
    return CLASS_ROLES[classToken] or "THD"
end

function Classes.canPlay(classToken, role)
    return Roles.has(Classes.allowed(classToken), role)
end

-- Drops the roles the class cannot play; nil when none are left.
function Classes.filter(roles, classToken)
    if not roles then
        return nil
    end
    local result = ""
    for _, role in ipairs(Roles.ORDER) do
        if Roles.has(roles, role) and Classes.canPlay(classToken, role) then
            result = result .. role
        end
    end
    return result ~= "" and result or nil
end

-- The armour each class wears below level 40 and from 40 on (Classic).
local ARMOR = {
    WARRIOR = { "Mail", "Plate" }, PALADIN = { "Mail", "Plate" },
    HUNTER = { "Leather", "Mail" }, SHAMAN = { "Leather", "Mail" },
    ROGUE = { "Leather", "Leather" }, DRUID = { "Leather", "Leather" },
    PRIEST = { "Cloth", "Cloth" }, MAGE = { "Cloth", "Cloth" }, WARLOCK = { "Cloth", "Cloth" },
}
Classes.ARMORS = { "Plate", "Mail", "Leather", "Cloth" }

function Classes.armor(classToken, level)
    local armor = ARMOR[classToken]
    return armor and armor[(level or 0) >= 40 and 2 or 1]
end

-- The classes grouped by the armour they wear at `level`, plate first:
-- { { armor, classes = { ... } } }, each in the order given.
function Classes.byArmor(classes, level)
    local groups = {}
    for _, armor in ipairs(Classes.ARMORS) do
        local group = { armor = armor, classes = {} }
        for _, class in ipairs(classes) do
            if Classes.armor(class, level) == armor then
                group.classes[#group.classes + 1] = class
            end
        end
        if #group.classes > 0 then
            groups[#groups + 1] = group
        end
    end
    return groups
end

-- Short codes for the wire (WoW's class ids).
local CODES = {
    WARRIOR = "1", PALADIN = "2", HUNTER = "3", ROGUE = "4", PRIEST = "5", SHAMAN = "7", MAGE = "8", WARLOCK = "9",
    DRUID = "11",
}
local TOKENS = {}
for token, code in pairs(CODES) do
    TOKENS[code] = token
end

function Classes.code(classToken)
    return CODES[classToken]
end

function Classes.fromCode(code)
    return TOKENS[code]
end

ns.Classes = Classes
return Classes
