local _, ns = ...

local Log = ns.Log

-- The spec of party members, also those without Forever Groups: out of combat
-- the addon inspects one member at a time (as WoW's Inspect does) and reads
-- the talent points per tree, like the player's own spec.
local InspectSpec = {}

local TIMEOUT = 5
local SPACING = 2
local RETRY = 60
-- Talents can change (respec, dual spec): an inspected member is looked at
-- again after this long.
local REFRESH = 600

local pending
-- The GUID of the newest inspect anyone asked for (WoW keeps one): when it
-- is not ours, the answer is someone else's and is left alone.
local lastAsked
local lastAt = -math.huge
local tried = {}
local inspectedAt = {}

local function isSecret(value)
    if canaccessvalue ~= nil then
        return not canaccessvalue(value)
    end
    return issecretvalue ~= nil and issecretvalue(value) == true
end

local function call(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local ok, value = pcall(fn, ...)
    return ok and value or nil
end

local function inspectConfig()
    local consts = type(Constants) == "table" and Constants.TraitConsts
    return type(consts) == "table" and consts.INSPECT_TRAIT_CONFIG_ID or nil
end

-- The player's own inspect window gets the data of every inspect: leave it
-- alone while it is open.
local function playerInspecting()
    return InspectFrame ~= nil and InspectFrame:IsShown()
end

-- The next member to inspect: one close by first, else one further away
-- (on Forever a member outside the dungeon can be inspected from inside:
-- the player's own inspect does it, 2026-11-17).
local function nextUnit()
    local now = GetTime()
    local far
    for i = 1, 4 do
        local unit = "party" .. i
        local name = ns.Party.unitName(unit)
        local due = not ns.Spec.treeOf(name) or (inspectedAt[name] and now - inspectedAt[name] >= REFRESH)
        if name and due and now - (tried[name] or -math.huge) >= RETRY and call(CanInspect, unit) == true then
            if call(CheckInteractDistance, unit, 1) == true then
                return unit, name
            end
            far = far or { unit, name }
        end
    end
    if far then
        return far[1], far[2]
    end
end

function InspectSpec.tick()
    local now = GetTime()
    if pending and now - pending.at > TIMEOUT then
        Log.debug("inspecting %s: no answer within %d s", pending.name, TIMEOUT)
        pending = nil
    end
    if pending or not IsInGroup() or now - lastAt < SPACING or InCombatLockdown() or playerInspecting()
        or not inspectConfig() or type(NotifyInspect) ~= "function" then
        return
    end
    local unit, name = nextUnit()
    if not unit then
        return
    end
    tried[name], lastAt = now, now
    local guid = call(UnitGUID, unit)
    if type(guid) ~= "string" or isSecret(guid) then
        return
    end
    pending = { unit = unit, name = name, guid = guid, at = now }
    if not pcall(NotifyInspect, unit) then
        pending = nil
    end
end

local function onReady(guid)
    if not pending or isSecret(guid) or guid ~= pending.guid then
        return
    end
    local asked = pending
    pending = nil
    if lastAsked ~= nil and lastAsked ~= asked.guid or playerInspecting() then
        return
    end
    if ns.Party.unitName(asked.unit) == asked.name then
        local _, classToken = UnitClass(asked.unit)
        local points, detail = ns.Spec.pointsOf(inspectConfig())
        local code = ns.Spec.learn(asked.name, classToken, points)
        inspectedAt[asked.name] = GetTime()
        Log.debug("inspected %s: %s (%s)", asked.name, tostring(code), tostring(detail))
    end
    call(ClearInspectPlayer)
end

function InspectSpec.init()
    ns.on("INSPECT_READY", onReady)
    if type(hooksecurefunc) == "function" and type(NotifyInspect) == "function" then
        hooksecurefunc("NotifyInspect", function(unit)
            local guid = call(UnitGUID, unit)
            lastAsked = type(guid) == "string" and not isSecret(guid) and guid or false
        end)
    end
end

ns.InspectSpec = InspectSpec
