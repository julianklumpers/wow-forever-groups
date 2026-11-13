local _, ns = ...

local Classes = ns.Classes

-- The roles a party member plays, without anyone choosing them in the addon:
-- the role they were taken on for (which Forever Groups also sets in WoW, and
-- which follows the player if they switch), else their role in WoW's party
-- frames, else every role their class can play.
local PartyRoles = {}

function PartyRoles.rolesOf(member)
    local roles = ns.RoleSync.expected(member.name) or member.wowRole or ns.Filler.roleOf(member.name)
    return (roles and Classes.filter(roles, member.classToken)) or Classes.allowed(member.classToken)
end

-- "party role", "class" or "invited": where the roles came from, for the window.
function PartyRoles.sourceOf(member)
    if ns.RoleSync.expected(member.name) or member.wowRole then
        return ns.Locale.mark("party role")
    elseif ns.Filler.roleOf(member.name) then
        return ns.Locale.mark("invited")
    end
    return ns.Locale.mark("any role of the class")
end

ns.PartyRoles = PartyRoles
