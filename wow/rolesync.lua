local _, ns = ...

local Party = ns.Party
local Log = ns.Log

-- Shows each player's Forever Groups role in WoW's party frames. A leader may
-- set anyone's role, everyone else only their own (UnitSetRole). The role is
-- set once, when the player joins, and is the role they were taken for: WoW
-- sets a role from the spec by itself (a Feral druid becomes the tank a few
-- seconds after joining as healer, a Protection warrior invited as DPS the
-- tank), so another role is set back: the player's own unless they ticked
-- that one too; a party member's always (Deadly Boss Mods sets it from the
-- spec again after each of their /reloads). Only the leader changing a
-- member's role in WoW's party frames makes it their new role.
-- Each change is answered at once; only LOOP_MAX set-backs of one player
-- within LOOP_WINDOW seconds (something keeps changing it) pause it, so that
-- is not answered in a loop. The roles are kept per character, so they still
-- hold after a /reload.
local RoleSync = {}

local WOW_ROLES = { T = "TANK", H = "HEALER", D = "DAMAGER" }
local LETTERS = { TANK = "T", HEALER = "H", DAMAGER = "D" }
local MAX_ATTEMPTS = 3
local LOOP_WINDOW, LOOP_MAX = 10, 6
-- Seconds between two tries: the server takes a moment to apply a role, and
-- roster updates come in bursts.
local RETRY_AFTER = 2

local expected = {}
local attempts = {}
local attemptedAt = {}
local settled = {}
-- Per player the times of their set-backs within LOOP_WINDOW, and whether a
-- pause for a loop was logged.
local resets = {}
local paused = {}
local listeners = {}
local onRoleChanged
-- While Forever Groups itself sets a role (onRoleSet leaves that alone).
local setting = false
-- The player's role is held for their single tick, not agreed (claimTicked).
local tickHeld = false

-- The player's name, also before the channel told it (right after a
-- /reload, when WoW may already have changed the role).
local function me()
    return ns.selfName or Party.unitName("player")
end

local function save()
    ns.charDb.roleSync = next(expected) and RoleSync.all() or nil
    ns.charDb.roleSyncTick = tickHeld or nil
    ns.charDb.roleSyncOffered = nil
end

-- Whether another role is the player's own choice: never a party member's
-- (only the leader changes it, onRoleSet); the player's own among the roles
-- they queued for.
local function ownChoice(name, role)
    if name ~= me() then
        return false
    end
    local entry = ns.engine and ns.engine.myEntry
    local roles = (entry and entry.members[1].roles) or ns.charDb.lastRoles
    return roles == nil or string.find(roles, role, 1, true) ~= nil
end

-- Seconds to wait before setting a player's role back again: nil while
-- fewer than LOOP_MAX set-backs fell within LOOP_WINDOW.
local function loopWait(name, now)
    local kept = {}
    for _, at in ipairs(resets[name] or {}) do
        if now - at < LOOP_WINDOW then
            kept[#kept + 1] = at
        end
    end
    resets[name] = kept
    if #kept < LOOP_MAX then
        return nil
    end
    return LOOP_WINDOW - (now - kept[1])
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
        if name == self then
            tickHeld = false
        end
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
    paused[name] = nil
    save()
end

function RoleSync.onChange(listener)
    listeners[#listeners + 1] = listener
end

-- When the next look is planned; a sooner one is planned on top of it.
local retryAt

local function retryLater(seconds)
    local at = GetTime() + math.max(0.1, seconds)
    if retryAt and retryAt <= at then
        return
    end
    retryAt = at
    C_Timer.After(at - GetTime(), function()
        if retryAt == at then
            retryAt = nil
        end
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

-- In any other party (a friend's, before or without a queue) a single
-- ticked role is the player's role in WoW too; with several ticked their
-- role is left alone. tickHeld: the hold is the tick's, not an agreed one.

local function claimTicked()
    local name = me()
    if not name or ns.GroupView.isTracking() or (ns.Demo and ns.Demo.isOn()) then
        return
    end
    if IsInRaid() then
        if tickHeld then
            tickHeld = false
            RoleSync.forget(name)
        end
        return
    end
    local roles = ns.charDb.lastRoles
    local single = type(roles) == "string" and #roles == 1 and WOW_ROLES[roles] and roles or nil
    if single and (tickHeld or not expected[name]) then
        if expected[name] ~= single then
            RoleSync.expect(name, single)
        end
        if not tickHeld then
            tickHeld = true
            save()
        end
    elseif not single and tickHeld then
        tickHeld = false
        RoleSync.forget(name)
    end
end

function RoleSync.apply()
    if not IsInGroup() then
        return
    end
    claimTicked()
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
        elseif role and current and settled[name] and (ownChoice(name, current) or not canSet(unit)) then
            -- Theirs, or not ours to set back (only a leader sets others' roles).
            changed(name, current)
        elseif role and current and settled[name] then
            local wait = loopWait(name, now)
            if not wait then
                Log.debug("WoW made %s %s; setting %s back", name, WOW_ROLES[current], WOW_ROLES[role])
                table.insert(resets[name], now)
                paused[name] = nil
                settled[name], attempts[name], attemptedAt[name] = false, 0, nil
                RoleSync.apply()
                return
            end
            if not paused[name] then
                paused[name] = true
                Log.debug("%s's role keeps changing; pausing %d s", name, math.ceil(wait))
            end
            retryLater(wait)
        elseif not role or waiting then -- luacheck: ignore 542
            -- Nothing to set, or the last try may still be on its way.
        elseif type(UnitSetRole) == "function" and canSet(unit) and attempts[name] < MAX_ATTEMPTS then
            attempts[name] = attempts[name] + 1
            attemptedAt[name] = now
            setting = true
            local ok, err = pcall(UnitSetRole, unit, WOW_ROLES[role])
            setting = false
            Log.debug("set role of %s to %s: %s", name, WOW_ROLES[role], ok and "ok" or tostring(err))
            if LETTERS[UnitGroupRolesAssigned(unit)] == role then
                -- Taken at once: the next change is answered at once too.
                settled[name], attemptedAt[name] = true, nil
            else
                -- WoW says nothing when a role does not take: look again.
                retryLater(RETRY_AFTER)
            end
        elseif current and attempts[name] >= MAX_ATTEMPTS and (name ~= me() or ownChoice(name, current)) then
            -- The role could not be set: a party member plays the one they
            -- have.
            settled[name] = true
            changed(name, current)
        end
    end
end

-- Another addon that sets the player's role anyway is answered at once,
-- before WoW even reports the change, so the wrong role barely shows. A
-- member's role the leader sets (in WoW's party frames, not Forever Groups
-- itself) is their new role.
local answering = false

local function onRoleSet(unit, role)
    if answering or setting then
        return
    end
    if unit ~= "player" then
        local name = Party.unitName(unit)
        local letter = LETTERS[role]
        if name and letter and expected[name] and expected[name] ~= letter and UnitIsGroupLeader("player") then
            changed(name, letter)
            settled[name], attempts[name], attemptedAt[name] = false, 0, nil
            Log.debug("you made %s %s", name, role)
        end
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

-- Whether a name (as WoW's role event gives it, maybe the first part only)
-- is the party's leader.
local function isLeaderName(name)
    if type(name) ~= "string" then
        return false
    end
    for i = 1, 4 do
        local unit = "party" .. i
        local full = Party.unitName(unit)
        if full and UnitIsGroupLeader(unit) and (full == name or string.match(full, "^(%S+)") == name) then
            return true
        end
    end
    return false
end

-- The party's leader setting the player's role (WoW's party frames) makes it
-- the player's own: the leader's client holds it from then on, so this one
-- must not set it back (ROLE_CHANGED_INFORM: changed, changed by, old, new).
function onRoleChanged(who, changedBy, _, newRole)
    local name = me()
    local letter = LETTERS[newRole]
    if name and letter and expected[name] and expected[name] ~= letter and changedBy ~= who
        and (who == name or (type(who) == "string" and string.match(name, "^(%S+)") == who))
        and isLeaderName(changedBy) then
        tickHeld = false
        changed(name, letter)
        -- WoW's role data may still show the old role: set the new one
        -- rather than take the old one over.
        settled[name], attempts[name], attemptedAt[name] = false, 0, nil
        Log.debug("your leader made you %s", newRole)
    end
    RoleSync.apply()
end

-- After a /reload the roles agreed before still count, from the moment the
-- addon loads (the roster comes later; not being in a group then clears
-- them).
local function restore()
    local saved, tick = ns.charDb.roleSync, ns.charDb.roleSyncTick == true
    if next(expected) or type(saved) ~= "table" then
        return
    end
    for name, role in pairs(saved) do
        RoleSync.expect(name, role)
    end
    tickHeld = tick and expected[me()] ~= nil
    save()
end

-- The roles ticked in the window changed.
function RoleSync.ticked()
    RoleSync.apply()
end

local function onRosterUpdate()
    if not IsInGroup() then
        if not ns.inWorld then
            return
        end
        expected, attempts, settled, attemptedAt, resets, paused = {}, {}, {}, {}, {}, {}
        tickHeld = false
        ns.charDb.roleSync, ns.charDb.roleSyncOffered, ns.charDb.roleSyncTick = nil, nil, nil
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
    ns.on("ROLE_CHANGED_INFORM", onRoleChanged)
end

ns.RoleSync = RoleSync
