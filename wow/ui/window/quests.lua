local _, ns = ...

local W = ns.WindowParts
local Widgets = ns.Widgets
local WIDTH = W.WIDTH
local PAD = W.PAD
local CHECK_INSET = W.CHECK_INSET
local ROW_WIDTH = W.ROW_WIDTH
local RANGE_X = W.RANGE_X
local MAX_QUEST_ROWS = W.MAX_QUEST_ROWS
local QUEST_ROW_HEIGHT = W.QUEST_ROW_HEIGHT
local ui = W.ui
local queueRows = W.queueRows
local questRows = W.questRows

-- The Quests tab: group and elite quests to queue for.

function W.questUnticked()
    ns.charDb.questUnticked = ns.charDb.questUnticked or {}
    return ns.charDb.questUnticked
end

-- The quest keys ticked in the Quests tab; every group quest is ticked until
-- the player unticks it.
-- Only the quests the tab has rows for, so nothing is queued that the
-- player cannot see or untick.
function W.tickedQuestKeys()
    local keys = {}
    for i, quest in ipairs(ns.Quests.groupQuests()) do
        if i <= MAX_QUEST_ROWS and not W.questUnticked()[quest.key] then
            keys[#keys + 1] = quest.key
        end
    end
    return keys
end

function W.hideQuestWidgets()
    ui.questHeader:Hide()
    ui.questHeader.line:Hide()
    ui.questEmpty:Hide()
    for _, row in ipairs(questRows) do
        row:Hide()
    end
end

function W.showQuestRow(row, key, quest, y, enabled)
    local _, size = ns.QuestMatch.parse(key)
    row.key = key
    row.label:SetText(quest and quest.title or ns.Quests.nameOf(key))
    row.range:SetText(string.format("%s · group of %d", quest and quest.label or "Group", size or 0))
    row.zone:SetText(quest and quest.zone or "")
    local waiting = ns.QuestQueue.waitingFor(key)
    row.waiting:SetText(waiting > 0 and string.format("%d waiting", waiting) or "")
    row:SetChecked(not W.questUnticked()[key])
    Widgets.setEnabled(row, enabled)
    W.place(row, PAD - CHECK_INSET, y)
    row:Show()
end

-- The Quests tab below the card; returns the new y.
function W.layoutQuests(y, state)
    local entry = ns.QuestQueue.entry()
    W.hideQuestWidgets()
    if entry then
        local count = #entry.dungeons
        ui.questHeader:SetText(string.format("Looking for a questing group  ·  %d quest%s", count,
            count == 1 and "" or "s"))
        W.place(ui.questHeader, PAD, y)
        ui.questHeader:Show()
        ui.questHeader.line:Show()
        y = y - 26
        for i, key in ipairs(entry.dungeons) do
            if questRows[i] then
                W.showQuestRow(questRows[i], key, nil, y, false)
                y = y - QUEST_ROW_HEIGHT
            end
        end
        return y - 6
    end
    if state ~= "solo" and state ~= "leader" then
        ui.questEmpty:SetText("Your party leader looks for questing groups.")
        W.place(ui.questEmpty, PAD, y)
        ui.questEmpty:Show()
        return y - 30
    end
    W.refreshRoles(false)
    y = W.layoutChoices(y, false)
    local quests = ns.Quests.groupQuests()
    ui.questHeader:SetText(string.format("Group and elite quests  ·  %d selected", #W.tickedQuestKeys()))
    W.place(ui.questHeader, PAD, y)
    ui.questHeader:Show()
    ui.questHeader.line:Show()
    y = y - 26
    for i, row in ipairs(questRows) do
        if quests[i] then
            W.showQuestRow(row, quests[i].key, quests[i], y, true)
            y = y - QUEST_ROW_HEIGHT
        else
            row:Hide()
        end
    end
    if #quests == 0 then
        ui.questEmpty:SetText("No group or elite quests in your quest log. Pick one up and it shows here.")
        W.place(ui.questEmpty, PAD, y - 4)
        ui.questEmpty:Show()
        y = y - 26
    end
    return y - 8
end

function W.refreshQuestsTab(y, state)
    W.setSetupShown(false)
    ui.queueHeader:Hide()
    ui.queueHeader.line:Hide()
    for _, row in ipairs(queueRows) do
        row:Hide()
    end
    ui.queueMore:Hide()
    y = W.layoutQuests(y, state)
    local queued = ns.QuestQueue.isQueued()
    local setup = not queued and (state == "solo" or state == "leader")
    local ready = queued or (W.selectedRoles() ~= nil and #W.tickedQuestKeys() > 0)
    ui.join:SetText(queued and "Stop" or "Find questing group")
    ui.join:SetShown(queued or setup)
    ui.joinSummary:SetShown(setup and ready)
    if setup and ready then
        local parts = { Widgets.describeRoles(W.selectedRoles()) }
        local count = #W.tickedQuestKeys()
        parts[#parts + 1] = string.format("%d quest%s", count, count == 1 and "" or "s")
        ui.joinSummary:SetText(table.concat(parts, "  ·  "))
    end
    Widgets.setEnabled(ui.join, ns.questEngine ~= nil and ready)
    ui.ready:SetText("Choose a role and at least one quest.")
    ui.ready:SetShown(setup and not ready and (ui.hint:GetText() or "") == "")
    ui.fill:Hide()
    ui.delist:Hide()
    return y
end

-- "Find group": queue for Forever Groups players and, with the same click,
-- search WoW's Group Finder; filling from it starts by itself when needed.
-- While searching the button stops everything.
function W.onQuestJoinClicked()
    if ns.QuestQueue.isQueued() then
        ns.QuestQueue.leave()
        W.setHint("")
        ns.Window.refresh()
        return
    end
    local roles = W.selectedRoles()
    if not roles then
        W.setHint("Choose a role first.")
        return
    end
    local members, membersErr = ns.QuestQueue.members(roles)
    if not members then
        W.setHint("Could not join: " .. membersErr)
        return
    end
    local ok, err = ns.QuestQueue.join(W.tickedQuestKeys(), members)
    W.setHint(ok and "" or ("Could not join: " .. tostring(err)))
    if ok then
        ns.QuestFinder.searchNow()
    end
    ns.Window.refresh()
end

function W.buildQuests()
    ui.questHeader = Widgets.header(W.frame, "Group and elite quests", PAD)
    ui.questEmpty = Widgets.text(W.frame, "GameFontDisableSmall")
    ui.questEmpty:SetWidth(WIDTH - 2 * PAD)
    for i = 1, MAX_QUEST_ROWS do
        local row = Widgets.check(W.frame, "", function(self)
            W.questUnticked()[self.key] = not self:GetChecked() or nil
            W.setHint("")
            ns.Window.refresh()
        end)
        row.range = Widgets.text(row, "GameFontDisableSmall")
        row.range:SetPoint("LEFT", row, "LEFT", RANGE_X + 40, 0)
        row.zone = Widgets.text(row, "GameFontDisableSmall")
        row.zone:SetPoint("LEFT", row, "LEFT", RANGE_X + 170, 0)
        row.waiting = Widgets.text(row, "GameFontNormalSmall", "RIGHT")
        row.waiting:SetPoint("RIGHT", row, "LEFT", ROW_WIDTH, 0)
        row:SetHitRectInsets(0, -(ROW_WIDTH - 22), 0, 0)
        questRows[i] = row
    end
end
