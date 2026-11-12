local _, ns = ...

local W = ns.WindowParts
local Widgets = ns.Widgets
local PAD = W.PAD
local TAB_WIDTH = W.TAB_WIDTH
local ui = W.ui

-- The Dungeons and Quests tabs, with each queue's status dot.

-- What a queue is doing, for its tab: kind and short text, or nil.
function W.queueStatus(engine)
    if not engine or not engine.myEntry then
        return nil
    end
    local proposal = engine.myProposalKey and engine.proposals[engine.myProposalKey]
    if proposal and not proposal.outcome then
        return "found", "!"
    end
    if engine.held then
        return "paused", "paused"
    end
    return "queued", Widgets.formatTime(GetServerTime() - engine.myEntry.joinedAt)
end

-- The tab row's base line runs under every tab but the chosen one, which
-- stays open into the content below.
-- Returns whether the tabs are shown.
function W.paintTabs(y)
    local shown = W.groupTab() == nil
    for _, widget in ipairs({ ui.tabs.dungeons, ui.tabs.quests, ui.tabLines[1], ui.tabLines[2] }) do
        widget:SetShown(shown)
    end
    if not shown then
        return false
    end
    local chosen = ui.tabs[W.currentTab()]
    for _, tab in pairs(ui.tabs) do
        Widgets.paintTab(tab, tab == chosen)
    end
    local kind, text = W.queueStatus(ns.engine)
    if not kind and ns.Filler.isActive() then
        kind, text = "queued", "filling"
    end
    Widgets.setTabStatus(ui.tabs.dungeons, kind, text)
    Widgets.setTabStatus(ui.tabs.quests, W.queueStatus(ns.questEngine))
    W.place(ui.tabs.dungeons, PAD, y)
    W.place(ui.tabs.quests, PAD + TAB_WIDTH, y)
    local left, right = ui.tabLines[1], ui.tabLines[2]
    left:ClearAllPoints()
    left:SetPoint("TOPLEFT", W.frame, "TOPLEFT", PAD - 12, y - 27)
    left:SetPoint("TOPRIGHT", chosen, "BOTTOMLEFT", 0, 1)
    right:ClearAllPoints()
    right:SetPoint("TOPLEFT", chosen, "BOTTOMRIGHT", 0, 1)
    right:SetPoint("TOPRIGHT", W.frame, "TOPRIGHT", -(PAD - 12), y - 27)
    return true
end

-- Under the Dungeons tab: Search | Who is looking.
local SUBTABS = { { key = "find", label = "Search" }, { key = "who", label = "Who is looking" } }
local SUBTAB_WIDTH = 140

function W.dungeonsView()
    return ns.charDb and ns.charDb.dungeonsView == "who" and "who" or "find"
end

function W.buildSubtabs()
    ui.subtabs = {}
    for _, sub in ipairs(SUBTABS) do
        ui.subtabs[sub.key] = Widgets.tab(W.frame, sub.label, SUBTAB_WIDTH, function()
            ns.charDb.dungeonsView = sub.key
            if sub.key == "who" then
                ns.LfgList.searchIfStale(10)
            end
            ns.Window.refresh()
        end)
        ui.subtabs[sub.key]:SetHeight(24)
    end
end

-- Returns the y under the subtabs (shown only on the Dungeons tab).
function W.paintSubtabs(y, shown)
    for i, sub in ipairs(SUBTABS) do
        local tab = ui.subtabs[sub.key]
        tab:SetShown(shown)
        if shown then
            Widgets.paintTab(tab, W.dungeonsView() == sub.key)
            W.place(tab, PAD + (i - 1) * SUBTAB_WIDTH, y)
        end
    end
    return shown and y - 32 or y
end

function W.buildTabs()
    ui.tabs = {}
    for _, tab in ipairs({ { "dungeons", "Dungeons" }, { "quests", "Quests" } }) do
        ui.tabs[tab[1]] = Widgets.tab(W.frame, tab[2], TAB_WIDTH, function()
            ns.charDb.tab = tab[1]
            W.setHint("")
            ns.Window.refresh()
        end)
    end
    ui.tabLines = {}
    for i = 1, 2 do
        local line = W.frame:CreateTexture(nil, "ARTWORK")
        line:SetHeight(1)
        line:SetColorTexture(1, 0.82, 0, 0.6)
        ui.tabLines[i] = line
    end
end
