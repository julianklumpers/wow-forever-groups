local _, ns = ...

local L = ns.L

local Log = ns.Log

-- A group's quests after it formed: a questing group's quest, or the
-- player's quests for the dungeon of a dungeon group. Members with
-- Forever Groups send their progress over hidden PARTY addon messages (nothing
-- shows in the chat), the progress window shows it, and once a questing
-- group's shared quests are turned in the player is asked whether to leave.
local QuestGroup = {}

local PREFIX = "v1|QP|"
local SEND_DELAY = 2
local JOIN_TIME = 180
local MAX_AGE = 3 * 3600
local MAX_REPORTED = 12
local POPUP = "DUNGEONQUEUE_QUESTS_DONE"

local context
local reports = {}
local sendScheduled = false

local function setContext(value)
    context = value
    if ns.charDb then
        ns.charDb.questGroup = value
    end
end

local function inLog(questId)
    return ns.Quests.has(questId)
end

local function dungeonQuestIds(dungeon)
    local ids = {}
    for _, quest in ipairs(ns.Quests.entriesFor(dungeon)) do
        if quest.questID then
            ids[#ids + 1] = quest.questID
        end
    end
    return ids
end

-- { done, total, complete } for a quest in the log, else nil.
local function progressOf(questId)
    if not inLog(questId) then
        return nil
    end
    local done, total = 0, 0
    if C_QuestLog and C_QuestLog.GetQuestObjectives then
        local ok, objectives = pcall(C_QuestLog.GetQuestObjectives, questId)
        for _, objective in ipairs(ok and type(objectives) == "table" and objectives or {}) do
            local required = tonumber(objective.numRequired) or 1
            total = total + required
            done = done + math.min(required, tonumber(objective.numFulfilled) or (objective.finished and required or 0))
        end
    end
    local complete = false
    if C_QuestLog and C_QuestLog.IsComplete then
        local ok, value = pcall(C_QuestLog.IsComplete, questId)
        complete = ok and value == true
    end
    return { done = done, total = total, complete = complete or (total > 0 and done >= total) }
end

-- The group's quests and the player's other group quests, which a member
-- may share.
local function reportedQuests()
    local ids, seen = {}, {}
    local function add(id)
        if not seen[id] and #ids < MAX_REPORTED then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    for _, id in ipairs(context and context.quests or {}) do
        add(id)
    end
    if not (context and context.dungeon) then
        for _, quest in ipairs(ns.Quests.groupQuests()) do
            add(quest.questID)
        end
    end
    return ids
end

local function message()
    local parts = {}
    for _, id in ipairs(reportedQuests()) do
        local progress = progressOf(id)
        if progress then
            parts[#parts + 1] = string.format("%d:%d/%d:%d", id, progress.done, progress.total,
                progress.complete and 1 or 0)
        elseif context.turnedIn[id] then
            parts[#parts + 1] = id .. ":t"
        end
    end
    return PREFIX .. table.concat(parts, ",")
end

local function sendSoon()
    if sendScheduled then
        return
    end
    sendScheduled = true
    C_Timer.After(SEND_DELAY, function()
        sendScheduled = false
        if QuestGroup.current() and IsInGroup() then
            ns.Comm.sendParty(message())
        end
    end)
end

function QuestGroup.current()
    if not context then
        return nil
    end
    local age = GetServerTime() - (context.startedAt or 0)
    local waiting = IsInGroup() or (context.dungeon and ns.GroupView.isTracking()) or age <= JOIN_TIME
    if age > MAX_AGE or not waiting then
        setContext(nil)
        reports = {}
        return nil
    end
    return context
end

-- A questing group formed (view.dungeon is its quest key).
function QuestGroup.start(view)
    local questId = tonumber((ns.QuestMatch.parse(view.dungeon)))
    if not questId then
        return
    end
    reports = {}
    -- core: the quest the group formed for; quests also gets the others'
    -- shared quests, for the progress list only.
    setContext({ quests = { questId }, core = { questId }, turnedIn = {}, seen = {}, startedAt = GetServerTime() })
    ns.GroupView.forget()
    sendSoon()
    ns.ProgressWindow.show(true)
end

-- A dungeon group is being built: follow the player's quests for it, and
-- show the window when there are any.
function QuestGroup.startDungeon(dungeon)
    if context and context.dungeon == dungeon then
        return
    end
    reports = {}
    local ids = dungeonQuestIds(dungeon)
    setContext({ dungeon = dungeon, quests = ids, turnedIn = {}, seen = {}, startedAt = GetServerTime() })
    sendSoon()
    if #ids > 0 then
        ns.ProgressWindow.show(true)
    end
end

function QuestGroup.isQuesting()
    return QuestGroup.current() ~= nil and context.dungeon == nil
end

-- Every quest the questing group formed for is turned in.
function QuestGroup.isDone()
    if not QuestGroup.isQuesting() then
        return false
    end
    for _, id in ipairs(context.core or context.quests) do
        if not context.turnedIn[id] then
            return false
        end
    end
    return true
end

function QuestGroup.restore()
    local saved = ns.charDb.questGroup
    if saved and saved.quests then
        saved.turnedIn = saved.turnedIn or {}
        saved.seen = saved.seen or {}
        context = saved
        if QuestGroup.current() then
            sendSoon()
        end
    end
end

local function isShared(questId)
    for _, id in ipairs(context.quests) do
        if id == questId then
            return true
        end
    end
    return false
end

-- From the PARTY addon channel; returns true when the message was ours.
function QuestGroup.onMessage(sender, text)
    if string.sub(text, 1, #PREFIX) ~= PREFIX then
        return false
    end
    local report = {}
    for id, rest in string.gmatch(string.sub(text, #PREFIX + 1), "(%d+):([^,]+)") do
        local done, total, complete = string.match(rest, "^(%d+)/(%d+):([01])$")
        id = tonumber(id)
        if rest == "t" then
            report[id] = { turnedIn = true }
        elseif done then
            report[id] = { done = tonumber(done), total = tonumber(total), complete = complete == "1" }
        end
    end
    reports[sender] = report
    if QuestGroup.current() then
        for id in pairs(report) do
            if not isShared(id) and inLog(id) then
                table.insert(context.quests, id)
            end
        end
    end
    ns.ProgressWindow.refresh()
    return true
end

local function describe(progress)
    if not progress then
        return "-"
    elseif progress.turnedIn then
        return L["done"]
    elseif progress.complete then
        return L["ready to turn in"]
    elseif progress.total > 0 then
        return progress.done .. "/" .. progress.total
    end
    return "started"
end

-- For the progress window: { { title, lines = { { name, text } } } }, and
-- the names of the members without Forever Groups (left out of the lines).
function QuestGroup.rows()
    if not QuestGroup.current() then
        return {}, {}
    end
    local members, without = {}, {}
    for _, member in ipairs(ns.Party.members() or {}) do
        if reports[member.name] or ns.Presence.isOnline(member.name) then
            members[#members + 1] = member
        else
            without[#without + 1] = member.name
        end
    end
    local rows = {}
    for _, id in ipairs(context.quests) do
        local mine = context.turnedIn[id] and { turnedIn = true } or progressOf(id)
        local lines = { { name = L["You"], text = describe(mine) } }
        for _, member in ipairs(members) do
            local report = reports[member.name]
            lines[#lines + 1] = { name = member.name, text = report and describe(report[id]) or "?" }
        end
        rows[#rows + 1] = { title = ns.Quests.titleOf(id), lines = lines }
    end
    return rows, without
end

local function leaveGroup()
    local leave = (C_PartyInfo and C_PartyInfo.LeaveParty) or LeaveParty
    if leave then
        pcall(leave)
    end
    setContext(nil)
    ns.ProgressWindow.hide()
end

local function checkDone()
    if context and context.asked or not QuestGroup.isDone() then
        return
    end
    context.asked = true
    StaticPopupDialogs[POPUP] = {
        text = L["Your shared quests are done. Leave the group?"],
        button1 = L["Leave group"],
        button2 = L["Stay"],
        OnAccept = leaveGroup,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }
    StaticPopup_Show(POPUP)
    ns.Notify.attention()
end

-- Turned in, not abandoned: WoW flags a quest completed once it is turned in.
local function wasTurnedIn(questId)
    if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
        local ok, done = pcall(C_QuestLog.IsQuestFlaggedCompleted, questId)
        return ok and done == true
    end
    return false
end

-- A quest of the group that was in the log and is gone was turned in when
-- WoW flags it completed; an abandoned one is just gone.
local function onQuestLog()
    if not QuestGroup.current() then
        return
    end
    if context.dungeon then
        for _, id in ipairs(dungeonQuestIds(context.dungeon)) do
            if not isShared(id) then
                table.insert(context.quests, id)
            end
        end
    end
    for _, id in ipairs(context.quests) do
        if inLog(id) then
            context.seen[id] = true
        elseif context.seen[id] and not context.turnedIn[id] and wasTurnedIn(id) then
            context.turnedIn[id] = true
            Log.debug("quest %d turned in", id)
        end
    end
    sendSoon()
    checkDone()
    ns.ProgressWindow.refresh()
end

function QuestGroup.init()
    ns.on("QUEST_LOG_UPDATE", onQuestLog)
    ns.on("QUEST_TURNED_IN", function(questId)
        if QuestGroup.current() and isShared(tonumber(questId)) then
            context.turnedIn[tonumber(questId)] = true
            onQuestLog()
        end
    end)
    ns.on("GROUP_ROSTER_UPDATE", function()
        if QuestGroup.current() then
            sendSoon()
            ns.ProgressWindow.refresh()
        else
            ns.ProgressWindow.hide()
        end
    end)
end

ns.QuestGroup = QuestGroup
