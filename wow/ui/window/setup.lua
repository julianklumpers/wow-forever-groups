local _, ns = ...

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
local ROLE_WORDS = W.ROLE_WORDS
local TILE_GAP = W.TILE_GAP
local TILE_WIDTH = W.TILE_WIDTH
local PARTY_ROW_HEIGHT = W.PARTY_ROW_HEIGHT
local CHOICE_GAP = W.CHOICE_GAP
local CHOICE_WIDTH = W.CHOICE_WIDTH
local QUEUE_ROWS = W.QUEUE_ROWS
local QUEUE_ROW_HEIGHT = W.QUEUE_ROW_HEIGHT
local ERRORS = W.ERRORS
local LEAD_BOX = 20
local ui = W.ui
local roleToggles = W.roleToggles
local partyRows = W.partyRows
local dungeonCells = W.dungeonCells
local queueRows = W.queueRows
local playstyleChoices = W.playstyleChoices

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
    for role, tile in pairs(roleToggles) do
        local allowed = Classes.canPlay(myClass, role)
        tile.reason = not allowed and CLASS_REASON or nil
        Widgets.paintTile(tile, W.hasRole(W.selectedRoles(), role), not queued and allowed)
    end
end

-- The line under the role tiles: with several roles ticked, the one the
-- player will most likely get (the fewest players looking per open slot);
-- otherwise a tip. Always one line, so ticking a role never moves the layout.
function W.roleHint()
    local roles = W.selectedRoles()
    if not roles then
        return "Tick every role you can play."
    end
    if #roles < 2 then
        return "Can you play another role too? Tick it: groups form sooner."
    end
    local general = "Forever Groups picks the role a group needs most."
    if not ns.Features.countsKnown() then
        return general
    end
    local counts = ns.QueueWindow.lookingCounts(ns.QueueWindow.wantedDungeons())
    local perGroup = ns.Config.SLOTS
    local best, bestRatio, tie
    local parts = {}
    for _, role in ipairs(Widgets.ROLES) do
        if W.hasRole(roles, role) then
            local ratio = counts[role] / perGroup[role]
            if not best or ratio < bestRatio then
                best, bestRatio, tie = role, ratio, false
            elseif ratio == bestRatio then
                tie = true
            end
            local words = ROLE_WORDS[role]
            parts[#parts + 1] = string.format("%d %s", counts[role], counts[role] == 1 and words[1] or words[2])
        end
    end
    if tie then
        return general
    end
    return string.format("You will most likely play %s: %s looking.", Widgets.ROLE_NAMES[best],
        table.concat(parts, ", "))
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
            row.roles:SetText(Widgets.describeRoles(roles) .. "  (" .. ns.PartyRoles.sourceOf(member) .. ")")
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
    ui.dungeonHeader:SetText("Dungeons for level " .. UnitLevel("player")
        .. string.format("  ·  %d selected", count))
    Widgets.paintExpander(ui.otherToggle, W.showOthers, string.format("(%d)", others))
    ui.otherToggle:SetShown(others > 0)
    for i, cell in ipairs(dungeonCells) do
        local dungeon = list[i]
        local detailed = W.isDetailed(i <= #levelList and #levelList or #otherList)
        cell.dungeon = dungeon
        if dungeon then
            cell.label:SetText(dungeon.name)
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
                W.paintGroupsNeeding(cell.groups, dungeon.id)
            else
                cell.range:SetPoint("LEFT", cell.label, "RIGHT", 6, 0)
                Widgets.fitClickArea(cell, cell.range)
                cell.hover:SetPoint("BOTTOMRIGHT", cell, "BOTTOMLEFT", CELL_WIDTH - 8, -1)
            end
            cell.counts:SetShown(detailed)
            cell.groups:SetShown(detailed)
            local quests = #ns.Quests.forDungeon(dungeon.id)
            cell.quests:SetShown(detailed and quests > 0)
            cell.quests:SetText(string.format("%d quest%s", quests, quests == 1 and "" or "s"))
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
        ui.playstyleHint:Hide()
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
function W.paintGroupsNeeding(text, dungeonId)
    local count = #ns.QueueWindow.groupsNeedingMe({ [dungeonId] = true })
    text:SetText(count > 0 and string.format("%d group%s", count, count == 1 and "" or "s") or "")
end

-- The roles, shared by both tabs, and the playstyle (dungeons only);
-- returns the new y.
function W.layoutChoices(y, withPlaystyle)
    ui.rolesHeader:Show()
    if ui.rolesHeader.line then
        ui.rolesHeader.line:Show()
    end
    for _, role in ipairs(Widgets.ROLES) do
        roleToggles[role]:Show()
    end
    W.place(ui.rolesHeader, PAD, y)
    -- Alone, the wish to lead sits on the right of the header line, like the
    -- links of the dungeon list; a party already has its leader.
    local solo = Party.state() == "solo"
    ui.leadCheck:SetShown(solo)
    if solo then
        ui.leadCheck:SetChecked(W.wantsLead(withPlaystyle and "dungeons" or "quests"))
        local labelWidth = ui.leadCheck.label:GetStringWidth() or 0
        W.place(ui.leadCheck, WIDTH - PAD - labelWidth - LEAD_BOX - 1, y + 4)
    end
    y = y - 26
    for i, role in ipairs(Widgets.ROLES) do
        W.place(roleToggles[role], PAD + (i - 1) * (TILE_WIDTH + TILE_GAP), y)
    end
    y = y - 76 - 10
    if withPlaystyle then
        ui.roleHint:SetText(W.roleHint())
    else
        ui.roleHint:SetText(W.selectedRoles()
            and "Questing groups: at most one tank and one healer."
            or "Tick every role you can play.")
    end
    ui.roleHint:Show()
    W.place(ui.roleHint, PAD, y)
    y = y - 26
    if not withPlaystyle then
        return y
    end
    ui.playstyleHeader:Show()
    W.place(ui.playstyleHeader, PAD, y)
    y = y - 26
    local mine = ns.Playstyle.mine()
    for i, choice in ipairs(playstyleChoices) do
        Widgets.paintChoice(choice, choice.playstyle == mine)
        W.place(choice, PAD + (i - 1) * (CHOICE_WIDTH + CHOICE_GAP), y)
    end
    y = y - 28 - 8
    ui.playstyleHint:SetText(ns.Playstyle.partnersText(mine))
    ui.playstyleHint:Show()
    W.place(ui.playstyleHint, PAD, y)
    for _, choice in ipairs(playstyleChoices) do
        choice:Show()
    end
    return y - 26
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
    if partyRowCount > 0 then
        W.place(ui.partyHeader, PAD, y)
        y = y - 26
        for i, row in ipairs(partyRows) do
            W.place(row, PAD, y - (i - 1) * PARTY_ROW_HEIGHT)
        end
        y = y - partyRowCount * PARTY_ROW_HEIGHT - 16
    end
    W.place(ui.dungeonHeader, PAD, y)
    ui.dungeonLinks:ClearAllPoints()
    ui.dungeonLinks:SetPoint("TOPRIGHT", W.frame, "TOPRIGHT", -PAD, y + 1)
    y = y - 26
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
    local header = string.format("Searching %d dungeon%s", count, count == 1 and "" or "s")
    local styles = entry.playstyle and entry.playstyle ~= ns.Playstyles.ANY
        and ns.Playstyle.describe({ entry.playstyle, unpack(ns.Playstyles.partners(entry.playstyle)) }, " or ")
    ui.queueHeader:SetText(styles and (header .. "  ·  " .. styles) or header)
    W.place(ui.queueHeader, PAD, y)
    y = y - 26
    local known = ns.Features.countsKnown()
    local shown = count > QUEUE_ROWS and QUEUE_ROWS - 1 or count
    for i, row in ipairs(queueRows) do
        local dungeon = i <= shown and Dungeons.get(entry.dungeons[i])
        if dungeon then
            row.name:SetText(dungeon.name)
            row.name:SetTextColor(Widgets.levelColor(UnitLevel("player"), dungeon.min, dungeon.max))
            row.range:SetText(Dungeons.rangeText(dungeon))
            Widgets.setRoleCounts(row.counts, known and ns.QueueWindow.lookingCounts({ [dungeon.id] = true }))
            W.paintGroupsNeeding(row.groups, dungeon.id)
            W.place(row, PAD - CHECK_INSET, y)
            row:Show()
            y = y - QUEUE_ROW_HEIGHT
        else
            row:Hide()
        end
    end
    ui.queueMore:SetShown(count > shown)
    if count > shown then
        ui.queueMore:SetText(string.format("and %d more: %s", count - shown,
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
    ns.Window.refresh()
end

function W.buildRoles()
    ui.rolesHeader = Widgets.header(W.frame, "Your roles", PAD)
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
            W.setHint("")
            ns.Window.refresh()
        end)
    end
end

function W.buildPlaystyle()
    ui.playstyleHeader = Widgets.header(W.frame, "Playstyle", PAD)
    ui.playstyleHint = Widgets.text(W.frame, "GameFontHighlightSmall")
    ui.playstyleHint:SetWidth(WIDTH - 2 * PAD)
    ui.playstyleHint:SetTextColor(0.85, 0.85, 0.85)
    for i, id in ipairs(ns.Playstyle.ORDER) do
        local choice = Widgets.choice(W.frame, ns.Playstyle.word(id), CHOICE_WIDTH, function()
            ns.Playstyle.set(id)
            W.setHint("")
            ns.Window.refresh()
        end)
        choice.playstyle = id
        Widgets.tooltip(choice, ns.Playstyle.word(id), ns.Playstyle.DESCRIPTIONS[id] .. " "
            .. ns.Playstyle.partnersText(id))
        playstyleChoices[i] = choice
    end
end

function W.buildParty()
    ui.partyHeader = Widgets.header(W.frame, "Party: roles follow each member's role in WoW", PAD)
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
    ui.dungeonHeader = Widgets.header(W.frame, "Dungeons", PAD)
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
            ns.LfgList.searchIfStale(5)
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
                GameTooltip:SetText(self.dungeon.name)
                GameTooltip:AddLine("Level " .. Dungeons.rangeText(self.dungeon), 1, 1, 1)
                local groups = ns.QueueWindow.groupsNeedingMe({ [self.dungeon.id] = true })
                if #groups > 0 then
                    GameTooltip:AddLine("Groups in WoW's Group Finder that need you:", 1, 0.82, 0)
                    for n, group in ipairs(groups) do
                        if n > 6 then
                            GameTooltip:AddLine(string.format("  and %d more", #groups - 6), 1, 1, 1)
                            break
                        end
                        GameTooltip:AddLine(string.format("  %s (%d/5)", group.leader, group.members or 1), 1, 1, 1)
                    end
                end
                local quests = ns.Quests.forDungeon(self.dungeon.id)
                if #quests > 0 then
                    GameTooltip:AddLine("Your quests here:", 1, 0.82, 0)
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
    ui.empty:SetText("No dungeons fit your level. Open 'Other dungeons' to pick one anyway.")
end
