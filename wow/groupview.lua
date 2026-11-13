local _, ns = ...

local L = ns.L

local Dungeons = ns.Dungeons
local Party = ns.Party
local Widgets = ns.Widgets
local Log = ns.Log

-- Follows a party that Forever Groups helped to form: who plays what, which
-- slots are still open, and the moment it is complete.
local GroupView = {}

local LETTER = { TANK = "T", HEALER = "H", DAMAGER = "D" }
local SLOT_ORDER = { "T", "H", "D", "D", "D" }
local JOIN_TIMEOUT = 180
local MAX_AGE = 3 * 3600

local context

-- Called when Forever Groups starts building a group for this dungeon.
-- Saved per character so the tracked group survives a /reload.
local function setContext(value)
    context = value
    if ns.charDb then
        ns.charDb.groupContext = value
    end
end

-- playstyles: the formed group's (core/playstyles.lua ids), if known.
function GroupView.track(dungeon, playstyles)
    if not context or context.dungeon ~= dungeon or context.entered then
        setContext({ dungeon = dungeon, announced = false, startedAt = GetServerTime() })
        ns.Entrances.request(dungeon)
        ns.QuestGroup.startDungeon(dungeon)
    end
    if playstyles and #playstyles > 0 then
        context.playstyles = playstyles
    end
end

function GroupView.playstyles()
    return GroupView.dungeon() and context.playstyles or {}
end

-- "The Deadmines (Relaxed)", or just the name without a known playstyle.
local function groupName()
    local name = Dungeons.name(context.dungeon)
    local styles = ns.Playstyle.describe(context.playstyles)
    return styles and (name .. " (" .. styles .. ")") or name
end

-- The dungeon of the group being followed, while outside it; else nil.
function GroupView.dungeon()
    return context and not context.entered and context.dungeon or nil
end

-- The dungeon of the group being followed, inside it as well; else nil.
function GroupView.trackedDungeon()
    return context and IsInGroup() and context.dungeon or nil
end

-- After loading: picks up the tracked group if the player is still in it.
-- early: right at login, when the group may not be known yet; then only
-- follows a saved group that is already there, and forgets nothing.
function GroupView.restore(early)
    local saved = ns.charDb.groupContext
    if early and not (saved and saved.dungeon and IsInGroup()) then
        return
    end
    if not saved or not saved.dungeon or GetServerTime() - (saved.startedAt or 0) > MAX_AGE then
        setContext(nil)
        return
    end
    if IsInGroup() or (not saved.joined and GetServerTime() - (saved.startedAt or 0) <= JOIN_TIMEOUT) then
        context = saved
    else
        setContext(nil)
    end
end

function GroupView.partySize()
    return #GroupView.composition().members
end

function GroupView.isTracking()
    return context ~= nil
end

-- In the followed group and its run still ahead or going on: not once the
-- group came back out of the dungeon.
function GroupView.isActive()
    return context ~= nil and IsInGroup() and (not context.entered or IsInInstance() == true)
end

-- Stops following the group (another kind of group took its place).
function GroupView.forget()
    setContext(nil)
end

local function roleOf(unit, name)
    local assigned = UnitGroupRolesAssigned and LETTER[UnitGroupRolesAssigned(unit)]
    return assigned or ns.RoleSync.expected(name) or ns.Filler.roleOf(name)
end

-- { members = { { name, role } }, slots = { { role, name } x5 }, open = "D" }
function GroupView.composition()
    local members = {}
    for _, unit in ipairs({ "player", "party1", "party2", "party3", "party4" }) do
        if unit == "player" or UnitExists(unit) then
            local name = Party.unitName(unit)
            if name then
                local _, classToken = UnitClass(unit)
                members[#members + 1] = { name = name, role = roleOf(unit, name), classToken = classToken, unit = unit }
            end
        end
    end
    -- Every member in the place of their own role (two tanks show as two
    -- tanks), then the open places: the roles a group of one tank, one
    -- healer and three DPS still lacks, as far as places are left. A member
    -- without a known role takes a place that is lacking.
    local lacking, counts = {}, { T = 0, H = 0, D = 0 }
    for _, member in ipairs(members) do
        if counts[member.role] then
            counts[member.role] = counts[member.role] + 1
        end
    end
    for _, role in ipairs({ "T", "H", "D" }) do
        for _ = counts[role] + 1, ns.Config.SLOTS[role] do
            lacking[#lacking + 1] = role
        end
    end
    local order = { T = 1, H = 2, D = 3 }
    local placed = {}
    for i, member in ipairs(members) do
        local role = member.role
        if not order[role] then
            role = table.remove(lacking, 1) or "D"
        end
        placed[#placed + 1] = { role = role, name = member.name, classToken = member.classToken, unit = member.unit,
            index = i }
    end
    table.sort(placed, function(x, y)
        if order[x.role] ~= order[y.role] then
            return order[x.role] < order[y.role]
        end
        return x.index < y.index
    end)
    local slots = {}
    for _, slot in ipairs(placed) do
        slots[#slots + 1] = { role = slot.role, name = slot.name, classToken = slot.classToken, unit = slot.unit }
    end
    local open = ""
    for _, role in ipairs(lacking) do
        if #slots < #SLOT_ORDER then
            slots[#slots + 1] = { role = role }
            open = open .. role
        end
    end
    while #slots < #SLOT_ORDER do
        slots[#slots + 1] = { role = "D" }
        open = open .. "D"
    end
    return { members = members, slots = slots, open = open }
end

local function describeOpen(open)
    local names = {}
    for letter in string.gmatch(open, ".") do
        names[#names + 1] = Widgets.roleName(letter)
    end
    return table.concat(names, ", ")
end

-- Status for the bar and window while in a tracked group, or nil.
function GroupView.status()
    if not context or not IsInGroup() then
        return nil
    end
    local composition = GroupView.composition()
    local count = #composition.members
    local name = Dungeons.name(context.dungeon)
    local status = {
        slots = composition.slots, complete = count >= 5, count = count, dungeon = context.dungeon,
        playstyles = context.playstyles or {}, openText = describeOpen(composition.open),
        inside = context.entered == true,
    }
    local run = status.inside and ns.Run.current()
    if run and run.dungeon == context.dungeon then
        status.run = ns.Run.describe(run)
    end
    -- For the status bar; the window's card spells it out. progress fills
    -- the bar: the bosses down inside, the players found outside.
    if status.complete then
        status.text = name .. "  ·  " .. (status.run or L["group complete"])
    else
        status.text = string.format(L["%s  ·  %d/5  ·  open: %s"], name, count, status.openText)
        if status.run then
            status.text = status.text .. "  ·  " .. status.run
        end
    end
    if run and run.dungeon == context.dungeon and run.total and run.total > 0 then
        status.progress = math.min(run.kills, run.total) / run.total
    elseif not status.inside then
        status.progress = math.min(count, 5) / 5
    end
    return status
end

-- One line per slot for the window, for any party the player is in.
function GroupView.lines()
    if not IsInGroup() then
        return nil
    end
    local lines = {}
    for _, slot in ipairs(GroupView.composition().slots) do
        lines[#lines + 1] = Widgets.ROLE_NAMES[slot.role] .. ": " .. (slot.name or "(open)")
    end
    return lines
end

local function announce()
    local dungeon = groupName()
    local text = "Group complete! " .. dungeon
    if RaidNotice_AddMessage and RaidWarningFrame then
        pcall(RaidNotice_AddMessage, RaidWarningFrame, text, ChatTypeInfo and ChatTypeInfo.RAID_WARNING)
    end
    if PlaySound and not ns.db.noSound then
        pcall(PlaySound, SOUNDKIT and SOUNDKIT.READY_CHECK or 8960)
    end
    Log.info("Your group for %s is complete.", dungeon)
    if not IsInInstance() and not ns.Entrances.setWaypoint(context.dungeon) then
        ns.Entrances.request(context.dungeon)
    end
    local lockdown = C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()
    if Party.state() == "leader" and not ns.db.noPartyAnnounce and not lockdown then
        local announcement = ns.Messages.text("partyComplete", { dungeon = Dungeons.englishName(context.dungeon) })
        if announcement then
            pcall(C_ChatInfo.SendChatMessage or SendChatMessage, announcement, "PARTY")
        end
    end
    ns.Filler.stop(true)
    if ns.engine and ns.engine.myEntry then
        ns.engine:leave()
    end
    if ns.Listing.isOurs() then
        Log.info("Your Group Finder listing is removed on your next key press.")
    elseif GroupView.isListed() and Party.state() == "leader" then
        Log.info("You are still listed in WoW's Group Finder. Remove the listing in the Forever Groups window.")
    end
end

-- Watches for the moment the tracked group becomes complete.
function GroupView.check()
    if not context then
        return
    end
    if not IsInGroup() then
        if context.joined or GetServerTime() - context.startedAt > JOIN_TIMEOUT then
            setContext(nil)
        end
        return
    end
    context.joined = true
    if context.entered then
        return
    end
    local count = #GroupView.composition().members
    if count >= 5 and not context.announced then
        context.announced = true
        announce()
    elseif count < 5 then
        context.announced = false
    end
end

function GroupView.isListed()
    local fn = C_LFGList and C_LFGList.HasActiveEntryInfo
    if type(fn) ~= "function" then
        return false
    end
    local ok, listed = pcall(fn)
    return ok and listed == true
end

-- Only from a click: removing a listing may be protected.
function GroupView.removeListing()
    local fn = C_LFGList and C_LFGList.RemoveListing
    if type(fn) == "function" then
        local ok, err = pcall(fn)
        Log.debug("remove Group Finder listing: %s", ok and "ok" or tostring(err))
    end
end

local function onEnteringWorld()
    if context and IsInInstance() then
        context.entered = true
    end
end

function GroupView.init()
    ns.on("GROUP_ROSTER_UPDATE", GroupView.check)
    ns.on("PLAYER_ENTERING_WORLD", onEnteringWorld)
end

ns.GroupView = GroupView
