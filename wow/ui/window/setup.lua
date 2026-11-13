local _, ns = ...

local L = ns.L

local W = ns.WindowParts
local Widgets = ns.Widgets
local Dungeons = ns.Dungeons
local Party = ns.Party
local Protocol = ns.Protocol
local Classes = ns.Classes
local CLASS_REASON = W.CLASS_REASON
local WIDTH = W.WIDTH
local COLUMNS = W.COLUMNS
local MAX_ROWS = W.MAX_ROWS
local PAD = W.PAD
local CHECK_INSET = W.CHECK_INSET
local CELL_WIDTH = W.CELL_WIDTH
local CELL_HEIGHT = W.CELL_HEIGHT
local DETAIL_LIMIT = W.DETAIL_LIMIT
local DETAIL_HEIGHT = W.DETAIL_HEIGHT
local ROW_WIDTH = W.ROW_WIDTH
local COUNT_SIZE = W.COUNT_SIZE
local RANGE_X = W.RANGE_X
local COUNTS_X = W.COUNTS_X
local ROLE_COUNTS = W.ROLE_COUNTS
local GOLD, GREEN = { 1, 0.82, 0 }, { 0.4, 1, 0.4 }
local TILE_GAP = W.TILE_GAP
local TILE_WIDTH = W.TILE_WIDTH
local PARTY_ROW_HEIGHT = W.PARTY_ROW_HEIGHT
local QUEUE_ROWS = W.QUEUE_ROWS
local QUEUE_ROW_HEIGHT = W.QUEUE_ROW_HEIGHT
local ERRORS = W.ERRORS
local LEAD_BOX = 20
local BOX_HEIGHT, BOX_PAD, ARROW_SIZE = 22, 8, 15
local ui = W.ui
local roleToggles = W.roleToggles
local partyRows = W.partyRows
local dungeonCells = W.dungeonCells
local queueRows = W.queueRows

-- Choosing roles, playstyle, party roles and dungeons, and the queued
-- dungeons summary.

function W.selectedDungeons()
    if not ns.charDb.lastDungeons then
        ns.charDb.lastDungeons = {}
        for _, dungeon in ipairs(Dungeons.forLevel(UnitLevel("player"))) do
            ns.charDb.lastDungeons[dungeon.id] = true
        end
    end
    return ns.charDb.lastDungeons
end

-- Two lists: the dungeons for the player's level, and the others below the
-- "Other dungeons" toggle: all of them when it is open, else only the ticked
-- ones, so a choice made there stays in sight. Also how many others exist.
function W.dungeonSections()
    local forLevel, selected = {}, W.selectedDungeons()
    for _, dungeon in ipairs(Dungeons.forLevel(UnitLevel("player"))) do
        forLevel[dungeon.id] = true
    end
    local levelList, otherList, others = {}, {}, 0
    for _, dungeon in ipairs(Dungeons.list) do
        if forLevel[dungeon.id] then
            levelList[#levelList + 1] = dungeon
        else
            others = others + 1
            if W.showOthers or selected[dungeon.id] then
                otherList[#otherList + 1] = dungeon
            end
        end
    end
    return levelList, otherList, others
end

function W.visibleDungeons()
    local levelList, otherList = W.dungeonSections()
    local list = {}
    for _, dungeon in ipairs(levelList) do
        list[#list + 1] = dungeon
    end
    for _, dungeon in ipairs(otherList) do
        list[#list + 1] = dungeon
    end
    return list
end

function W.selectedVisibleIds()
    local ids, selected = {}, W.selectedDungeons()
    for _, dungeon in ipairs(W.visibleDungeons()) do
        if selected[dungeon.id] then
            ids[#ids + 1] = dungeon.id
        end
    end
    return ids
end

function W.refreshRoles(queued)
    local myClass = Party.playerClass()
    ns.charDb.lastRoles = Classes.filter(W.selectedRoles(), myClass)
    local current = ns.Spec.current()
    for role, tile in pairs(roleToggles) do
        local allowed = Classes.canPlay(myClass, role)
        tile.reason = not allowed and CLASS_REASON or nil
        Widgets.setTileLook(tile, allowed and ns.Specs.forRole(myClass, role, current and current.index) or nil)
        Widgets.paintTile(tile, W.hasRole(W.selectedRoles(), role), not queued and allowed)
    end
end

-- The role with the fewest players looking per place in a group, among
-- the roles the player's class can play, for the ticked dungeons; nil on a
-- tie or with nobody looking. Also returns a tooltip line.
function W.neededRole()
    if not ns.Features.countsKnown() then
        return nil
    end
    local counts = ns.QueueWindow.lookingCounts(ns.QueueWindow.wantedDungeons())
    if counts.T + counts.H + counts.D == 0 then
        return nil
    end
    local myClass = Party.playerClass()
    local best, bestRatio, tie
    for _, role in ipairs(Widgets.ROLES) do
        if Classes.canPlay(myClass, role) then
            local ratio = counts[role] / ns.Config.SLOTS[role]
            if not best or ratio < bestRatio then
                best, bestRatio, tie = role, ratio, false
            elseif ratio == bestRatio then
                tie = true
            end
        end
    end
    if not best or tie then
        return nil
    end
    local parts = {}
    for _, role in ipairs(Widgets.ROLES) do
        local words = ROLE_COUNTS[role]
        parts[#parts + 1] = ns.Locale.count(counts[role], words[1], words[2])
    end
    return best, string.format(L["Needed most right now: %s looking for your dungeons."], table.concat(parts, ", "))
end

function W.refreshParty(members)
    local shown = 0
    for i, row in ipairs(partyRows) do
        local member = members and members[i] or nil
        row.member = member
        if member then
            local roles = ns.PartyRoles.rolesOf(member)
            row.name:SetText(member.name)
            row.name:SetTextColor(Widgets.classColor(member.classToken))
            local x = 0
            for _, role in ipairs(Widgets.ROLES) do
                local icon = row.icons[role]
                if string.find(roles, role, 1, true) then
                    icon:ClearAllPoints()
                    icon:SetPoint("LEFT", row, "LEFT", 200 + x, 0)
                    icon:Show()
                    x = x + 22
                else
                    icon:Hide()
                end
            end
            row.roles:ClearAllPoints()
            row.roles:SetPoint("LEFT", row, "LEFT", 206 + x, 0)
            row.roles:SetText(Widgets.describeRoles(roles) .. "  (" .. L[ns.PartyRoles.sourceOf(member)] .. ")")
            row:Show()
            shown = shown + 1
        else
            row:Hide()
        end
    end
    return shown
end

-- Up to DETAIL_LIMIT dungeons get one row each, with how many players look
-- for it; a longer list (all other dungeons) is two plain columns.
function W.isDetailed(count)
    return count <= DETAIL_LIMIT
end

-- Fills the cells, level dungeons first; returns how many of each list.
function W.refreshDungeons()
    local levelList, otherList, others = W.dungeonSections()
    local list = W.visibleDungeons()
    local selected = W.selectedDungeons()
    local count = 0
    for _, dungeon in ipairs(list) do
        if selected[dungeon.id] then
            count = count + 1
        end
    end
    ui.dungeonHeader:SetText(string.format(L["Dungeons for level %d  ·  %d selected"], UnitLevel("player"), count))
    Widgets.paintExpander(ui.otherToggle, W.showOthers, string.format("(%d)", others))
    ui.otherToggle:SetShown(others > 0)
    for i, cell in ipairs(dungeonCells) do
        local dungeon = list[i]
        local detailed = W.isDetailed(i <= #levelList and #levelList or #otherList)
        cell.dungeon = dungeon
        if dungeon then
            cell.label:SetText(Dungeons.name(dungeon.id))
            cell.label:SetTextColor(Widgets.levelColor(UnitLevel("player"), dungeon.min, dungeon.max))
            cell.range:SetText(Dungeons.rangeText(dungeon))
            cell.range:ClearAllPoints()
            cell.hover:ClearAllPoints()
            cell.hover:SetPoint("TOPLEFT", cell, "TOPLEFT", 0, 1)
            if detailed then
                cell.range:SetPoint("LEFT", cell, "LEFT", RANGE_X, 0)
                cell:SetHitRectInsets(0, -(ROW_WIDTH - 22), 0, 0)
                cell.hover:SetPoint("BOTTOMRIGHT", cell, "BOTTOMLEFT", ROW_WIDTH, -1)
                local known = ns.Features.countsKnown()
                Widgets.setRoleCounts(cell.counts, known and ns.QueueWindow.lookingCounts({ [dungeon.id] = true }))
            else
                cell.range:SetPoint("LEFT", cell.label, "RIGHT", 6, 0)
                Widgets.fitClickArea(cell, cell.range)
                cell.hover:SetPoint("BOTTOMRIGHT", cell, "BOTTOMLEFT", CELL_WIDTH - 8, -1)
            end
            cell.counts:SetShown(detailed)
            cell.groups:SetShown(detailed)
            local quests = #ns.Quests.forDungeon(dungeon.id)
            cell.quests:SetShown(detailed and quests > 0)
            cell.quests:SetText(ns.Locale.count(quests, "%d quest", "%d quests"))
            if detailed then
                W.paintDemand(cell.groups, dungeon.id)
            end
            cell.chosen:SetShown(selected[dungeon.id] == true)
            cell:SetChecked(selected[dungeon.id] == true)
            cell:Show()
        else
            cell:Hide()
        end
    end
    ui.empty:SetShown(#levelList == 0)
    return #levelList, #otherList
end

function W.setSetupShown(shown)
    for _, widget in ipairs(ui.setupWidgets) do
        widget:SetShown(shown)
        if widget.line then
            widget.line:SetShown(shown)
        end
    end
    ui.dungeonLinks:SetShown(shown)
    if not shown then
        ui.roleHint:Hide()
        ui.leadCheck:Hide()
        ui.playstyleButton:Hide()
        ui.playstyleLabel:Hide()
        W.hidePlaystyleMenu()
    end
    if not shown then
        ui.partyHeader:Hide()
        if ui.partyHeader.line then
            ui.partyHeader.line:Hide()
        end
        for _, row in ipairs(partyRows) do
            row:Hide()
        end
        for _, cell in ipairs(dungeonCells) do
            cell:Hide()
        end
        ui.empty:Hide()
    end
end

-- Places the role, party and dungeon choices from y downwards; returns the
-- new y.
-- "5 groups" after a dungeon's counts: listed groups that need one of the
-- player's roles; empty when none.
-- How much the player's roles are wanted for a dungeon right now: listed
-- groups that need them, and one of their roles too few others looking can
-- play; "quiet" when neither and nobody looks. Returns the text, its color, a
-- tooltip line, or nil.
function W.demand(dungeonId)
    local wanted = { [dungeonId] = true }
    local count = #ns.QueueWindow.groupsNeedingMe(wanted)
    local groups = count > 0 and ns.Locale.count(count, "%d group", "%d groups")
    local roles = W.selectedRoles()
    local counts = roles and ns.LfgList.isSearched(dungeonId) and ns.QueueWindow.lookingCounts(wanted)
    if counts and not groups and counts.T + counts.H + counts.D == 0 then
        return L["quiet"], { 0.6, 0.6, 0.6 }, L["Nobody else is looking for this dungeon right now."]
    end
    local role
    if counts then
        local slots = ns.engine and ns.engine.config.SLOTS or ns.Config.SLOTS
        for _, letter in ipairs({ "T", "H", "D" }) do
            if not role and W.hasRole(roles, letter) and counts[letter] < slots[letter] then
                role = letter
            end
        end
    end
    if not role then
        return groups or nil, GOLD
    end
    local name, n = Widgets.roleName(role), counts[role]
    local tip = n == 0
        and string.format(L["%s needed: nobody else who can play it is looking for it right now."], name)
        or string.format(L["%s needed: only %d others who can play it are looking for it right now."], name, n)
    if n == 1 then
        tip = string.format(L["%s needed: only one other player who can play it is looking for it right now."], name)
    end
    local needed = string.format(L["%s needed"], name)
    if not groups then
        return needed, GREEN, tip
    end
    local green = string.format("|cff%02x%02x%02x", GREEN[1] * 255, GREEN[2] * 255, GREEN[3] * 255)
    return string.format("%s  ·  %s%s|r", groups, green, needed), GOLD, tip
end

function W.paintDemand(text, dungeonId)
    local label, color = W.demand(dungeonId)
    text:SetText(label or "")
    if color then
        text:SetTextColor(color[1], color[2], color[3])
    end
end

-- The roles, shared by both tabs, and the playstyle (dungeons only);
-- returns the new y.
function W.layoutChoices(y, withPlaystyle)
    for _, role in ipairs(Widgets.ROLES) do
        roleToggles[role]:Show()
    end
    y = y - 6
    for i, role in ipairs(Widgets.ROLES) do
        W.place(roleToggles[role], PAD + (i - 1) * (TILE_WIDTH + TILE_GAP), y)
    end
    local needed, neededTip
    if withPlaystyle and not (ns.engine and ns.engine.myEntry) then
        needed, neededTip = W.neededRole()
    end
    for _, role in ipairs(Widgets.ROLES) do
        Widgets.paintNeeded(roleToggles[role], role == needed and neededTip or nil)
    end
    y = y - Widgets.TILE_HEIGHT - 10
    -- Under the tiles: the playstyle (dungeons only) on the left, the wish
    -- to lead on the right (alone only; a party already has its leader).
    ui.playstyleButton:SetShown(withPlaystyle)
    ui.playstyleLabel:SetShown(withPlaystyle)
    if withPlaystyle then
        local mine = ns.Playstyle.mine()
        local button = ui.playstyleButton
        button.label:SetText(ns.Playstyle.word(mine))
        -- As wide as the longest playstyle, so the box keeps its size.
        local longest = 0
        for _, id in ipairs(ns.Playstyle.ORDER) do
            button.measure:SetText(ns.Playstyle.word(id))
            longest = math.max(longest, button.measure:GetStringWidth() or 0)
        end
        button:SetWidth(BOX_PAD + longest + 6 + ARROW_SIZE + 3)
        W.place(button, PAD + (ui.playstyleLabel:GetStringWidth() or 0) + 6, y)
        ui.playstyleLabel:ClearAllPoints()
        ui.playstyleLabel:SetPoint("RIGHT", ui.playstyleButton, "LEFT", -6, 0)
    else
        W.hidePlaystyleMenu()
    end
    local solo = Party.state() == "solo"
    ui.leadCheck:SetShown(solo)
    if solo then
        ui.leadCheck:SetChecked(W.wantsLead(W.currentTab()))
        local labelWidth = ui.leadCheck.label:GetStringWidth() or 0
        W.place(ui.leadCheck, WIDTH - PAD - labelWidth - LEAD_BOX - 1, y - (BOX_HEIGHT - LEAD_BOX) / 2)
    end
    W.placeBattlegroundSize(PAD, y)
    local hint = W.currentTab() == "quests" and L["Questing groups: at most one tank and one healer."] or nil
    ui.roleHint:SetShown(hint ~= nil)
    if hint then
        ui.roleHint:SetText(hint)
        W.place(ui.roleHint, PAD, y - 5)
    end
    return y - BOX_HEIGHT - 10
end

-- Places dungeon cells first .. first + count - 1 from y down; returns the
-- new y.
function W.layoutCells(y, first, count)
    local detailed = W.isDetailed(count)
    for i = 1, count do
        local cell = dungeonCells[first + i - 1]
        if detailed then
            W.place(cell, PAD - CHECK_INSET, y - (i - 1) * DETAIL_HEIGHT)
        else
            local row, column = math.floor((i - 1) / COLUMNS), (i - 1) % COLUMNS
            W.place(cell, PAD - CHECK_INSET + column * CELL_WIDTH, y - row * CELL_HEIGHT)
        end
    end
    if detailed then
        return y - count * DETAIL_HEIGHT
    end
    return y - math.ceil(count / COLUMNS) * CELL_HEIGHT
end

function W.layoutSetup(y, partyRowCount, levelCount, otherCount)
    y = W.layoutChoices(y, true)
    if W.cardBelowRoles then
        y = W.cardBelowRoles(y)
    end
    if partyRowCount > 0 then
        W.place(ui.partyHeader, PAD, y)
        y = y - W.HEADER_STEP
        for i, row in ipairs(partyRows) do
            W.place(row, PAD, y - (i - 1) * PARTY_ROW_HEIGHT)
        end
        y = y - partyRowCount * PARTY_ROW_HEIGHT - 16
    end
    W.place(ui.dungeonHeader, PAD, y)
    ui.dungeonLinks:ClearAllPoints()
    ui.dungeonLinks:SetPoint("TOPRIGHT", W.frame, "TOPRIGHT", -PAD, y + 1)
    y = y - W.HEADER_STEP
    W.place(ui.empty, 22, y - 4)
    y = levelCount > 0 and W.layoutCells(y, 1, levelCount) or (y - DETAIL_HEIGHT)
    if not ui.otherToggle:IsShown() then
        return y - 8
    end
    W.place(ui.otherToggle, PAD, y - 6)
    y = y - 32
    return W.layoutCells(y, levelCount + 1, otherCount) - 8
end

-- The dungeons searched for, laid out like the table you picked them from.
function W.layoutQueued(y, entry)
    local count = #entry.dungeons
    local header = ns.Locale.count(count, "Searching %d dungeon", "Searching %d dungeons")
    local styles = entry.playstyle and entry.playstyle ~= ns.Playstyles.ANY
        and ns.Playstyle.describe({ entry.playstyle, unpack(ns.Playstyles.partners(entry.playstyle)) },
            " " .. L["or"] .. " ")
    ui.queueHeader:SetText(styles and (header .. "  ·  " .. styles) or header)
    W.place(ui.queueHeader, PAD, y)
    y = y - W.HEADER_STEP
    local known = ns.Features.countsKnown()
    local shown = count > QUEUE_ROWS and QUEUE_ROWS - 1 or count
    for i, row in ipairs(queueRows) do
        local dungeon = i <= shown and Dungeons.get(entry.dungeons[i])
        if dungeon then
            row.name:SetText(Dungeons.name(dungeon.id))
            row.name:SetTextColor(Widgets.levelColor(UnitLevel("player"), dungeon.min, dungeon.max))
            row.range:SetText(Dungeons.rangeText(dungeon))
            Widgets.setRoleCounts(row.counts, known and ns.QueueWindow.lookingCounts({ [dungeon.id] = true }))
            W.paintDemand(row.groups, dungeon.id)
            W.place(row, PAD - CHECK_INSET, y)
            row:Show()
            y = y - QUEUE_ROW_HEIGHT
        else
            row:Hide()
        end
    end
    ui.queueMore:SetShown(count > shown)
    if count > shown then
        ui.queueMore:SetText(string.format(L["and %d more: %s"], count - shown,
            W.shortNames({ unpack(entry.dungeons, shown + 1) })))
        W.place(ui.queueMore, PAD, y - 4)
        y = y - QUEUE_ROW_HEIGHT
    end
    return y - 6
end

function W.collectMembers()
    local roles = W.selectedRoles()
    if not roles then
        return nil, "Choose at least one role."
    end
    local members = { { name = ns.selfName, roles = roles, level = UnitLevel("player") } }
    local state = Party.state()
    if state == "member" or state == "raid" then
        return nil, "Only your party leader can queue the party."
    end
    if state == "leader" then
        local party = Party.members()
        if not party then
            return nil, "Party member names are still loading; try again in a moment."
        end
        for _, member in ipairs(party) do
            members[#members + 1] = { name = member.name, roles = ns.PartyRoles.rolesOf(member), level = member.level }
        end
    end
    local ok, err = Protocol.validateParty(members)
    if not ok then
        return nil, ERRORS[err] or err
    end
    return members
end

function W.selectVisible(value)
    local selected = W.selectedDungeons()
    for _, dungeon in ipairs(W.visibleDungeons()) do
        selected[dungeon.id] = value or nil
    end
    ns.LfgList.searchIfMissing()
    ns.Window.refresh()
end

function W.buildRoles()
    ui.roleHint = Widgets.text(W.frame, "GameFontHighlightSmall")
    ui.roleHint:SetWidth(WIDTH - 2 * PAD)
    ui.roleHint:SetTextColor(0.85, 0.85, 0.85)
    ui.leadCheck = Widgets.check(W.frame, "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:16:16|t I'd like to lead",
        function(self)
            W.setWantsLead(self:GetChecked())
        end)
    ui.leadCheck:SetSize(LEAD_BOX, LEAD_BOX)
    ui.leadCheck.label:SetFontObject(GameFontNormalSmall)
    Widgets.tooltip(ui.leadCheck, "I'd like to lead the group", "You become the group's leader when a group forms "
        .. "with you, unless a party already has a leader. Forever Groups won't ask listed groups to invite you: it "
        .. "builds the group for you, with you as its leader.")
    ui.leadCheck:Hide()
    for _, role in ipairs(Widgets.ROLES) do
        roleToggles[role] = Widgets.roleTile(W.frame, role, TILE_WIDTH, function(self)
            ns.charDb.lastRoles = Widgets.toggleRole(W.selectedRoles(), role, self:GetChecked())
            ns.LfgList.syncRoles(ns.charDb.lastRoles)
            W.setHint("")
            ns.Window.refresh()
        end)
    end
end

local function pickPlaystyle(id)
    ns.Playstyle.set(id)
    W.setHint("")
    ns.Window.refresh()
end

-- WoW's own menu (the one of its Group Finder's playstyle dropdown): a radio
-- per playstyle, with who you are grouped with in its tooltip.
local function setupMenu(button)
    button:SetupMenu(function(_, root)
        for _, id in ipairs(ns.Playstyle.ORDER) do
            local radio = root:CreateRadio(ns.Playstyle.word(id), function(value)
                return ns.Playstyle.mine() == value
            end, function(value)
                pickPlaystyle(value)
                return MenuResponse and MenuResponse.Close
            end, id)
            if radio and radio.SetTooltip then
                radio:SetTooltip(function(tooltip)
                    tooltip:SetText(ns.Playstyle.word(id), 1, 0.82, 0)
                    tooltip:AddLine(L[ns.Playstyle.DESCRIPTIONS[id]], 1, 1, 1, true)
                    tooltip:AddLine(ns.Playstyle.partnersText(id), 0.8, 0.8, 0.8, true)
                end)
            end
        end
    end)
end

-- The playstyle on the roles header: the choice and WoW's yellow arrow, no
-- frame around them; it opens WoW's own menu, or our list on a client
-- without one (wow/ui/playstylemenu.lua).
function W.buildPlaystyle()
    ui.playstyleLabel = Widgets.text(W.frame, "GameFontNormalSmall")
    ui.playstyleLabel:SetText("Playstyle:")
    local ok, button = pcall(CreateFrame, "DropdownButton", nil, W.frame, "BackdropTemplate")
    if not ok or not button then
        ok, button = pcall(CreateFrame, "DropdownButton", nil, W.frame)
    end
    local native = ok and button and type(button.SetupMenu) == "function"
    if not native then
        if ok and button then
            button:Hide()
        end
        button = Widgets.backdropFrame("Button", W.frame)
        button:SetScript("OnClick", function(self)
            ns.PlaystyleMenu.toggle(self, pickPlaystyle)
        end)
    end
    button:SetHeight(BOX_HEIGHT)
    Widgets.addOutline(button)
    button.label = Widgets.text(button, "GameFontHighlightSmall")
    button.label:SetPoint("LEFT", BOX_PAD, 0)
    button.measure = Widgets.text(button, "GameFontHighlightSmall")
    button.measure:Hide()
    button.arrow = button:CreateTexture(nil, "ARTWORK")
    button.arrow:SetSize(ARROW_SIZE, ARROW_SIZE)
    button.arrow:SetPoint("RIGHT", -3, 0)
    -- WoW's own dropdown button (the gold-edged square with the arrow); the
    -- plain yellow arrow on a client without that atlas.
    local atlas = Widgets.atlasExists("common-dropdown-a-button") and "common-dropdown-a-button"
    local function paint(state)
        local name = atlas and (atlas .. state)
        if name and state ~= "" and not Widgets.atlasExists(name) then
            name = atlas
        end
        if name then
            button.arrow:SetAtlas(name)
        else
            button.arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
        end
        Widgets.paintOutline(button, { 1, 1, 1, 0.04 }, state == "" and { 1, 1, 1, 0.35 } or { 1, 0.82, 0, 1 })
    end
    paint("")
    button:HookScript("OnEnter", function()
        paint("-hover")
    end)
    button:HookScript("OnLeave", function()
        paint("")
    end)
    button:HookScript("OnMouseDown", function()
        paint("-pressedhover")
    end)
    button:HookScript("OnMouseUp", function(self)
        paint(self:IsMouseOver() and "-hover" or "")
    end)
    if native then
        setupMenu(button)
    end
    button.native = native
    ui.playstyleButton = button
end

function W.hidePlaystyleMenu()
    local button = ui.playstyleButton
    if button and button.native and type(button.CloseMenu) == "function" then
        pcall(button.CloseMenu, button)
    end
    ns.PlaystyleMenu.hide()
end

function W.buildParty()
    ui.partyHeader = Widgets.header(W.frame, "Party: roles follow each member's role in WoW", PAD, W.HEADER_GAP)
    for i = 1, 4 do
        local row = CreateFrame("Frame", nil, W.frame)
        row:SetSize(WIDTH - 2 * PAD, PARTY_ROW_HEIGHT)
        row.partyRow = true
        row.name = Widgets.text(row, "GameFontHighlight")
        row.name:SetPoint("LEFT", 4, 0)
        row.name:SetWidth(190)
        row.icons = {}
        for _, role in ipairs(Widgets.ROLES) do
            row.icons[role] = Widgets.roleIcon(row, role, 18)
        end
        row.roles = Widgets.text(row, "GameFontHighlightSmall")
        row.roles:SetTextColor(0.75, 0.75, 0.75)
        partyRows[i] = row
    end
end

function W.buildDungeons()
    ui.dungeonHeader = Widgets.header(W.frame, "Dungeons", PAD, W.HEADER_GAP)
    ui.otherToggle = Widgets.expander(W.frame, "Other dungeons", WIDTH - 2 * PAD, function()
        W.showOthers = not W.showOthers
        ns.LfgList.searchIfStale(5)
        ns.Window.refresh()
    end)
    ui.dungeonLinks = CreateFrame("Frame", nil, W.frame)
    ui.selectNone = Widgets.link(ui.dungeonLinks, "None", function()
        W.selectVisible(false)
    end)
    ui.selectNone:SetPoint("RIGHT")
    local dot = Widgets.text(ui.dungeonLinks, "GameFontDisableSmall")
    dot:SetText("·")
    dot:SetPoint("RIGHT", ui.selectNone, "LEFT", -5, 0)
    ui.selectAll = Widgets.link(ui.dungeonLinks, "All", function()
        W.selectVisible(true)
    end)
    ui.selectAll:SetPoint("RIGHT", dot, "LEFT", -5, 0)
    ui.dungeonLinks:SetSize(80, 16)
    for i = 1, COLUMNS * MAX_ROWS do
        local cell = Widgets.check(W.frame, "", function(self)
            if self.dungeon then
                W.selectedDungeons()[self.dungeon.id] = self:GetChecked() and true or nil
            end
            W.setHint("")
            if self:GetChecked() and not ns.LfgList.searchIfMissing() then
                ns.LfgList.searchIfStale(5)
            end
            ns.Window.refresh()
        end)
        cell.range = Widgets.text(cell, "GameFontDisableSmall")
        cell.quests = Widgets.text(cell, "GameFontNormalSmall")
        cell.quests:SetPoint("LEFT", cell.range, "RIGHT", 10, 0)
        cell.counts = Widgets.roleCounts(cell, COUNT_SIZE)
        cell.counts:SetPoint("LEFT", cell, "LEFT", COUNTS_X, 0)
        cell.groups = Widgets.text(cell, "GameFontNormalSmall", "RIGHT")
        cell.groups:SetPoint("RIGHT", cell.counts, "LEFT", -14, 0)
        cell.hover = cell:CreateTexture(nil, "HIGHLIGHT")
        cell.hover:SetColorTexture(1, 1, 1, 0.06)
        cell.chosen = cell:CreateTexture(nil, "BACKGROUND")
        cell.chosen:SetAllPoints(cell.hover)
        cell.chosen:SetColorTexture(1, 0.82, 0, 0.07)
        cell:SetScript("OnEnter", function(self)
            if self.dungeon and GameTooltip then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(Dungeons.name(self.dungeon.id))
                GameTooltip:AddLine(string.format(L["Level %s"], Dungeons.rangeText(self.dungeon)), 1, 1, 1)
                local groups = ns.QueueWindow.groupsNeedingMe({ [self.dungeon.id] = true })
                if #groups > 0 then
                    GameTooltip:AddLine(L["Groups in WoW's Group Finder that need you:"], 1, 0.82, 0)
                    for n, group in ipairs(groups) do
                        if n > 6 then
                            GameTooltip:AddLine("  " .. string.format(L["and %d more"], #groups - 6), 1, 1, 1)
                            break
                        end
                        GameTooltip:AddLine(string.format("  %s (%d/5)", group.leader, group.members or 1), 1, 1, 1)
                    end
                end
                local _, _, demandTip = W.demand(self.dungeon.id)
                if demandTip then
                    GameTooltip:AddLine(demandTip, 1, 1, 1, true)
                end
                local quests = ns.Quests.forDungeon(self.dungeon.id)
                if #quests > 0 then
                    GameTooltip:AddLine(L["Your quests here:"], 1, 0.82, 0)
                    for _, title in ipairs(quests) do
                        GameTooltip:AddLine("  " .. title, 1, 1, 1)
                    end
                end
                GameTooltip:Show()
            end
        end)
        cell:SetScript("OnLeave", function()
            if GameTooltip then
                GameTooltip:Hide()
            end
        end)
        dungeonCells[i] = cell
    end
    ui.empty = Widgets.text(W.frame, "GameFontDisableSmall")
    ui.empty:SetText(L["No dungeons fit your level. Open 'Other dungeons' to pick one anyway."])
end
