local _, ns = ...
ns = ns or {}

local Roles = ns.Roles or require("core.roles")

-- Roles each class can play on Forever, keyed by the locale-independent class
-- token from UnitClass. A class missing here is not restricted.
local CLASS_ROLES = {
    WARRIOR = "TD",
    PALADIN = "THD",
    DRUID = "THD",
    SHAMAN = "THD",
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

ns.Classes = Classes
return Classes
