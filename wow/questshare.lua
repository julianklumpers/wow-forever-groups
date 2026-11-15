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
    if string.sub(text, 1, 6) == "v1|QA|" then
        local dungeon = string.sub(text, 7)
        if sender ~= ns.selfName and IsInGroup() and Dungeons.get(dungeon) then
            local saved = ns.charDb.questShare
            if not saved or saved.dungeon ~= dungeon then
                saved = { dungeon = dungeon, sharedTo = {} }
                ns.charDb.questShare = saved
            end
            saved.heardAsk = true
        end
        return true
    end
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
        QuestShare.listArrived()
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

-- The quest shared last and when: WoW's answers ("too far away", "busy")
-- name the player, not the quest.
local lastPush

local function push(questId)
    lastPush = { id = questId, at = GetTime() }
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

-- Sharing by itself: once the lists of the party's Forever Groups players
-- are in, each of our quests for the dungeon that a party member lacks is
-- shared, by one holder only (the first by name of the Forever Groups
-- players who have it). A member without Forever Groups sends no list: it
-- gets every shareable quest unless WoW says it has it (WoW's answer is not
-- reliable at a distance, and shares to members who have it are skipped by
-- WoW anyway). Each quest goes once per member.
local AUTO_DELAY = 5
local autoScheduled = false

-- What was shared, and whether the party was asked, for the group's dungeon;
-- kept per character so a /reload in the middle of a run does not start
-- over. Cleared on leaving the group or for another dungeon.
local function memory(dungeon)
    local saved = ns.charDb.questShare
    if not saved or saved.dungeon ~= dungeon then
        saved = { dungeon = dungeon, sharedTo = {} }
        ns.charDb.questShare = saved
    end
    return saved
end

local function unitOnQuest(unit, questId)
    local fn = C_QuestLog and C_QuestLog.IsUnitOnQuest
    if type(fn) ~= "function" then
        return false
    end
    local ok, on = pcall(fn, unit, questId)
    return ok and on == true
end

-- The members who still need the quest, or nil while a Forever Groups
-- member's list has not come in yet (patient; else, as for a version that
-- sends none, it counts as unknown).
local function lacking(questId, party, known, patient, sharedTo)
    local names = {}
    for _, member in ipairs(party) do
        local set = known[member.name]
        if not set and patient and ns.Presence.isOnline(member.name) then
            return nil
        end
        local has = set and set[questId] or (not set and unitOnQuest(member.unit, questId))
        if not has and not (sharedTo[questId] and sharedTo[questId][member.name]) then
            names[#names + 1] = member.name
        end
    end
    return names
end

-- Whether we are the one to share it: the first by name of the Forever
-- Groups players who hold it.
local function isSharer(questId, known)
    for name, set in pairs(known) do
        if set[questId] and name < ns.selfName then
            return false
        end
    end
    return true
end

function QuestShare.autoShare(patient)
    local dungeon = ns.GroupView.trackedDungeon()
    local party = ns.Party.members()
    if ns.db.noAutoShareQuests or not dungeon or not party or #party == 0 then
        return 0
    end
    local known = lists[dungeon] or {}
    local sharedTo = memory(dungeon).sharedTo
    local queue = {}
    for _, quest in ipairs(ns.Quests.entriesFor(dungeon)) do
        local id = quest.questID
        if id and isPushable(id) and isSharer(id, known) then
            local names = lacking(id, party, known, patient, sharedTo)
            if names == nil then
                C_Timer.After(AUTO_DELAY, function()
                    QuestShare.autoShare(false)
                end)
                return 0
            end
            if #names > 0 then
                sharedTo[id] = sharedTo[id] or {}
                for _, name in ipairs(names) do
                    sharedTo[id][name] = true
                end
                queue[#queue + 1] = quest
            end
        end
    end
    for i, quest in ipairs(queue) do
        C_Timer.After((i - 1) * SHARE_SPACING, function()
            push(quest.questID)
        end)
    end
    if #queue == 1 then
        Log.info("Sharing 1 quest for %s with your group.", Dungeons.name(dungeon))
    elseif #queue > 1 then
        Log.info("Sharing %d quests for %s with your group.", #queue, Dungeons.name(dungeon))
    end
    QuestShare.askParty(dungeon, party, known)
    return #queue
end

-- Members without Forever Groups send no list, so their quests are unknown:
-- each Forever Groups player asks the party once, on coming into a group with
-- such a member, to share theirs: also a player who joins a group whose run
-- is under way. Not a player who already saw a boss die in this run (a
-- /reload mid-run), nor when another Forever Groups player in the group just
-- asked (`v1|QA|dungeon` on the PARTY addon channel); at a new group the
-- first by name asks and the others hear it.
local ASK = "v1|QA|"
local ASK_STAGGER = 3

local function sawBossDie()
    local run = ns.Run.current()
    return run ~= nil and (run.kills or 0) > 0
end

function QuestShare.askParty(dungeon, party, known)
    local saved = memory(dungeon)
    if saved.askedParty or saved.heardAsk or ns.db.noPartyAnnounce or sawBossDie() then
        return false
    end
    local withoutAddon, rank = false, 0
    for _, member in ipairs(party) do
        local hasAddon = known[member.name] ~= nil or ns.Presence.isOnline(member.name)
        if not hasAddon then
            withoutAddon = true
        elseif member.name < ns.selfName then
            rank = rank + 1
        end
    end
    if not withoutAddon then
        return false
    end
    saved.askedParty = true
    C_Timer.After(rank * ASK_STAGGER, function()
        if ns.charDb.questShare ~= saved or saved.heardAsk or not IsInGroup()
            or (C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()) then
            return
        end
        local text = ns.Messages.text("partyAskQuests", { dungeon = Dungeons.englishName(dungeon) })
        if text then
            ns.Comm.sendParty(ASK .. dungeon)
            ns.Whispers.sayParty(text)
        end
    end)
    return true
end

-- A share WoW turned down because the player is too far away (still outside
-- while we are in the dungeon) or busy: it is tried again every RETRY_GAP
-- seconds, at most RETRIES times, until it reaches them.
local RETRY_GAP, RETRIES = 15, 20
local retryScheduled = false
local pushRefusals

local function refusalPatterns()
    if not pushRefusals then
        pushRefusals = {}
        for _, key in ipairs({ "ERR_QUEST_PUSH_TOO_FAR_S", "ERR_QUEST_PUSH_BUSY_S" }) do
            local format = _G[key]
            if type(format) == "string" then
                local pattern = string.gsub(format, "([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
                pushRefusals[#pushRefusals + 1] = "^" .. string.gsub(pattern, "%%s", "(.+)") .. "$"
            end
        end
    end
    return pushRefusals
end

local function onSystem(text)
    local saved = ns.charDb.questShare
    if type(text) ~= "string" or not saved or not lastPush or GetTime() - lastPush.at > SHARE_SPACING then
        return
    end
    for _, pattern in ipairs(refusalPatterns()) do
        local name = string.match(text, pattern)
        local shared = name and saved.sharedTo[lastPush.id]
        local key = shared and ns.Whispers.find(shared, name)
        if key then
            saved.tries = saved.tries or {}
            local tries = (saved.tries[key] or 0) + 1
            saved.tries[key] = tries
            if tries <= RETRIES then
                shared[key] = nil
                if not retryScheduled then
                    retryScheduled = true
                    C_Timer.After(RETRY_GAP, function()
                        retryScheduled = false
                        QuestShare.autoShare(false)
                    end)
                end
            end
            return
        end
    end
end

local function autoShareSoon()
    if autoScheduled or ns.db.noAutoShareQuests then
        return
    end
    autoScheduled = true
    C_Timer.After(AUTO_DELAY, function()
        autoScheduled = false
        QuestShare.autoShare(true)
    end)
end

-- A list came in: the sharing waits a little for the others' too.
function QuestShare.listArrived()
    if ns.GroupView.trackedDungeon() then
        autoShareSoon()
    end
end

-- The group's dungeon and the party's names, to tell a real change (a group
-- for a dungeon, someone joined or left) from the other roster updates (a
-- level up, a role, a zone).
local lastRoster

local function rosterKey()
    local names = {}
    for _, member in ipairs(ns.Party.members() or {}) do
        names[#names + 1] = member.name
    end
    table.sort(names)
    return tostring(ns.GroupView.trackedDungeon()) .. "|" .. table.concat(names, ",")
end

function QuestShare.init()
    ns.on("GROUP_ROSTER_UPDATE", function()
        if not IsInGroup() then
            ns.charDb.questShare, lastRoster = nil, nil
            return
        end
        local key = rosterKey()
        if key == lastRoster then
            return
        end
        lastRoster = key
        if ns.GroupView.trackedDungeon() then
            sendSoon(true)
            autoShareSoon()
        end
    end)
    ns.on("CHAT_MSG_SYSTEM", onSystem)
    -- Logged out in a group and back alone: that group's sharing is over.
    ns.on("PLAYER_ENTERING_WORLD", function()
        if not IsInGroup() then
            ns.charDb.questShare = nil
        end
    end)
    ns.on("QUEST_LOG_UPDATE", function()
        if ns.GroupView.trackedDungeon() then
            sendSoon(false)
        end
    end)
end

ns.QuestShare = QuestShare
