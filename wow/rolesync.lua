local _, ns = ...

local Party = ns.Party
local Log = ns.Log

-- Shows each player's Forever Groups role in WoW's party frames. A leader may
-- set anyone's role, everyone else only their own (UnitSetRole). The role is
-- set once, when the player joins; if the player picks another role after
-- that, Forever Groups adopts it instead of setting it back.
local RoleSync = {}

local WOW_ROLES = { T = "TANK", H = "HEALER", D = "DAMAGER" }
local LETTERS = { TANK = "T", HEALER = "H", DAMAGER = "D" }
local MAX_ATTEMPTS = 3
-- Seconds between two tries: the server takes a moment to apply a role, and
-- roster updates come in bursts.
local RETRY_AFTER = 2

local expected = {}
local attempts = {}
local attemptedAt = {}
local settled = {}
local listeners = {}

local function canSet(unit)
    return unit == "player" or UnitIsGroupLeader("player")
end

function RoleSync.expect(name, role)
    if name and WOW_ROLES[role] then
        expected[name] = role
        attempts[name] = 0
        attemptedAt[name] = nil
        settled[name] = false
    end
end

function RoleSync.expected(name)
    return expected[name]
end

-- Everyone Forever Groups expects in the current group, joined or on the way.
function RoleSync.all()
    local copy = {}
    for name, role in pairs(expected) do
        copy[name] = role
    end
    return copy
end

function RoleSync.forget(name)
    expected[name], attempts[name], settled[name], attemptedAt[name] = nil, nil, nil, nil
end

function RoleSync.onChange(listener)
    listeners[#listeners + 1] = listener
end

local function changed(name, role)
    Log.debug("%s now plays %s", name, WOW_ROLES[role])
    for _, listener in ipairs(listeners) do
        listener(name, role)
    end
end

function RoleSync.apply()
    if not IsInGroup() then
        return
    end
    local units = { "player" }
    for i = 1, 4 do
        units[#units + 1] = "party" .. i
    end
    local now = GetTime()
    for _, unit in ipairs(units) do
        local name = Party.unitName(unit)
        local role = name and expected[name]
        local current = UnitGroupRolesAssigned and LETTERS[UnitGroupRolesAssigned(unit)]
        local waiting = attemptedAt[name] ~= nil and now - attemptedAt[name] < RETRY_AFTER
        if role and current == role then
            settled[name] = true
        elseif role and current and settled[name] then
            expected[name] = current
            changed(name, current)
        elseif not role or waiting then -- luacheck: ignore 542
            -- Nothing to set, or the last try may still be on its way.
        elseif type(UnitSetRole) == "function" and canSet(unit) and attempts[name] < MAX_ATTEMPTS then
            attempts[name] = attempts[name] + 1
            attemptedAt[name] = now
            local ok, err = pcall(UnitSetRole, unit, WOW_ROLES[role])
            Log.debug("set role of %s to %s: %s", name, WOW_ROLES[role], ok and "ok" or tostring(err))
        elseif current and attempts[name] >= MAX_ATTEMPTS then
            settled[name] = true
            expected[name] = current
            changed(name, current)
        end
    end
end

local function onRosterUpdate()
    if not IsInGroup() then
        expected, attempts, settled, attemptedAt = {}, {}, {}, {}
        return
    end
    RoleSync.apply()
end

function RoleSync.init()
    ns.on("GROUP_ROSTER_UPDATE", onRosterUpdate)
    ns.on("PLAYER_ROLES_ASSIGNED", RoleSync.apply)
    ns.on("ROLE_CHANGED_INFORM", RoleSync.apply)
end

ns.RoleSync = RoleSync
