local _, ns = ...

local W = ns.WindowParts
local Widgets = ns.Widgets
local Party = ns.Party
local WIDTH = W.WIDTH
local PAD = W.PAD
local ui = W.ui
local L = ns.L

-- The main window: the connection in the title bar, three tabs (Dungeons,
-- Quests, Battlegrounds), and one screen per tab that stays the same while
-- choosing, searching and in a group: the roles, what the queue or group is
-- doing with the group's places, and the list to tick (or, in a group, its
-- actions). Its parts live in wow/ui/window/ (shared, card, setup, compose,
-- levels, quests, battlegrounds, tabs); this file puts them together.
local Window = {}

function Window.selectedBattlegroundIds()
    if not ns.charDb then
        return {}
    end
    return W.tickedBattlegroundIds()
end

function Window.selectedDungeonIds()
    if not ns.charDb then
        return {}
    end
    return W.selectedVisibleIds()
end

-- Sets the frame height from the content and the bottom buttons.
function W.fitHeight(y)
    local hasButtons = ui.join:IsShown() or ui.delist:IsShown() or ui.takeLead:IsShown() or ui.endRun:IsShown()
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

local function dungeonSummary()
    local parts = { Widgets.describeRoles(W.selectedRoles()) }
    if ns.Playstyle.mine() ~= ns.Playstyles.ANY then
        parts[#parts + 1] = ns.Playstyle.word(ns.Playstyle.mine())
    end
    parts[#parts + 1] = W.leadWord("dungeons")
    parts[#parts + 1] = ns.Locale.count(#W.selectedVisibleIds(), "%d dungeon", "%d dungeons")
    return table.concat(parts, "  ·  ")
end

local END_RUN_WIDTH = 110

-- The main button, with End run on its right while a followed run goes on.
local function fitJoin(ending)
    ui.endRun:SetShown(ending)
    ui.join:ClearAllPoints()
    if ending then
        ui.join:SetWidth(W.CONTENT - END_RUN_WIDTH - W.SPACE.s)
        ui.join:SetPoint("BOTTOMLEFT", PAD, 16)
    else
        ui.join:SetWidth(W.CONTENT)
        ui.join:SetPoint("BOTTOM", 0, 16)
    end
end

-- The Dungeons tab from y down; returns the new y. The roles (locked while
-- searching: Stop to change them), the queue's or group's status with its
-- places, the class choices while choosing, the level limit, then the
-- dungeons to tick while choosing, or the group's actions once Forever
-- Groups follows a group.
local function refreshDungeonsTab(y, state)
    local engine = ns.engine
    local entry = engine and engine.myEntry
    local searching = entry ~= nil or ns.Filler.isActive()
    local canLead = state == "solo" or state == "leader"
    local composition = ns.GroupView.composition()
    local full = state ~= "solo" and #composition.members >= 5
    -- In a run Forever Groups follows, an open place calls for a
    -- replacement, not for ticking dungeons.
    local following = ns.GroupView.isActive()
    local listed = canLead and not full and not following and not searching
    local locked = W.locked("dungeons")
    local open = following and state == "leader" and not searching and composition.open or ""
    -- Searching or in a formed group nothing is chosen: the choices make
    -- way and come back with Stop.
    local busy = searching or full or following
    if canLead and not busy then
        W.refreshRoles(locked)
        y = W.layoutChoices(y, true, state == "leader")
    else
        W.hideChoices()
        y = y - 10
    end
    local composing = listed and ns.PartyCompose.isBuilder()
    y = W.layoutStatus(y, "dungeons", state, { places = not (composing and ns.PartyCompose.isOn()),
        roleInfo = state == "leader" and not searching, chooseReplacements = open ~= "",
        rightRoom = state == "leader" and not busy and W.playstyleRoom() or nil })
    if composing then
        y = W.layoutCompose(y)
    else
        W.hideCompose()
    end
    if canLead and not busy then
        y = W.layoutLevels(y, "dungeons", W.selectedVisibleIds())
    else
        W.hideLevels()
    end
    y = W.layoutActions(y)
    if listed then
        y = W.layoutDungeonList(y - 12)
    else
        W.hideDungeonList()
        if searching and canLead then
            W.layoutLookingAfterStatus("dungeons")
        else
            W.hideHeaderLooking()
        end
    end

    local replace = open ~= ""
    fitJoin(following and not searching)
    ui.join:SetText(L[searching and "Stop" or not engine and "Connecting..." or (replace and "Find replacement")
        or (W.leadWord("dungeons") and "Find players" or "Find group")])
    ui.join:SetShown(searching or listed or replace)
    local ready = searching or replace or (W.selectedRoles() ~= nil and #W.selectedVisibleIds() > 0)
    local summary
    if searching and entry then
        local styles = entry.playstyle and entry.playstyle ~= ns.Playstyles.ANY
            and ns.Playstyle.describe({ entry.playstyle, unpack(ns.Playstyles.partners(entry.playstyle)) },
                " " .. L["or"] .. " ")
        summary = W.searchSummary(entry.members[1].roles,
            { styles or nil, ns.Locale.count(#entry.dungeons, "%d dungeon", "%d dungeons") }, entry.joinedAt)
    elseif replace then
        summary = string.format(L["%s  ·  %d open"], Widgets.describeRoles(open), #open)
    elseif listed and ready then
        summary = dungeonSummary()
    end
    ui.joinSummary:SetText(summary or "")
    ui.joinSummary:SetShown(summary ~= nil)
    Widgets.setEnabled(ui.join, engine ~= nil and ready)
    ui.ready:SetText(L["Choose a role and at least one dungeon."])
    ui.ready:SetShown(listed and not searching and not ready and (ui.hint:GetText() or "") == "")
    ui.delist:SetShown(not ui.join:IsShown() and ns.GroupView.isListed()
        and (Party.inGroup() or ns.GroupView.isTracking()) and state ~= "member" and state ~= "raid")
    local leader = not full and ns.TakeLead.leader()
    ui.takeLead:SetShown(leader and true or false)
    if leader then
        local asked = ns.TakeLead.isAsked()
        ui.takeLead:SetText(L[asked and "Asked to lead" or "Make me leader"])
        Widgets.setEnabled(ui.takeLead, not asked)
    end
    return y
end

local function refreshMain()
    if not W.frame or not W.frame:IsShown() then
        return
    end
    W.followGroupTab()
    local state = Party.state()
    local tabs = W.paintTabs(W.TABS_TOP)
    W.fitInset(tabs)
    W.refreshConnection()
    local y = tabs and (W.TABS_TOP - 38) or (W.insetTop() or (W.TABS_TOP - 10))
    local tab = W.currentTab()
    if tab ~= "dungeons" then
        W.hideDungeonList()
        W.hideActions()
        ui.takeLead:Hide()
        ui.fill:Hide()
        ui.delist:Hide()
        fitJoin(false)
    end
    if tab == "quests" then
        W.hideBattlegroundWidgets()
        W.fitHeight(W.refreshQuestsTab(y, state))
        return
    end
    if tab == "battlegrounds" then
        W.hideQuestWidgets()
        W.fitHeight(W.refreshBattlegroundsTab(y, state))
        return
    end
    W.hideQuestWidgets()
    W.hideBattlegroundWidgets()
    ui.fill:Hide()
    W.fitHeight(refreshDungeonsTab(y, state))
end

-- The Who is looking drawer shows what the main window chooses (tab,
-- roles, dungeons), so it follows every change.
function Window.refresh()
    refreshMain()
    ns.QueueWindow.refresh()
end

function Window.onJoinClicked()
    if ns.Demo.isOn() then
        return
    end
    if W.currentTab() == "quests" then
        W.onQuestJoinClicked()
        return
    end
    if W.currentTab() == "battlegrounds" then
        W.onBattlegroundJoinClicked()
        return
    end
    local engine = ns.engine
    if not engine then
        return
    end
    if not engine.myEntry and not ns.Filler.isActive() and ns.GroupView.isActive() then
        ns.Run.findReplacement(true)
        W.setHint("")
        Window.refresh()
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
        W.setHint(L["Choose at least one dungeon."])
        return
    end
    ns.PartyLevels.noteStart("dungeons")
    local ok, joinErr = ns.join(members, ids)
    W.setHint(ok and "" or string.format(L["Could not join: %s"], L[tostring(joinErr)]))
    if ok then
        ns.LfgList.search()
    end
    Window.refresh()
end

-- Must run from a click or typed command: it starts a Group Finder search.
function Window.startFill()
    if ns.Demo.isOn() then
        return
    end
    if not ns.Features.groupFinder() then
        W.setHint(L["WoW's Group Finder is turned off in the settings (/fg settings)."])
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
        W.setHint(L["Your group is already complete."])
        return
    end
    for i, member in ipairs(members) do
        ns.RoleSync.expect(member.name, assignment[i])
    end
    local ids = entry and entry.dungeons or W.selectedVisibleIds()
    if #ids == 0 then
        W.setHint(L["Choose at least one dungeon."])
        return
    end
    if not entry then
        ns.PartyLevels.noteStart("dungeons")
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
    ns.KeySearch.watch(W.frame)
    ns.QueueWindow.attach(W.frame)
    W.buildTabs()
    W.buildStatus()
    W.buildRoles()
    W.buildCompose()
    W.buildLevels()
    W.buildPlaystyle()
    W.buildQuests()
    W.buildBattlegrounds()
    W.buildDungeons()
    ui.hint = Widgets.text(W.frame, "GameFontNormalSmall")
    ui.hint:SetPoint("BOTTOMLEFT", PAD, 54)
    ui.hint:SetWidth(W.CONTENT)
    ui.hint:SetTextColor(1, 0.4, 0.4)
    ui.join = Widgets.button(W.frame, "Find group", W.CONTENT)
    ui.join:SetHeight(30)
    ui.join:SetPoint("BOTTOM", 0, 16)
    ui.joinSummary = Widgets.text(ui.join, "GameFontHighlightSmall", "RIGHT")
    ui.joinSummary:SetPoint("RIGHT", -14, 0)
    ui.joinSummary:SetTextColor(0.85, 0.85, 0.85)
    ui.join:SetScript("OnClick", Window.onJoinClicked)
    Widgets.tooltip(ui.join, "Find group", "Matches you with other Forever Groups players and fills the rest "
        .. "from WoW's Group Finder, whichever is first.")
    ui.endRun = Widgets.button(W.frame, "End run", END_RUN_WIDTH)
    ui.endRun:SetHeight(30)
    ui.endRun:SetPoint("BOTTOMRIGHT", -PAD, 16)
    ui.endRun:SetScript("OnClick", function()
        ns.Run.endFollowing()
        Window.refresh()
    end)
    Widgets.tooltip(ui.endRun, "End run", "Stops following this group: no more replacements, and your choices and "
        .. "tabs come back. You stay in the group.")
    ui.endRun:Hide()
    ui.ready = Widgets.text(W.frame, "GameFontDisableSmall")
    ui.ready:SetPoint("BOTTOMLEFT", PAD, 54)
    ui.ready:SetText(L["Choose a role and at least one dungeon."])
    ui.fill = Widgets.button(W.frame, "Fill from Group Finder", 200)
    ui.fill:SetPoint("BOTTOMRIGHT", -176, 14)
    ui.fill:SetScript("OnClick", Window.startFill)
    Widgets.tooltip(ui.fill, "Fill from Group Finder", "Invites players listed in WoW's Group Finder for the "
        .. "roles your group still needs.")
    ui.delist = Widgets.button(W.frame, "Remove LFG listing", 170)
    ui.delist:SetPoint("BOTTOMLEFT", PAD, 14)
    Widgets.tooltip(ui.delist, "Remove LFG listing", "Removes your own listing from WoW's Group Finder, now "
        .. "that your group is formed.")
    ui.takeLead:ClearAllPoints()
    ui.takeLead:SetPoint("BOTTOMLEFT", PAD, 14)
    ui.delist:SetScript("OnClick", function()
        ns.GroupView.removeListing()
        Window.refresh()
    end)
end

-- Called from clicks and typed commands, so opening may search the Group
-- Finder for what the open tab shows: the ticked dungeons, the zones of the
-- quests or the battlegrounds.
function Window.toggle()
    if not W.frame then
        W.build()
    end
    W.frame:SetShown(not W.frame:IsShown())
    if W.frame:IsShown() then
        ns.QueueWindow.searchIfStale(30, W.currentTab())
        ns.Demo.maybeStart()
    end
end

function Window.show()
    if not W.frame then
        W.build()
    end
    W.frame:Show()
    ns.Demo.maybeStart()
end

-- The window steps aside while a group proposal asks for an answer, and
-- comes back once it is answered (if it was open).
function Window.stepAside()
    if W.frame and W.frame:IsShown() then
        W.frame:Hide()
        W.steppedAside = true
    end
end

function Window.comeBack()
    if W.steppedAside then
        W.steppedAside = nil
        Window.show()
    end
end

function Window.isShown()
    return W.frame ~= nil and W.frame:IsShown()
end

ns.Window = Window
