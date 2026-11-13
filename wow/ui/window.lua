local _, ns = ...

local W = ns.WindowParts
local Widgets = ns.Widgets
local Party = ns.Party
local WIDTH = W.WIDTH
local PAD = W.PAD
local CHECK_INSET = W.CHECK_INSET
local CARD_PADDING = W.CARD_PADDING
local ROW_WIDTH = W.ROW_WIDTH
local COUNT_SIZE = W.COUNT_SIZE
local RANGE_X = W.RANGE_X
local COUNTS_X = W.COUNTS_X
local QUEUE_ROWS = W.QUEUE_ROWS
local QUEUE_ROW_HEIGHT = W.QUEUE_ROW_HEIGHT
local ui = W.ui
local roleToggles = W.roleToggles
local queueRows = W.queueRows

-- The main window: the connection and two tabs (Dungeons, Quests) on top, a
-- status card per tab, and below it only what fits the moment: choosing
-- roles and dungeons, a queue summary, or nothing extra once the group is
-- complete. Its parts live in wow/ui/window/ (shared, card, setup, quests,
-- tabs); this file puts them together.
local Window = {}

function Window.selectedDungeonIds()
    if not ns.charDb then
        return {}
    end
    return W.selectedVisibleIds()
end

-- Sets the frame height from the content and the bottom buttons.
function W.fitHeight(y)
    local hasButtons = ui.join:IsShown() or ui.delist:IsShown()
    local hasHint = (ui.hint:GetText() or "") ~= ""
    ui.hint:ClearAllPoints()
    ui.hint:SetPoint("BOTTOMLEFT", PAD, hasButtons and 54 or 12)
    local hasNote = hasHint or ui.ready:IsShown()
    local height
    if hasButtons then
        height = -y + (hasNote and 72 or 52)
    else
        height = -y + (hasHint and 36 or 14)
    end
    W.frame:SetHeight(height)
    local screen = UIParent:GetHeight()
    if type(screen) == "number" and screen > 0 then
        W.frame:SetScale(math.min(1, (screen - 140) / height))
    end
end

local function refreshMain()
    if not W.frame or not W.frame:IsShown() then
        return
    end
    local engine = ns.engine
    local entry = engine and engine.myEntry
    local queued = entry ~= nil
    local state = Party.state()
    local canLead = state == "solo" or state == "leader"
    local full = state ~= "solo" and ns.GroupView.partySize() >= 5
    local setup = canLead and not queued and not full and not ns.Filler.isActive()

    local y = -30
    local tabs = W.paintTabs(y)
    W.fitInset(tabs)
    if tabs then
        y = y - 38
    else
        y = W.insetTop() or (y - 10)
    end
    local cardBottom
    local function placeCard(top)
        W.place(ui.card, PAD - CARD_PADDING, top)
        cardBottom = top - W.refreshCard(state, full, W.currentTab())
        return cardBottom - 12
    end
    -- Alone and choosing, the roles come first and the card (then only
    -- "Looking now") follows them; otherwise the card leads.
    local questsQueued = ns.QuestQueue.isQueued()
    local choosing = state == "solo" and not ns.Filler.isActive()
        and (W.currentTab() == "quests" and not questsQueued or W.currentTab() ~= "quests" and not queued)
    if choosing then
        W.cardBelowRoles = placeCard
        y = y - 10
    else
        W.cardBelowRoles = nil
        y = placeCard(y)
    end

    if W.currentTab() == "quests" then
        W.fitHeight(W.refreshQuestsTab(y, state))
        return
    end
    W.hideQuestWidgets()
    ui.ready:SetText("Choose a role and at least one dungeon.")
    W.setSetupShown(setup)
    ui.queueHeader:SetShown(queued)
    ui.queueHeader.line:SetShown(queued)
    if not queued then
        for _, row in ipairs(queueRows) do
            row:Hide()
        end
        ui.queueMore:Hide()
    end
    if setup then
        W.refreshRoles(queued)
        local members = state == "leader" and Party.members() or nil
        local partyRowCount = W.refreshParty(members)
        ui.partyHeader:SetShown(partyRowCount > 0)
        if ui.partyHeader.line then
            ui.partyHeader.line:SetShown(partyRowCount > 0)
        end
        local levelCount, otherCount = W.refreshDungeons()
        y = W.layoutSetup(y, partyRowCount, levelCount, otherCount)
    elseif queued then
        y = W.layoutQueued(y, entry)
    end
    y = W.placeOtherQueueLink(y, state)

    local searching = queued or ns.Filler.isActive()
    ui.join:SetText(searching and "Stop" or not engine and "Connecting..."
        or (W.leadWord("dungeons") and "Find players" or "Find group"))
    ui.join:SetShown(searching or setup)
    local ready = searching or (W.selectedRoles() ~= nil and #W.selectedVisibleIds() > 0)
    ui.joinSummary:SetShown(setup and not searching and ready)
    if setup and ready then
        local dungeonCount = #W.selectedVisibleIds()
        local parts = { Widgets.describeRoles(W.selectedRoles()) }
        if ns.Playstyle.mine() ~= ns.Playstyles.ANY then
            parts[#parts + 1] = ns.Playstyle.word(ns.Playstyle.mine())
        end
        parts[#parts + 1] = W.leadWord("dungeons")
        parts[#parts + 1] = string.format("%d dungeon%s", dungeonCount, dungeonCount == 1 and "" or "s")
        ui.joinSummary:SetText(table.concat(parts, "  ·  "))
    end
    Widgets.setEnabled(ui.join, engine ~= nil and ready)
    ui.ready:SetShown(setup and not ready and (ui.hint:GetText() or "") == "")
    ui.fill:Hide()
    ui.delist:SetShown(not ui.join:IsShown() and ns.GroupView.isListed()
        and (IsInGroup() or ns.GroupView.isTracking()) and state ~= "member" and state ~= "raid")
    if not setup and not queued and not ui.join:IsShown() and not ui.delist:IsShown() then
        y = cardBottom - 2
    end
    W.fitHeight(y)
end

-- The Who is looking drawer shows what the main window chooses (tab,
-- roles, dungeons), so it follows every change.
function Window.refresh()
    refreshMain()
    ns.QueueWindow.refresh()
end

function Window.onJoinClicked()
    if W.currentTab() == "quests" then
        W.onQuestJoinClicked()
        return
    end
    local engine = ns.engine
    if not engine then
        return
    end
    if engine.myEntry or ns.Filler.isActive() then
        if engine.myEntry then
            engine:leave()
        end
        ns.Filler.stop()
        ns.Apply.stopSeeking()
        ns.Listing.tick()
        ns.Input.run()
        W.setHint("")
        Window.refresh()
        return
    end
    local members, err = W.collectMembers()
    if not members then
        W.setHint(err)
        return
    end
    local ids = W.selectedVisibleIds()
    if #ids == 0 then
        W.setHint("Choose at least one dungeon.")
        return
    end
    local ok, joinErr = ns.join(members, ids)
    W.setHint(ok and "" or ("Could not join: " .. tostring(joinErr)))
    if ok then
        ns.LfgList.search()
    end
    Window.refresh()
end

-- Must run from a click or typed command: it starts a Group Finder search.
function Window.startFill()
    if not ns.Features.groupFinder() then
        W.setHint("WoW's Group Finder is turned off in the settings (/fg settings).")
        return
    end
    if ns.Filler.isActive() then
        ns.Filler.searchAgain()
        return
    end
    if not W.frame then
        W.build()
    end
    local entry = ns.engine and ns.engine.myEntry
    local members, err
    if entry then
        members = entry.members
    else
        members, err = W.collectMembers()
    end
    if not members then
        W.setHint(err)
        return
    end
    local missing, assignment = ns.Filler.missingFor(members)
    if not missing or missing == "" then
        W.setHint("Your group is already complete.")
        return
    end
    for i, member in ipairs(members) do
        ns.RoleSync.expect(member.name, assignment[i])
    end
    local ids = entry and entry.dungeons or W.selectedVisibleIds()
    if #ids == 0 then
        W.setHint("Choose at least one dungeon.")
        return
    end
    local names = {}
    for _, member in ipairs(members) do
        names[#names + 1] = member.name
    end
    W.setHint("")
    ns.LfgList.search()
    ns.Filler.start({ dungeons = ids, missing = missing, members = names })
    Window.refresh()
end

function W.build()
    W.frame = Widgets.window("ForeverGroupsFrame", "Forever Groups", WIDTH, 400, nil, false,
        Widgets.ICON)
    W.frame:SetScript("OnShow", Window.refresh)
    ns.QueueWindow.attach(W.frame)
    W.buildTabs()
    W.buildCard()
    W.buildRoles()
    W.buildPlaystyle()
    W.buildQuests()
    W.buildParty()
    W.buildDungeons()
    ui.setupWidgets = { ui.rolesHeader, ui.dungeonHeader, ui.otherToggle }
    for _, role in ipairs(Widgets.ROLES) do
        ui.setupWidgets[#ui.setupWidgets + 1] = roleToggles[role]
    end
    ui.queueHeader = Widgets.header(W.frame, "Searching", PAD)
    for i = 1, QUEUE_ROWS do
        local row = CreateFrame("Frame", nil, W.frame)
        row:SetSize(ROW_WIDTH, QUEUE_ROW_HEIGHT)
        row.name = Widgets.text(row, "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", CHECK_INSET, 0)
        row.range = Widgets.text(row, "GameFontDisableSmall")
        row.range:SetPoint("LEFT", RANGE_X, 0)
        row.counts = Widgets.roleCounts(row, COUNT_SIZE)
        row.counts:SetPoint("LEFT", COUNTS_X, 0)
        row.groups = Widgets.text(row, "GameFontNormalSmall", "RIGHT")
        row.groups:SetPoint("RIGHT", row.counts, "LEFT", -14, 0)
        queueRows[i] = row
    end
    ui.queueMore = Widgets.text(W.frame, "GameFontDisableSmall")
    ui.queueMore:SetWidth(WIDTH - 2 * PAD)
    ui.hint = Widgets.text(W.frame, "GameFontNormalSmall")
    ui.hint:SetPoint("BOTTOMLEFT", PAD, 54)
    ui.hint:SetWidth(WIDTH - 2 * PAD)
    ui.hint:SetTextColor(1, 0.4, 0.4)
    ui.join = Widgets.button(W.frame, "Find group", WIDTH - 2 * PAD)
    ui.join:SetHeight(30)
    ui.join:SetPoint("BOTTOM", 0, 16)
    ui.joinSummary = Widgets.text(ui.join, "GameFontHighlightSmall", "RIGHT")
    ui.joinSummary:SetPoint("RIGHT", -14, 0)
    ui.joinSummary:SetTextColor(0.85, 0.85, 0.85)
    ui.join:SetScript("OnClick", Window.onJoinClicked)
    Widgets.tooltip(ui.join, "Find group", "Matches you with other Forever Groups players and fills the rest "
        .. "from WoW's Group Finder, whichever is first.")
    ui.ready = Widgets.text(W.frame, "GameFontDisableSmall")
    ui.ready:SetPoint("BOTTOMLEFT", PAD, 54)
    ui.ready:SetText("Choose a role and at least one dungeon.")
    ui.fill = Widgets.button(W.frame, "Fill from Group Finder", 200)
    ui.fill:SetPoint("BOTTOMRIGHT", -176, 14)
    ui.fill:SetScript("OnClick", Window.startFill)
    Widgets.tooltip(ui.fill, "Fill from Group Finder", "Invites players listed in WoW's Group Finder for the "
        .. "roles your group still needs.")
    ui.delist = Widgets.button(W.frame, "Remove LFG listing", 170)
    ui.delist:SetPoint("BOTTOMLEFT", PAD, 14)
    Widgets.tooltip(ui.delist, "Remove LFG listing", "Removes your own listing from WoW's Group Finder, now "
        .. "that your group is formed.")
    ui.delist:SetScript("OnClick", function()
        ns.GroupView.removeListing()
        Window.refresh()
    end)
end

-- Called from clicks and typed commands, so opening may search the Group
-- Finder for the ticked dungeons.
function Window.toggle()
    if not W.frame then
        W.build()
    end
    W.frame:SetShown(not W.frame:IsShown())
    if W.frame:IsShown() then
        ns.LfgList.searchIfStale(30)
    end
end

function Window.show()
    if not W.frame then
        W.build()
    end
    W.frame:Show()
end

function Window.isShown()
    return W.frame ~= nil and W.frame:IsShown()
end

ns.Window = Window
