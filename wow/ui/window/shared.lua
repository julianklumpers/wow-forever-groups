local _, ns = ...

-- What the main window's parts share: sizes, the widgets made once, and
-- small helpers. The parts (card, setup, quests, tabs) and window.lua add
-- their functions to this table.
local W = {}
ns.WindowParts = W

W.CLASS_REASON = "Your class cannot play this role."

W.WIDTH = 580
W.COLUMNS, W.MAX_ROWS = 2, 18
W.PAD = 26
W.CHECK_INSET = 3
W.CARD_PADDING = 12
W.CELL_WIDTH, W.CELL_HEIGHT = (W.WIDTH - 2 * W.PAD) / 2, 22
W.DETAIL_LIMIT, W.DETAIL_HEIGHT = 10, 24
W.ROW_WIDTH = W.WIDTH - 2 * W.PAD + W.CHECK_INSET
W.COUNT_SIZE = 13
W.RANGE_X = 190
W.COUNTS_X = W.ROW_WIDTH - (3 * (W.COUNT_SIZE + 32) - 8)
W.ROLE_WORDS = { T = { "tank", "tanks" }, H = { "healer", "healers" }, D = { "DPS", "DPS" } }
W.TILE_GAP = 12
W.TILE_WIDTH = math.floor((W.WIDTH - 2 * W.PAD - 2 * W.TILE_GAP) / 3)
W.PARTY_ROW_HEIGHT = 26
W.SLOT_WIDTH, W.SLOT_GAP = 100, 8
W.GREEN = { 0.3, 1, 0.3 }
W.GOLD = { 1, 0.82, 0 }
W.CONNECTION_COLORS = {
    connected = { 0.3, 0.9, 0.3 }, connecting = { 1, 0.82, 0 }, paused = { 1, 0.82, 0 },
    sending = { 1, 0.82, 0 }, failed = { 1, 0.3, 0.3 },
}

W.ui = {}
W.roleToggles = {}
W.partyRows = {}
W.dungeonCells = {}
W.queueRows = {}
W.questRows = {}
W.MAX_QUEST_ROWS = 10
W.QUEST_ROW_HEIGHT = 24
W.TAB_WIDTH = 150
W.QUEUE_ROWS, W.QUEUE_ROW_HEIGHT = 8, 22
W.SLOT_ROLES = { "T", "H", "D", "D", "D" }
W.slots = {}
W.showOthers = false

W.ERRORS = {
    ["role composition does not fit a group"] =
        "These roles cannot make one group (1 tank, 1 healer, 3 DPS). Add a role or change one.",
    ["too many members"] = "A party of five is already a full group.",
}

function W.selectedRoles()
    if ns.charDb.lastRole and not ns.charDb.lastRoles then
        ns.charDb.lastRoles = ns.charDb.lastRole
    end
    ns.charDb.lastRole = nil
    return ns.charDb.lastRoles
end

function W.hasRole(roles, role)
    return roles ~= nil and string.find(roles, role, 1, true) ~= nil
end

-- Typed commands (/fg fill) can fail while the window is closed: then the
-- reason goes to chat as well.
function W.setHint(text)
    W.ui.hint:SetText(text or "")
    if text and text ~= "" and not W.frame:IsShown() then
        ns.Log.info(text)
    end
end

-- The wish to lead, separately for dungeons (charDb.wantsLead) and group
-- quests (charDb.wantsLeadQuests); tab: "dungeons" or "quests".
function W.wantsLead(tab)
    if tab == "quests" then
        return ns.charDb.wantsLeadQuests == true
    end
    return ns.charDb.wantsLead == true
end

-- Sets the wish for the tab shown, and that queue's entry with it.
function W.setWantsLead(wants)
    local quests = W.currentTab() == "quests"
    local value = wants and true or nil
    if quests then
        ns.charDb.wantsLeadQuests = value
    else
        ns.charDb.wantsLead = value
    end
    local engine = quests and ns.questEngine or ns.engine
    if engine then
        engine:setLead(value)
    end
    -- Who is looking opens the half that fits the new choice, whatever was
    -- folded by hand before.
    if ns.db.queueFold then
        ns.db.queueFold[value and "lead" or "join"] = nil
    end
    W.setHint("")
    ns.Window.refresh()
    ns.QueueWindow.refresh()
end

-- "lead" for the Find group summary when a solo player wants to lead.
function W.leadWord(tab)
    return W.wantsLead(tab or W.currentTab()) and ns.Party.state() == "solo" and "lead" or nil
end

function W.place(widget, x, y)
    widget:ClearAllPoints()
    widget:SetPoint("TOPLEFT", W.frame, "TOPLEFT", x, y)
end

-- While a group Forever Groups follows is busy, the window shows only that
-- group: no tabs, and the tab that belongs to it. Once its quests are
-- turned in or its run is over the tabs come back. nil otherwise.
function W.groupTab()
    if not IsInGroup() then
        return nil
    elseif ns.QuestGroup.isQuesting() then
        return not ns.QuestGroup.isDone() and "quests" or nil
    elseif ns.GroupView.isActive() then
        return "dungeons"
    end
    return nil
end

-- Waiting in one queue shows only that queue's page, without tabs, until the
-- player follows the link to the other queue; in both queues the tabs are
-- back. nil when the tabs are shown.
function W.queueTab()
    local dungeons = (ns.engine ~= nil and ns.engine.myEntry ~= nil) or ns.Filler.isActive()
    local quests = ns.QuestQueue.isQueued()
    local single
    if dungeons and not quests then
        single = "dungeons"
    elseif quests and not dungeons then
        single = "quests"
    end
    if single ~= W.lastQueueTab then
        W.lastQueueTab = single
        W.browsingOther = false
    end
    if W.browsingOther then
        return nil
    end
    return single
end

function W.fixedTab()
    return W.groupTab() or W.queueTab()
end

-- The link under a single queue's page to the other queue's page.
function W.placeOtherQueueLink(y, state)
    local link = W.ui.otherQueue
    local tab = W.groupTab() == nil and W.queueTab()
    local other = tab == "dungeons" and "quests" or "dungeons"
    local can = tab and (state == "solo" or state == "leader")
        and (other == "dungeons" or #ns.Quests.groupQuests() > 0)
    link:SetShown(can and true or false)
    if not can then
        return y
    end
    link.target = other
    link:SetText(other == "quests" and "Also find a questing group »" or "Also find a dungeon group »")
    link:SetWidth(math.ceil(link.label:GetStringWidth() or 40) + 2)
    W.place(link, W.PAD, y)
    return y - 22
end

function W.currentTab()
    local fixed = W.fixedTab()
    if fixed then
        return fixed
    end
    return ns.charDb and ns.charDb.tab == "quests" and "quests" or "dungeons"
end
