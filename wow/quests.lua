local _, ns = ...

local L = ns.L

local Dungeons = ns.Dungeons
local Log = ns.Log

-- The quests in the player's quest log for each dungeon. WoW's quest log
-- lists quests under a header per area, and a dungeon's quests sit under the
-- dungeon's name ("Scarlet Monastery" covers all of its wings).
local Quests = {}

local byDungeon = {}
local entriesByDungeon = {}
local groupQuests = {}
local inLog = {}
local DEFAULT_GROUP_SIZE = 3
local dirty = true
local loggedHeaders = false

local function entries()
    local list = {}
    if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo then
        for i = 1, C_QuestLog.GetNumQuestLogEntries() or 0 do
            local info = C_QuestLog.GetInfo(i)
            if type(info) == "table" and not info.isHidden then
                list[#list + 1] = { title = info.title, isHeader = info.isHeader, questID = info.questID,
                    suggestedGroup = info.suggestedGroup }
            end
        end
    elseif GetNumQuestLogEntries and GetQuestLogTitle then
        for i = 1, GetNumQuestLogEntries() or 0 do
            local title, _, _, isHeader, _, _, _, questID = GetQuestLogTitle(i)
            list[#list + 1] = { title = title, isHeader = isHeader, questID = questID }
        end
    end
    return list
end

local function tagOf(questId)
    if not (C_QuestLog and C_QuestLog.GetQuestTagInfo) then
        return nil
    end
    local ok, info = pcall(C_QuestLog.GetQuestTagInfo, questId)
    return ok and type(info) == "table" and info or nil
end

local function questTag(name, fallback)
    local tags = Enum and Enum.QuestTag
    return tags and tags[name] or fallback
end

-- A quest for a group outside dungeons: WoW tags it Group (elite quests in
-- this client) or suggests a group size. Dungeon, raid and PvP quests are
-- left to the other tab or not matched at all.
local function asGroupQuest(entry, zone)
    if not entry.questID or entry.questID == 0 then
        return nil
    end
    local tag = tagOf(entry.questID)
    local tagId = tag and tag.tagID
    if tagId == questTag("Dungeon", 81) or tagId == questTag("Raid", 62) or tagId == questTag("PvP", 41) then
        return nil
    end
    local size = tonumber(entry.suggestedGroup) or 0
    if tagId ~= questTag("Group", 1) and size < 2 then
        return nil
    end
    size = size >= 2 and math.min(size, 5) or DEFAULT_GROUP_SIZE
    return {
        questID = entry.questID, title = entry.title, zone = zone, size = size,
        label = (tag and type(tag.tagName) == "string" and tag.tagName ~= "") and tag.tagName or "Group",
        key = ns.QuestMatch.key(entry.questID, size),
    }
end

local function refresh()
    byDungeon, entriesByDungeon, groupQuests, inLog = {}, {}, {}, {}
    dirty = false
    local current = {}
    local headers = {}
    local zone
    for _, entry in ipairs(entries()) do
        if type(entry.title) == "string" then
            if entry.isHeader then
                current = Dungeons.forArea(entry.title)
                zone = entry.title
                headers[#headers + 1] = entry.title
            else
                if entry.questID then
                    inLog[entry.questID] = true
                end
                local group = #current == 0 and asGroupQuest(entry, zone)
                if group then
                    groupQuests[#groupQuests + 1] = group
                end
                for _, id in ipairs(current) do
                    byDungeon[id] = byDungeon[id] or {}
                    table.insert(byDungeon[id], entry.title)
                    entriesByDungeon[id] = entriesByDungeon[id] or {}
                    table.insert(entriesByDungeon[id], { title = entry.title, questID = entry.questID })
                end
            end
        end
    end
    if not loggedHeaders and #headers > 0 then
        loggedHeaders = true
        Log.debug("quest log headers: %s", table.concat(headers, ", "))
    end
end

-- The titles of the quests for this dungeon, possibly empty.
function Quests.forDungeon(id)
    if dirty then
        refresh()
    end
    return byDungeon[id] or {}
end

-- { { title, questID } } for this dungeon, possibly empty.
function Quests.entriesFor(id)
    if dirty then
        refresh()
    end
    return entriesByDungeon[id] or {}
end

-- { { questID, title, zone, size, label, key } }: the group and elite quests
-- in the quest log, outside dungeons.
function Quests.groupQuests()
    if dirty then
        refresh()
    end
    return groupQuests
end

function Quests.has(questId)
    if dirty then
        refresh()
    end
    return inLog[questId] == true
end

function Quests.titleOf(questId)
    for _, quest in ipairs(Quests.groupQuests()) do
        if tostring(quest.questID) == tostring(questId) then
            return quest.title
        end
    end
    if C_QuestLog and C_QuestLog.GetTitleForQuestID then
        local ok, title = pcall(C_QuestLog.GetTitleForQuestID, tonumber(questId))
        if ok and type(title) == "string" and title ~= "" then
            return title
        end
    end
    return string.format(L["quest %s"], tostring(questId))
end

-- The name of what a group is for: a dungeon, or a quest key ("176-3").
function Quests.nameOf(key)
    local questId = ns.QuestMatch.parse(key)
    if questId then
        return Quests.titleOf(questId)
    end
    local battleground = ns.Battlegrounds.parseKey(key)
    if battleground then
        return ns.Battlegrounds.name(battleground)
    end
    return Dungeons.name(key)
end

function Quests.init()
    ns.on("QUEST_LOG_UPDATE", function()
        dirty = true
    end)
end

ns.Quests = Quests
