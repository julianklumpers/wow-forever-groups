local _, ns = ...

local Party = ns.Party
local Log = ns.Log

-- Shows each player's Forever Groups role in WoW's party frames. A leader may
-- set anyone's role, everyone else only their own (UnitSetRole). The role is
-- set once, when the player joins; if the player picks another role after
-- that, Forever Groups adopts it instead of setting it back. Not for the
-- player's own role when it turns into one they did not queue for: WoW sets
-- a role from the spec by itself (a Feral druid becomes the tank a few seconds
-- after joining as healer), so that one is always set back: the role the
-- player chose in Forever Groups wins over the spec. At most once per
-- RESET_GAP, so a server that keeps changing it is not answered in a loop.
-- The roles are kept per character, so they still hold after a /reload.
local RoleSync = {}

local WOW_ROLES = { T = "TANK", H = "HEALER", D = "DAMAGER" }
local LETTERS = { TANK = "T", HEALER = "H", DAMAGER = "D" }
local MAX_ATTEMPTS = 3
local RESET_GAP = 5
-- Seconds between two tries: the server takes a moment to apply a role, and
-- roster updates come in bursts.
local RETRY_AFTER = 2

local expected = {}
local attempts = {}
local attemptedAt = {}
local settled = {}
local resets = {}
local listeners = {}

-- The player's name, also before the channel told it (right after a
-- /reload, when WoW may already have changed the role).
local function me()
    return ns.selfName or Party.unitName("player")
end

local function save()
    ns.charDb.roleSync = next(expected) and RoleSync.all() or nil
end

-- Whether the player could have picked this role: anyone else's role is
-- theirs to choose; the player's own only among the roles they queued for.
local function ownChoice(name, role)
    if name ~= me() then
        return true
    end
    local entry = ns.engine and ns.engine.myEntry
    local roles = (entry and entry.members[1].roles) or ns.charDb.lastRoles
    return roles == nil or string.find(roles, role, 1, true) ~= nil
end

local function canSet(unit)
    return unit == "player" or UnitIsGroupLeader("player")
end

-- Deadly Boss Mods plans its role check (below) as it loads, before Forever
-- Groups does: once the player's role is held, that planned check is called
-- off through DBM's own DBM:Unschedule.
local function cancelBossModsCheck()
    local dbm = _G.DBM
    local original = type(dbm) == "table" and dbm.foreverGroupsRoleCheck
    if original and type(dbm.Unschedule) == "function" then
        pcall(dbm.Unschedule, dbm, original)
    end
end

function RoleSync.expect(name, role)
    local self = me()
    if name and WOW_ROLES[role] and (self == nil or name == self) then
        cancelBossModsCheck()
    end
    if name and WOW_ROLES[role] then
        expected[name] = role
        attempts[name] = 0
        attemptedAt[name] = nil
        settled[name] = false
        resets[name] = nil
        save()
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
    expected[name], attempts[name], settled[name], attemptedAt[name], resets[name] = nil, nil, nil, nil, nil
    save()
end

function RoleSync.onChange(listener)
    listeners[#listeners + 1] = listener
end

local retryScheduled = false

local function retryLater(seconds)
    if retryScheduled then
        return
    end
    retryScheduled = true
    C_Timer.After(math.max(0.1, seconds), function()
        retryScheduled = false
        RoleSync.apply()
    end)
end

local function changed(name, role)
    expected[name] = role
    save()
    Log.debug("%s now plays %s", name, WOW_ROLES[role])
    for _, listener in ipairs(listeners) do
        listener(name, role)
    end
end

-- In a group Forever Groups follows, the player's own role is held at one
-- they ticked, also when nothing was agreed for it (a group formed before
-- an update, or by a leader without the addon): the current one if they
-- ticked it, else the first ticked one.
local function claimOwn()
    local name = me()
    if not name or expected[name] or not ns.GroupView.isTracking() then
        return
    end
    local roles = ns.charDb.lastRoles
    if type(roles) ~= "string" or roles == "" then
        return
    end
    local current = UnitGroupRolesAssigned and LETTERS[UnitGroupRolesAssigned("player")]
    RoleSync.expect(name, (current and string.find(roles, current, 1, true)) and current or roles:sub(1, 1))
end

function RoleSync.apply()
    if not IsInGroup() then
        return
    end
    claimOwn()
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
        elseif role and current and settled[name] and ownChoice(name, current) then
            changed(name, current)
        elseif role and current and settled[name] and now - (resets[name] or -math.huge) >= RESET_GAP then
            Log.debug("WoW made %s %s; setting %s back", name, WOW_ROLES[current], WOW_ROLES[role])
            resets[name] = now
            settled[name], attempts[name], attemptedAt[name] = false, 0, nil
            RoleSync.apply()
            return
        elseif role and current and settled[name] then
            retryLater(RESET_GAP - (now - resets[name]))
        elseif not role or waiting then -- luacheck: ignore 542
            -- Nothing to set, or the last try may still be on its way.
        elseif type(UnitSetRole) == "function" and canSet(unit) and attempts[name] < MAX_ATTEMPTS then
            attempts[name] = attempts[name] + 1
            attemptedAt[name] = now
            local ok, err = pcall(UnitSetRole, unit, WOW_ROLES[role])
            Log.debug("set role of %s to %s: %s", name, WOW_ROLES[role], ok and "ok" or tostring(err))
        elseif current and attempts[name] >= MAX_ATTEMPTS and ownChoice(name, current) then
            settled[name] = true
            changed(name, current)
        end
    end
end

-- Another addon that sets the player's role anyway is answered at once,
-- before WoW even reports the change, so the wrong role barely shows.
local answering = false

local function onRoleSet(unit, role)
    if answering or unit ~= "player" then
        return
    end
    local name = me()
    local wanted = name and expected[name]
    local letter = LETTERS[role]
    if not wanted or not letter or letter == wanted or ownChoice(name, letter) then
        return
    end
    answering = true
    local ok = pcall(UnitSetRole, "player", WOW_ROLES[wanted])
    answering = false
    Log.debug("something set %s to %s; set %s right back: %s", name, role, WOW_ROLES[wanted], ok and "ok" or "failed")
end

-- Deadly Boss Mods sets the role from the spec two seconds after a group
-- forms and after every /reload (DBM:RoleCheck; in Forever's client that is
-- all it does). While Forever Groups holds the player's role, that check is
-- skipped, so the spec's role never shows; otherwise DBM works as always.
local function quietBossMods()
    local dbm = _G.DBM
    if type(dbm) ~= "table" or type(dbm.RoleCheck) ~= "function" or dbm.foreverGroupsRoleCheck then
        return
    end
    local original = dbm.RoleCheck
    dbm.foreverGroupsRoleCheck = original
    dbm.RoleCheck = function(self, ...)
        local name = me()
        if name and expected[name] then
            Log.debug("Deadly Boss Mods' role check skipped: Forever Groups holds your role")
            return
        end
        return original(self, ...)
    end
end

-- After a /reload the roles agreed before still count, from the moment the
-- addon loads (the roster comes later; not being in a group then clears
-- them).
local function restore()
    local saved = ns.charDb.roleSync
    if next(expected) or type(saved) ~= "table" then
        return
    end
    for name, role in pairs(saved) do
        RoleSync.expect(name, role)
    end
end

local function onRosterUpdate()
    if not IsInGroup() then
        expected, attempts, settled, attemptedAt, resets = {}, {}, {}, {}, {}
        ns.charDb.roleSync = nil
        return
    end
    restore()
    RoleSync.apply()
end

function RoleSync.init()
    if type(hooksecurefunc) == "function" and type(UnitSetRole) == "function" then
        hooksecurefunc("UnitSetRole", onRoleSet)
    end
    quietBossMods()
    restore()
    ns.on("ADDON_LOADED", quietBossMods)
    ns.on("PLAYER_LOGIN", quietBossMods)
    ns.on("PLAYER_ENTERING_WORLD", onRosterUpdate)
    ns.on("GROUP_ROSTER_UPDATE", onRosterUpdate)
    ns.on("PLAYER_ROLES_ASSIGNED", RoleSync.apply)
    ns.on("ROLE_CHANGED_INFORM", RoleSync.apply)
end

ns.RoleSync = RoleSync
