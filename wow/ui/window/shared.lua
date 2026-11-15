local _, ns = ...

local L = ns.L
local Widgets = ns.Widgets

-- What the main window's parts share: sizes, the widgets made once, and
-- small helpers. The parts (card, setup, compose, levels, quests,
-- battlegrounds, tabs) and window.lua add their functions to this table.
local W = {}
ns.WindowParts = W

W.CLASS_REASON = ns.Locale.mark("Your class cannot play this role.")

W.WIDTH = 610
W.COLUMNS, W.MAX_ROWS = 2, 18

-- The window's small design system: every gap is a step of SPACE, and the
-- content sits in one box with the same margin to the inside of the gold
-- frame on both sides, which is what the eye measures against. The frame's
-- border is not as wide on both sides (about 8 on the left, 6 on the right,
-- measured in game). PAD is the box's left edge, RIGHT its
-- right edge, CONTENT its width; rows of tiles or cards are cut with
-- W.columns so they fill the box to the pixel.
W.SPACE = { xs = 4, s = 6, m = 8, l = 12, xl = 16, xxl = 24 }
W.BORDER_LEFT, W.BORDER_RIGHT = 8, 6
W.MARGIN = 18
W.PAD = W.BORDER_LEFT + W.MARGIN
W.RIGHT = W.WIDTH - W.BORDER_RIGHT - W.MARGIN
W.CONTENT = W.RIGHT - W.PAD
-- How far a right-aligned widget's TOPRIGHT anchor sits from the frame's.
W.RIGHT_OFFSET = W.RIGHT - W.WIDTH

-- count columns over width (the content box by default) with gap between
-- them: { { x, width } } from the left edge `left` (PAD), the pixels left
-- over from dividing going one each to the first columns, so the row ends
-- exactly at the right edge.
function W.columns(count, gap, width, left)
    width, left = width or W.CONTENT, left or W.PAD
    local base = math.floor((width - (count - 1) * gap) / count)
    local extra = width - (count - 1) * gap - base * count
    local list, x = {}, left
    for i = 1, count do
        local w = base + (i <= extra and 1 or 0)
        list[i] = { x = x, width = w }
        x = x + w + gap
    end
    return list
end
W.CHECK_INSET = 3
W.CELL_WIDTH, W.CELL_HEIGHT = W.CONTENT / 2, 22
W.DETAIL_LIMIT, W.DETAIL_HEIGHT = 10, 24
W.ROW_WIDTH = W.CONTENT + W.CHECK_INSET
W.COUNT_SIZE = 13
W.RANGE_X = 190
W.COUNTS_X = W.ROW_WIDTH - (3 * (W.COUNT_SIZE + 32) - 8)
W.ROLE_COUNTS = ns.Locale.mark({ T = { "%d tank", "%d tanks" }, H = { "%d healer", "%d healers" },
    D = { "%d DPS", "%d DPS" } })
W.TILE_GAP = W.SPACE.s
W.TILE_WIDTH = math.floor((W.CONTENT - 2 * W.TILE_GAP) / 3)
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
W.dungeonCells = {}
W.questRows = {}
W.MAX_QUEST_ROWS = 10
W.QUEST_ROW_HEIGHT = 24
W.TAB_WIDTH = 150
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

-- The roles the tiles show on a tab: those its queue entry searches with,
-- else the ones last chosen.
function W.shownRoles(tab)
    local entry
    if tab == "quests" then
        entry = ns.QuestQueue.entry()
    elseif tab == "battlegrounds" then
        entry = ns.BgQueue.entry()
    else
        entry = ns.engine and ns.engine.myEntry
    end
    return entry and entry.members[1].roles or W.selectedRoles()
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
    if tab == "dungeons" then
        ns.PartyCompose.apply()
    end
    ns.PartyLevels.apply()
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

-- The tab of a group Forever Groups follows while it is busy: dungeons for
-- a run, quests for a questing group; nil otherwise.
local function groupTab()
    if not ns.Party.inGroup() then
        return nil
    elseif ns.QuestGroup.isQuesting() then
        return not ns.QuestGroup.isDone() and "quests" or nil
    elseif ns.GroupView.isActive() then
        return "dungeons"
    end
    return nil
end

W.groupTab = groupTab

-- When such a group starts, the window turns to its tab once; the tabs make
-- way while it lasts, as a group leaves the other queues.
function W.followGroupTab()
    local tab = groupTab()
    if tab ~= W.lastGroupTab then
        W.lastGroupTab = tab
        if tab and ns.charDb then
            ns.charDb.tab = tab
        end
    end
end

-- Whether the tab's queue is searching: its queue entry, or WoW's Group
-- Finder filling or building the group.
function W.searching(tab)
    if tab == "quests" then
        return ns.QuestQueue.isQueued()
    elseif tab == "battlegrounds" then
        return ns.BgQueue.isQueued() or ns.BgFinder.isActive()
    end
    return (ns.engine ~= nil and ns.engine.myEntry ~= nil) or ns.Filler.isActive()
end

-- The choices can't be changed while the tab's queue searches (Stop first)
-- or a group proposal waits for an answer; they show what is searched for.
function W.locked(tab)
    local engine = (tab == "quests" and ns.questEngine) or (tab == "battlegrounds" and ns.bgEngine) or ns.engine
    return W.searching(tab) or (engine ~= nil and ns.Queues.proposalOpen(engine))
end

-- What the Stop button sums up on its right: the roles, texts (nil ones
-- left out) and the time in the queue.
function W.searchSummary(roles, texts, joinedAt)
    local parts = {}
    if roles then
        parts[#parts + 1] = Widgets.describeRoles(roles)
    end
    for i = 1, table.maxn(texts) do
        if texts[i] then
            parts[#parts + 1] = texts[i]
        end
    end
    if joinedAt then
        parts[#parts + 1] = Widgets.formatTime(GetServerTime() - joinedAt)
    end
    return table.concat(parts, "  ·  ")
end

-- The gold panel's inner panel (ButtonFrameTemplate's Inset) starts right
-- under the tabs' gold base line, which takes the place of its top border.
-- The gold panel's inner panel (ButtonFrameTemplate's Inset) starts below
-- room for the tabs; without tabs it moves up under the title bar.
local INSET_TOP_WITHOUT_TABS = -26
W.TABS_TOP, W.TAB_HEIGHT = -30, 28
-- The inner panel's border.
local INSET_BORDER = 3

-- Without tabs: the top of the inner panel's inside, where the content
-- starts; nil without an inner panel.
function W.insetTop()
    if not W.insetTopLeft then
        return nil
    end
    return INSET_TOP_WITHOUT_TABS - INSET_BORDER
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
    inset:SetPoint("TOPLEFT", saved[1], saved[2], saved[3], tabs and (W.TABS_TOP - W.TAB_HEIGHT)
        or INSET_TOP_WITHOUT_TABS)
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

function W.currentTab()
    local tab = ns.charDb and ns.charDb.tab
    return (tab == "quests" or tab == "battlegrounds") and tab or "dungeons"
end
