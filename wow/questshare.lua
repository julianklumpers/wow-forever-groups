local _, ns = ...

local Dungeons = ns.Dungeons
local Log = ns.Log

-- Dungeon quests in a new group: party members with Forever Groups tell each
-- other which quests they have for the dungeon (PARTY addon messages), so the
-- window shows who has what, and one click shares your own quests with the
-- group, one at a time.
local QuestShare = {}

local LIST = "v1|QL|"
local REQUEST = "v1|QR|"
local SEND_DELAY = 2
local SHARE_SPACING = 1.5

local lists = {}
local sendScheduled = false
local requestNext = false

local function myQuestIds(dungeon)
    local ids = {}
    for _, quest in ipairs(ns.Quests.entriesFor(dungeon)) do
        if quest.questID then
            ids[#ids + 1] = quest.questID
        end
    end
    return ids
end

local function sendList(dungeon, request)
    ns.Comm.sendParty(LIST .. dungeon .. "|" .. table.concat(myQuestIds(dungeon), ","))
    if request then
        ns.Comm.sendParty(REQUEST .. dungeon)
    end
end

-- Sends our list (and asks for the others') a moment after things settle, so
-- a burst of roster or quest log changes sends one message.
local function sendSoon(request)
    requestNext = requestNext or request
    if sendScheduled then
        return
    end
    sendScheduled = true
    C_Timer.After(SEND_DELAY, function()
        sendScheduled = false
        local dungeon = ns.GroupView.trackedDungeon()
        if dungeon then
            sendList(dungeon, requestNext)
        end
        requestNext = false
    end)
end

-- From the PARTY addon channel; returns true when the message was ours.
function QuestShare.onMessage(sender, text)
    if string.sub(text, 1, #REQUEST) == REQUEST then
        local dungeon = string.sub(text, #REQUEST + 1)
        if sender ~= ns.selfName and Dungeons.get(dungeon) then
            sendList(dungeon, false)
        end
        return true
    end
    if string.sub(text, 1, #LIST) ~= LIST then
        return false
    end
    local dungeon, ids = string.match(text, "^v1|QL|(%w+)|([%d,]*)$")
    if dungeon and sender ~= ns.selfName then
        local set = {}
        for id in string.gmatch(ids, "%d+") do
            set[tonumber(id)] = true
        end
        lists[dungeon] = lists[dungeon] or {}
        lists[dungeon][sender] = set
    end
    return true
end

local function titleOf(questId)
    if C_QuestLog and C_QuestLog.GetTitleForQuestID then
        local ok, title = pcall(C_QuestLog.GetTitleForQuestID, questId)
        if ok and type(title) == "string" and title ~= "" then
            return title
        end
    end
    return "quest " .. questId
end

local function count(set)
    local n = 0
    for _ in pairs(set) do
        n = n + 1
    end
    return n
end

-- For the window: { mine = n, members = { { name, count or nil } },
-- theyHave = { titles of quests others have that we lack } }, or nil.
function QuestShare.summary(dungeon)
    local party = ns.Party.members()
    if not dungeon or not party or #party == 0 then
        return nil
    end
    local mine, have = myQuestIds(dungeon), {}
    for _, id in ipairs(mine) do
        have[id] = true
    end
    local known = lists[dungeon] or {}
    local members, theyHave, seen = {}, {}, {}
    for _, member in ipairs(party) do
        local set = known[member.name]
        members[#members + 1] = { name = member.name, count = set and count(set) or nil, quests = set }
        for id in pairs(set or {}) do
            if not have[id] and not seen[id] then
                seen[id] = true
                theyHave[#theyHave + 1] = titleOf(id)
            end
        end
    end
    return { mine = #mine, members = members, theyHave = theyHave }
end

local function isPushable(questId)
    if C_QuestLog and C_QuestLog.IsPushableQuest then
        local ok, pushable = pcall(C_QuestLog.IsPushableQuest, questId)
        return ok and pushable == true
    end
    return true
end

local function push(questId)
    if C_QuestLog and C_QuestLog.SetSelectedQuest then
        pcall(C_QuestLog.SetSelectedQuest, questId)
    end
    if type(QuestLogPushQuest) == "function" then
        local ok, err = pcall(QuestLogPushQuest)
        Log.debug("share quest %d: %s", questId, ok and "ok" or tostring(err))
    end
end

-- Shares every quest we have for the dungeon that can be shared. Returns how
-- many will be shared.
function QuestShare.shareMine(dungeon)
    local queue = {}
    for _, quest in ipairs(ns.Quests.entriesFor(dungeon or "")) do
        if quest.questID and isPushable(quest.questID) then
            queue[#queue + 1] = quest
        end
    end
    if #queue == 0 then
        Log.info("You have no quests for %s that can be shared.", Dungeons.name(dungeon or ""))
        return 0
    end
    for i, quest in ipairs(queue) do
        C_Timer.After((i - 1) * SHARE_SPACING, function()
            push(quest.questID)
        end)
    end
    if #queue == 1 then
        Log.info("Sharing 1 quest for %s with your group.", Dungeons.name(dungeon))
    else
        Log.info("Sharing %d quests for %s with your group.", #queue, Dungeons.name(dungeon))
    end
    return #queue
end

function QuestShare.init()
    ns.on("GROUP_ROSTER_UPDATE", function()
        if ns.GroupView.trackedDungeon() then
            sendSoon(true)
        end
    end)
    ns.on("QUEST_LOG_UPDATE", function()
        if ns.GroupView.trackedDungeon() then
            sendSoon(false)
        end
    end)
end

ns.QuestShare = QuestShare
