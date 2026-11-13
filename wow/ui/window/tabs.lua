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

-- The chosen tab shows the art of WoW's Group Finder buttons (290x36), and
-- its picture runs on under it across the content and fades out, as one
-- picture: it spans the tab row's width from the tabs' top down, stretched
-- to a fifth of that in height, and the tab and the content each show their
-- part of it.
local TAB_ART = { dungeons = "groupfinder-button-dungeons", quests = "groupfinder-button-questing",
    battlegrounds = "groupfinder-button-battlegrounds" }
local TAB_ORDER = { "dungeons", "quests", "battlegrounds" }
local TAB_LABELS = ns.Locale.mark({ dungeons = "Dungeons", quests = "Quests", battlegrounds = "Battlegrounds" })

local function tabX(key)
    for i, other in ipairs(TAB_ORDER) do
        if other == key then
            return PAD + (i - 1) * TAB_WIDTH
        end
    end
    return PAD
end
local ART_ASPECT = 5
local ART_MARGIN = 0
-- Dimmed by colour, not by transparency: the tab and the page have
-- different backgrounds, so see-through art would show a seam where they
-- meet. Under the tab the picture stays solid for SOLID_BAND, then fades.
local ART_TINT = 0.8
local SOLID_BAND = 24
local TAB_HEIGHT = W.TAB_HEIGHT

local function paintArt(chosenKey, y)
    local left, last = W.panelEdges()
    local right = last + 1
    local width = right - left
    local height = width / ART_ASPECT
    for key, tab in pairs(ui.tabs) do
        local x = tabX(key)
        local ok = key == chosenKey and Widgets.atlasPart(tab.art, TAB_ART[key], (x + 1 - left) / width,
            (x + TAB_WIDTH - 1 - left) / width, 1 / height, TAB_HEIGHT / height, ART_MARGIN)
        tab.art:SetShown(ok and true or false)
        tab.art:SetVertexColor(ART_TINT, ART_TINT, ART_TINT, 1)
    end
    local solid, fade = ui.tabArtSolid, ui.tabArt
    local top, split = TAB_HEIGHT / height, (TAB_HEIGHT + SOLID_BAND) / height
    local ok = Widgets.atlasPart(solid, TAB_ART[chosenKey], 0, 1, top, split, ART_MARGIN)
        and Widgets.atlasPart(fade, TAB_ART[chosenKey], 0, 1, split, 1, ART_MARGIN)
    solid:SetShown(ok and true or false)
    fade:SetShown(ok and true or false)
    if not ok then
        return
    end
    solid:ClearAllPoints()
    solid:SetPoint("TOPLEFT", W.frame, "TOPLEFT", left, y - TAB_HEIGHT)
    solid:SetSize(width, SOLID_BAND)
    solid:SetVertexColor(ART_TINT, ART_TINT, ART_TINT, 1)
    fade:ClearAllPoints()
    fade:SetPoint("TOPLEFT", solid, "BOTTOMLEFT")
    fade:SetSize(width, height - TAB_HEIGHT - SOLID_BAND)
    if not (type(CreateColor) == "function" and pcall(fade.SetGradient, fade, "VERTICAL",
        CreateColor(ART_TINT, ART_TINT, ART_TINT, 0), CreateColor(ART_TINT, ART_TINT, ART_TINT, 1))) then
        fade:SetAlpha(0.5)
    end
end

-- The chosen tab's sides run into the base line in an outward rounded
-- corner: two pixels each, between the side's end and the line's.
local function placeFlares(chosen)
    local left, right = ui.tabFlares[1], ui.tabFlares[2]
    for _, piece in ipairs({ left[1], left[2], right[1], right[2] }) do
        piece:ClearAllPoints()
    end
    left[1]:SetPoint("TOPRIGHT", chosen, "BOTTOMLEFT", 0, 3)
    left[2]:SetPoint("TOPRIGHT", chosen, "BOTTOMLEFT", -1, 2)
    right[1]:SetPoint("TOPLEFT", chosen, "BOTTOMRIGHT", 0, 3)
    right[2]:SetPoint("TOPLEFT", chosen, "BOTTOMRIGHT", 1, 2)
end

-- The tab row's base line runs under every tab but the chosen one, which
-- stays open into the content below.
-- Returns whether the tabs are shown.
function W.paintTabs(y)
    local shown = W.fixedTab() == nil
    for _, widget in ipairs({ ui.tabLines[1], ui.tabLines[2], ui.tabArt, ui.tabArtSolid }) do
        widget:SetShown(shown)
    end
    for _, tab in pairs(ui.tabs) do
        tab:SetShown(shown)
    end
    for _, flare in ipairs(ui.tabFlares) do
        for _, piece in ipairs(flare) do
            piece:SetShown(shown)
        end
    end
    if not shown then
        return false
    end
    local chosen = ui.tabs[W.currentTab()]
    paintArt(W.currentTab(), y)
    for _, tab in pairs(ui.tabs) do
        Widgets.paintTab(tab, tab == chosen)
    end
    local kind, text = W.queueStatus(ns.engine)
    if not kind and ns.Filler.isActive() then
        kind, text = "queued", "filling"
    end
    Widgets.setTabStatus(ui.tabs.dungeons, kind, text)
    Widgets.setTabStatus(ui.tabs.quests, W.queueStatus(ns.questEngine))
    kind, text = W.queueStatus(ns.bgEngine)
    if not kind and ns.BgFinder.isActive() then
        kind, text = "queued", "finding"
    end
    Widgets.setTabStatus(ui.tabs.battlegrounds, kind, text)
    for key, tab in pairs(ui.tabs) do
        W.place(tab, tabX(key), y)
    end
    local panelLeft, panelRight = W.panelEdges()
    local left, right = ui.tabLines[1], ui.tabLines[2]
    left:ClearAllPoints()
    left:SetPoint("TOPLEFT", W.frame, "TOPLEFT", panelLeft, y - TAB_HEIGHT + 1)
    left:SetPoint("TOPRIGHT", chosen, "BOTTOMLEFT", -2, 1)
    right:ClearAllPoints()
    right:SetPoint("TOPLEFT", chosen, "BOTTOMRIGHT", 2, 1)
    right:SetPoint("TOPRIGHT", W.frame, "TOPLEFT", panelRight + 1, y - TAB_HEIGHT + 1)
    placeFlares(chosen)
    return true
end

function W.buildTabs()
    ui.tabs = {}
    for _, key in ipairs(TAB_ORDER) do
        ui.tabs[key] = Widgets.tab(W.frame, TAB_LABELS[key], TAB_WIDTH, function()
            ns.charDb.tab = key
            W.setHint("")
            if not ns.Input.run() then
                ns.QueueWindow.searchIfStale(10, key)
            end
            ns.Window.refresh()
        end)
    end
    ui.otherQueues = {}
    for i = 1, 2 do
        ui.otherQueues[i] = Widgets.link(W.frame, "", function(self)
            W.browsingOther = true
            ns.charDb.tab = self.target
            W.setHint("")
            if not ns.Input.run() then
                ns.QueueWindow.searchIfStale(10, self.target)
            end
            ns.Window.refresh()
        end)
        ui.otherQueues[i]:Hide()
    end
    local panel = type(W.frame.Inset) == "table" and W.frame.Inset or W.frame
    ui.tabArtSolid = panel:CreateTexture(nil, "BACKGROUND", nil, 2)
    ui.tabArtSolid:Hide()
    ui.tabArt = panel:CreateTexture(nil, "BACKGROUND", nil, 2)
    ui.tabArt:Hide()
    ui.tabLines = {}
    for i = 1, 2 do
        local line = W.frame:CreateTexture(nil, "ARTWORK")
        line:SetHeight(1)
        line:SetColorTexture(1, 0.82, 0, 0.6)
        ui.tabLines[i] = line
    end
    ui.tabFlares = {}
    for i = 1, 2 do
        local flare = {}
        for j = 1, 2 do
            local piece = W.frame:CreateTexture(nil, "ARTWORK")
            piece:SetSize(1, 1)
            piece:SetColorTexture(1, 0.82, 0, 0.6)
            flare[j] = piece
        end
        ui.tabFlares[i] = flare
    end
end
