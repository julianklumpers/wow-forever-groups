local _, ns = ...

local L = ns.L

-- What the main window's parts share: sizes, the widgets made once, and
-- small helpers. The parts (card, setup, quests, tabs) and window.lua add
-- their functions to this table.
local W = {}
ns.WindowParts = W

W.CLASS_REASON = ns.Locale.mark("Your class cannot play this role.")

W.WIDTH = 610
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
W.ROLE_COUNTS = ns.Locale.mark({ T = { "%d tank", "%d tanks" }, H = { "%d healer", "%d healers" },
    D = { "%d DPS", "%d DPS" } })
W.TILE_GAP = 12
W.TILE_WIDTH = math.floor((W.WIDTH - 2 * W.PAD - 2 * W.TILE_GAP) / 3)
W.PARTY_ROW_HEIGHT = 26
W.SLOT_WIDTH, W.SLOT_GAP = ns.Widgets.SLOT_WIDTH, 8
-- The main window's section headers: room under the text for the controls
-- on the header line (playstyle, I'd like to lead, All / None) before the
-- line, and the step from a header to what follows it.
W.HEADER_GAP = 8
W.HEADER_STEP = 31
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

W.ERRORS = ns.Locale.mark({
    ["role composition does not fit a group"] =
        "These roles cannot make one group (1 tank, 1 healer, 3 DPS). Add a role or change one.",
    ["too many members"] = "A party of five is already a full group.",
})

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
    W.ui.hint:SetText(text and L[text] or "")
    if text and text ~= "" and not W.frame:IsShown() then
        ns.Log.info(text)
    end
end

-- The wish to lead, separately per tab: dungeons (charDb.wantsLead), group
-- quests (wantsLeadQuests) and battlegrounds (wantsLeadBattlegrounds).
local LEAD_KEYS = { quests = "wantsLeadQuests", battlegrounds = "wantsLeadBattlegrounds" }

function W.wantsLead(tab)
    return ns.charDb[LEAD_KEYS[tab] or "wantsLead"] == true
end

-- Sets the wish for the tab shown, and that queue's entry with it.
function W.setWantsLead(wants)
    local tab = W.currentTab()
    local value = wants and true or nil
    ns.charDb[LEAD_KEYS[tab] or "wantsLead"] = value
    local engine = (tab == "quests" and ns.questEngine) or (tab == "dungeons" and ns.engine)
        or (tab == "battlegrounds" and ns.bgEngine) or nil
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
end

-- "lead" for the Find group summary when a solo player wants to lead.
function W.leadWord(tab)
    return W.wantsLead(tab or W.currentTab()) and ns.Party.state() == "solo" and L["lead"] or nil
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
    elseif not ns.engine then
        -- Still connecting: what kind of group this is shows once
        -- connected; until then no tabs that may vanish a moment later.
        return W.currentTabChoice()
    end
    return nil
end

-- Waiting in one queue shows only that queue's page, without tabs, until the
-- player follows a link to another queue; in more queues the tabs are back.
-- nil when the tabs are shown.
function W.queueTab()
    local waiting = {
        dungeons = (ns.engine ~= nil and ns.engine.myEntry ~= nil) or ns.Filler.isActive(),
        quests = ns.QuestQueue.isQueued(),
        battlegrounds = ns.BgQueue.isQueued() or ns.BgFinder.isActive(),
    }
    local single, count = nil, 0
    for tab, queued in pairs(waiting) do
        if queued then
            single, count = tab, count + 1
        end
    end
    if count ~= 1 then
        single = nil
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

local LINK_TEXTS = ns.Locale.mark({
    dungeons = "Also find a dungeon group »",
    quests = "Also find a questing group »",
    battlegrounds = "Also find a battleground group »",
})

local function offered(tab)
    if tab == "quests" then
        return #ns.Quests.groupQuests() > 0
    elseif tab == "battlegrounds" then
        return #ns.Battlegrounds.forLevel(UnitLevel("player")) > 0
    end
    return true
end

-- The links under a single queue's page to the other queues' pages.
function W.placeOtherQueueLink(y, state)
    local tab = W.groupTab() == nil and W.queueTab()
    local can = tab and (state == "solo" or state == "leader")
    local x, shown = W.PAD, 0
    for _, other in ipairs({ "dungeons", "quests", "battlegrounds" }) do
        if can and other ~= tab and offered(other) then
            shown = shown + 1
            local link = W.ui.otherQueues[shown]
            link.target = other
            link:SetText(L[LINK_TEXTS[other]])
            local width = math.ceil(link.label:GetStringWidth() or 40) + 2
            link:SetWidth(width)
            W.place(link, x, y)
            link:Show()
            x = x + width + 24
        end
    end
    for i = shown + 1, #W.ui.otherQueues do
        W.ui.otherQueues[i]:Hide()
    end
    return shown > 0 and y - 22 or y
end

-- The gold panel's inner panel (ButtonFrameTemplate's Inset) starts below
-- room for the tabs; without tabs it moves up under the title bar, so the
-- card starts inside it instead of across its top edge.
local INSET_TOP_WITHOUT_TABS = -26
W.TABS_TOP, W.TAB_HEIGHT = -30, 28
-- The inner panel's border, which the card's picture stays inside.
local INSET_BORDER = 3

-- Without tabs: the top of the inner panel's inside, where the card starts;
-- nil without an inner panel.
function W.insetTop()
    if not W.insetTopLeft then
        return nil
    end
    return INSET_TOP_WITHOUT_TABS - INSET_BORDER
end

-- How far the card may reach left and right past its own edges to fill the
-- inner panel (0, 0 without one).
function W.cardBleed()
    local saved = W.insetTopLeft
    if not saved or type(saved[3]) ~= "number" or type(W.insetRight) ~= "number" then
        return 0, 0
    end
    local cardLeft = W.PAD - W.CARD_PADDING
    return math.max(0, cardLeft - saved[3] - INSET_BORDER), math.max(0, cardLeft + W.insetRight - INSET_BORDER)
end

function W.fitInset(tabs)
    local inset = W.frame and W.frame.Inset
    if type(inset) ~= "table" or type(inset.GetNumPoints) ~= "function" then
        return
    end
    if not W.insetTopLeft then
        for i = 1, inset:GetNumPoints() do
            local point, relativeTo, relativePoint, x, y = inset:GetPoint(i)
            if point == "TOPLEFT" then
                W.insetTopLeft = { relativeTo, relativePoint, x, y }
            elseif point == "BOTTOMRIGHT" then
                W.insetRight = x
            end
        end
        if not W.insetTopLeft then
            return
        end
    end
    local saved = W.insetTopLeft
    -- With tabs the panel starts right under their gold base line, which
    -- takes the place of its top border.
    local top = tabs and (W.TABS_TOP - W.TAB_HEIGHT) or INSET_TOP_WITHOUT_TABS
    inset:SetPoint("TOPLEFT", saved[1], saved[2], saved[3], top)
    local slice = inset.NineSlice
    if type(slice) == "table" then
        for _, key in ipairs({ "TopEdge", "TopLeftCorner", "TopRightCorner" }) do
            local piece = slice[key]
            if type(piece) == "table" and type(piece.SetShown) == "function" then
                piece:SetShown(not tabs)
            end
        end
    end
end

-- The inner panel's outer left and right pixel columns.
function W.panelEdges()
    if W.insetTopLeft and type(W.insetTopLeft[3]) == "number" and type(W.insetRight) == "number" then
        return W.insetTopLeft[3], W.WIDTH + W.insetRight - 1
    end
    return W.PAD - 12, W.WIDTH - (W.PAD - 12) - 1
end

function W.currentTabChoice()
    local tab = ns.charDb and ns.charDb.tab
    return (tab == "quests" or tab == "battlegrounds") and tab or "dungeons"
end

function W.currentTab()
    return W.fixedTab() or W.currentTabChoice()
end
