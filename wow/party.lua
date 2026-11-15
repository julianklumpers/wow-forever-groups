local _, ns = ...

local Party = {}

local ROLE_FROM_WOW = { TANK = "T", HEALER = "H", DAMAGER = "D" }

local function isSecret(value)
    return issecretvalue ~= nil and issecretvalue(value) == true
end

-- Forever puts the surname in UnitFullName's realm slot ("Roos", "Bieff"),
-- while the server identifies the player as "Roos Bieff".
function Party.unitName(unit)
    local name, second = UnitFullName(unit)
    if type(name) ~= "string" or isSecret(name) or name == "" or name == UNKNOWNOBJECT then
        return nil
    end
    if type(second) == "string" and second ~= "" and second ~= GetNormalizedRealmName() then
        return name .. " " .. second
    end
    return name
end

function Party.playerClass()
    local _, classToken = UnitClass("player")
    return classToken
end

-- "solo", "leader", "member" or "raid".
function Party.state()
    if IsInRaid and IsInRaid() then
        return "raid"
    end
    if not IsInGroup() then
        return "solo"
    end
    return UnitIsGroupLeader("player") and "leader" or "member"
end

-- The other party members, or nil while some name is not loaded yet.
function Party.members()
    local members = {}
    if Party.state() == "solo" then
        return members
    end
    for i = 1, 4 do
        local unit = "party" .. i
        if UnitExists(unit) then
            local name = Party.unitName(unit)
            if not name then
                return nil
            end
            local assigned = UnitGroupRolesAssigned and UnitGroupRolesAssigned(unit)
            local _, classToken = UnitClass(unit)
            members[#members + 1] = {
                unit = unit, name = name, level = UnitLevel(unit) or 0, wowRole = ROLE_FROM_WOW[assigned],
                classToken = classToken,
            }
        end
    end
    return members
end

-- /fg preview party: a sample party, so the window shows a party leader's
-- view without being in a group. Only the window asks for it (shownState,
-- shownMembers, GroupView.composition(true)); queueing, matching and
-- messages use state() and members() and never see it.
local SAMPLE = {
    { name = "Sample Tank", classToken = "WARRIOR", wowRole = "T" },
    { name = "Sample Mage", classToken = "MAGE", wowRole = "D" },
}
local sampleOn = false

function Party.setSample(on)
    sampleOn = on and true or false
end

function Party.isSample()
    return sampleOn and not IsInGroup()
end

function Party.shownState()
    return Party.isSample() and "leader" or Party.state()
end

function Party.shownMembers()
    if not Party.isSample() then
        return Party.members()
    end
    local members = {}
    for i, member in ipairs(SAMPLE) do
        members[i] = { name = member.name, classToken = member.classToken, wowRole = member.wowRole,
            level = UnitLevel("player") or 0 }
    end
    return members
end

ns.Party = Party
