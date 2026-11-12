local _, ns = ...

local Dungeons = ns.Dungeons
local Widgets = ns.Widgets
local Log = ns.Log

-- Follows a dungeon run: which bosses are down, and how many bosses the
-- dungeon has (learned from earlier runs: the most ever killed in one run).
-- When a player leaves the full group before every boss is down, the leader
-- is asked whether to queue the group for a replacement.
local Run = {}

local POPUP = "DUNGEONQUEUE_REPLACEMENT"
local SAME_RUN = 2 * 3600

local run
local journalChecked = {}
local lastNames = {}
local lastSize = 0
local lastLeaver

local function setRun(value)
    run = value
    ns.charDb.run = value
end

local function killCount()
    local count = 0
    for _ in pairs(run and run.kills or {}) do
        count = count + 1
    end
    return count
end

local function bossCounts()
    ns.db.bossCounts = ns.db.bossCounts or {}
    return ns.db.bossCounts
end

-- Remembers how many bosses this run killed, once it is over. Not for a
-- run whose wing was a guess (an area with several dungeons).
local function commitRun()
    if not run or run.ambiguous then
        return
    end
    local count = killCount()
    if count > (bossCounts()[run.dungeon] or 0) then
        bossCounts()[run.dungeon] = count
    end
end

local function endRun()
    commitRun()
    setRun(nil)
end

local function journalCounts()
    ns.db.journalBossCounts = ns.db.journalBossCounts or {}
    return ns.db.journalBossCounts
end

local function encounterCount(journal)
    if type(journal) ~= "number" or journal == 0 or type(EJ_GetEncounterInfoByIndex) ~= "function" then
        return nil
    end
    local count = 0
    while count < 40 do
        local ok, name = pcall(EJ_GetEncounterInfoByIndex, count + 1, journal)
        if not ok or not name then
            break
        end
        count = count + 1
    end
    return count > 0 and count or nil
end

local function insideOf(dungeon)
    if not IsInInstance() then
        return false
    end
    for _, id in ipairs(Dungeons.forArea((GetInstanceInfo()))) do
        if id == dungeon then
            return true
        end
    end
    return false
end

-- The Adventure Guide's bosses of the dungeon, found by the map the player
-- stands on inside it, once per visit; remembered for later.
local function journalTotal(dungeon)
    local fromEntrance = encounterCount(ns.Entrances.journalInstance(dungeon))
    if fromEntrance then
        return fromEntrance
    end
    if journalChecked[dungeon] or not insideOf(dungeon) then
        return journalCounts()[dungeon]
    end
    journalChecked[dungeon] = true
    local count
    if type(EJ_GetInstanceForMap) == "function" and C_Map and C_Map.GetBestMapForUnit then
        local okMap, map = pcall(C_Map.GetBestMapForUnit, "player")
        local okJournal, journal = pcall(EJ_GetInstanceForMap, okMap and map or 0)
        count = okJournal and encounterCount(journal) or nil
    end
    if count and journalCounts()[dungeon] ~= count then
        journalCounts()[dungeon] = count
        Log.debug("%s has %d bosses in the Adventure Guide", Dungeons.name(dungeon), count)
    end
    return count or journalCounts()[dungeon]
end

-- How many bosses the dungeon has: WoW's Adventure Guide when it lists the
-- dungeon, else the built-in count (core/dungeons.lua); the most ever killed
-- in one run here when that is higher.
function Run.bossTotal(dungeon)
    local listed = journalTotal(dungeon)
    if not listed then
        listed = Dungeons.get(dungeon) and Dungeons.get(dungeon).bosses
    end
    local learnedCount = bossCounts()[dungeon]
    if listed and learnedCount then
        return math.max(listed, learnedCount)
    end
    return listed or learnedCount
end

-- { dungeon, kills, total } for the run in progress, or nil. No total for a
-- run whose wing was a guess.
function Run.current()
    if not run then
        return nil
    end
    return { dungeon = run.dungeon, kills = killCount(),
        total = not run.ambiguous and Run.bossTotal(run.dungeon) or nil }
end

-- Whether the player is inside the dungeon of the run.
function Run.isInside()
    return run ~= nil and insideOf(run.dungeon)
end

-- "3/8 bosses", or "3 bosses down" while the total is not known.
function Run.describe(info)
    if info.total then
        return string.format("%d/%d bosses", math.min(info.kills, info.total), info.total)
    end
    return string.format("%d boss%s down", info.kills, info.kills == 1 and "" or "es")
end

local function finished(info)
    return info.total ~= nil and info.total > 0 and info.kills >= info.total
end

local function partyNames()
    local members = ns.Party.members()
    if not members then
        return nil
    end
    local names = {}
    for _, member in ipairs(members) do
        names[member.name] = true
    end
    return names
end

-- The same group: at least one of the run's party members is still here
-- (or the player was and is alone).
local function sameGroup(members)
    local now = partyNames() or {}
    local any = false
    for name in pairs(members or {}) do
        any = true
        if now[name] then
            return true
        end
    end
    return not any and next(now) == nil
end

local function startRun(dungeon, instanceId, ambiguous)
    endRun()
    setRun({ dungeon = dungeon, instance = instanceId, kills = {}, startedAt = GetServerTime(),
        lastAt = GetServerTime(), members = partyNames() or {}, ambiguous = ambiguous or nil })
    Log.debug("run started: %s", Dungeons.name(dungeon))
end

-- Entering another instance, or coming out without a group, ends the run;
-- coming out with the group keeps it (they may go back in).
local function onEnteringWorld()
    journalChecked = {}
    local inInstance, kind = IsInInstance()
    if not inInstance then
        if run and not IsInGroup() then
            endRun()
        end
        return
    end
    local name, _, _, _, _, _, _, instanceId = GetInstanceInfo()
    local ids = kind == "party" and Dungeons.forArea(name) or {}
    if #ids == 0 then
        if run then
            endRun()
        end
        return
    end
    local dungeon, known = ids[1], #ids == 1
    local tracked = ns.GroupView.trackedDungeon()
    for _, id in ipairs(ids) do
        if id == tracked or (run and id == run.dungeon) then
            dungeon, known = id, known or id == tracked or not run.ambiguous
        end
    end
    if run and run.dungeon == dungeon and run.instance == instanceId and sameGroup(run.members)
        and GetServerTime() - (run.lastAt or run.startedAt) < SAME_RUN then
        run.lastAt = GetServerTime()
        return
    end
    startRun(dungeon, instanceId, not known)
end

local function isSecret(value)
    if canaccessvalue ~= nil then
        return not canaccessvalue(value)
    end
    return issecretvalue ~= nil and issecretvalue(value) == true
end

-- Inside an instance WoW may hand the boss name as a secret value: it is
-- only kept when it can be read.
-- Only kills inside the run's dungeon count; a boss killed again means the
-- group started over (a new run of the same dungeon).
local function onEncounterEnd(encounterId, encounterName, _, _, success)
    if not run or isSecret(encounterId) or isSecret(success) or type(encounterId) ~= "number" or success ~= 1
        or not insideOf(run.dungeon) then
        return
    end
    if run.kills[tostring(encounterId)] then
        startRun(run.dungeon, run.instance, run.ambiguous)
    end
    local name = not isSecret(encounterName) and type(encounterName) == "string" and encounterName or true
    run.lastAt = GetServerTime()
    run.kills[tostring(encounterId)] = name
    ns.charDb.run = run
    Log.debug("boss down: %s (%s)", name == true and "a boss" or name, Run.describe(Run.current()))
end


-- Queues the party for the roles the leaver left open: Forever Groups players
-- and WoW's Group Finder both look, as with Find group. From a click only.
function Run.findReplacement()
    local dungeon = run and run.dungeon or ns.GroupView.dungeon()
    local composition = ns.GroupView.composition()
    local open = composition.open
    if not dungeon or open == "" or ns.Party.state() ~= "leader" then
        return false
    end
    local members, names = {}, {}
    for _, member in ipairs(composition.members) do
        names[#names + 1] = member.name
        local entry = { name = member.name, roles = member.role or "D", level = UnitLevel(member.unit or "player") }
        if member.name == ns.selfName then
            table.insert(members, 1, entry)
        else
            members[#members + 1] = entry
        end
    end
    for _, member in ipairs(members) do
        ns.RoleSync.expect(member.name, member.roles)
    end
    if lastLeaver then
        names[#names + 1] = lastLeaver
    end
    ns.LfgList.search()
    if ns.engine and not ns.engine.myEntry then
        ns.join(members, { dungeon })
    end
    if ns.Features.fill() then
        ns.Filler.start({ dungeon = dungeon, missing = open, members = names })
    end
    Log.info("Looking for a replacement %s for %s.", Widgets.describeRoles(open), Dungeons.name(dungeon))
    local lockdown = C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()
    if not ns.db.noPartyAnnounce and not lockdown then
        local text = ns.Messages.text("partyReplacement", { role = Widgets.describeRoles(open) })
        if text then
            pcall(C_ChatInfo.SendChatMessage or SendChatMessage, text, "PARTY")
        end
    end
    return true
end

local function ask(leaver, open, info)
    local bosses = info and (Run.describe(info) .. (info.total and " down" or "") .. ". ") or ""
    StaticPopupDialogs[POPUP] = {
        text = string.format("%s left the group. %sQueue the group to find a replacement %s?",
            leaver or "Someone", bosses, Widgets.describeRoles(open)),
        button1 = "Find replacement",
        button2 = "No",
        OnAccept = function()
            Run.findReplacement()
        end,
        timeout = 60,
        whileDead = true,
        hideOnEscape = true,
    }
    ns.Notify.attention()
    pcall(StaticPopup_Show, POPUP)
end

local function onRosterUpdate()
    local names = partyNames()
    if not names then
        return
    end
    local size = 1
    for _ in pairs(names) do
        size = size + 1
    end
    local hadFull, previous = lastSize >= 5, lastNames
    lastSize, lastNames = size, names
    if not hadFull or size >= 5 or size < 2 or ns.Party.state() ~= "leader" or ns.Filler.isActive() then
        return
    end
    local tracked = ns.GroupView.trackedDungeon()
    local current = run and (not tracked or run.dungeon == tracked) and run or nil
    local dungeon = current and current.dungeon or ns.GroupView.dungeon()
    if not dungeon then
        return
    end
    local info = current and Run.current() or nil
    if info and finished(info) then
        Log.info("Someone left, but every boss is down; no replacement needed.")
        return
    end
    local leaver
    for name in pairs(previous) do
        if not names[name] then
            leaver = name
        end
    end
    lastLeaver = leaver
    if leaver then
        ns.RoleSync.forget(leaver)
    end
    local open = ns.GroupView.composition().open
    if open ~= "" then
        ask(leaver, open, info)
    end
end

local function onLeavingInstance()
    if run and not IsInInstance() and not IsInGroup() then
        endRun()
    end
end

function Run.init()
    local saved = ns.charDb.run
    if saved and saved.startedAt and GetServerTime() - (saved.lastAt or saved.startedAt) < SAME_RUN then
        run = saved
    else
        setRun(nil)
    end
    ns.on("PLAYER_ENTERING_WORLD", onEnteringWorld)
    ns.on("ENCOUNTER_END", onEncounterEnd)
    ns.on("GROUP_ROSTER_UPDATE", onRosterUpdate)
    ns.on("GROUP_ROSTER_UPDATE", onLeavingInstance)
end

ns.Run = Run
