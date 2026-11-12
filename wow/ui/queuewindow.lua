local _, ns = ...

local Widgets = ns.Widgets
local Dungeons = ns.Dungeons
local Playstyles = ns.Playstyles

-- Who is looking right now: Forever Groups players in the queue, and the solo
-- players listed in WoW's Group Finder for the dungeons you are looking for.
local QueueWindow = {}

local WIDTH = 560
local ROW_HEIGHT = 18

local frame
local sections = {}
local blocks = {}
local wheelSearching = false
local wheelBlocked = false
-- "dungeons" or "quests": the main window's tab when the window opened.
local mode = "dungeons"

-- The group quests this player is looking for: the questing queue's, else
-- the ones ticked on the Quests tab; as a set of quest keys.
function QueueWindow.wantedQuests()
    local entry = ns.questEngine and ns.questEngine.myEntry
    local keys = entry and entry.dungeons or (ns.WindowParts.tickedQuestKeys and ns.WindowParts.tickedQuestKeys()) or {}
    local wanted = {}
    for _, key in ipairs(keys) do
        wanted[key] = true
    end
    return wanted
end

-- The zones of those quests (zone name => true) and as a list.
local function zonesOf(wanted)
    local set, list = {}, {}
    for _, quest in ipairs(ns.Quests.groupQuests()) do
        if wanted[quest.key] and quest.zone and not set[quest.zone] then
            set[quest.zone] = true
            list[#list + 1] = quest.zone
        end
    end
    return set, list
end

-- Searches the Group Finder for what the window shows when its results are
-- older than `age` seconds; only from player input.
-- subject: "dungeons" or "quests"; the window's own by default.
function QueueWindow.searchIfStale(age, subject)
    if (subject or mode) ~= "quests" then
        return ns.LfgList.searchIfStale(age)
    end
    if ns.LfgList.secondsSinceZoneSearch() < age then
        return false
    end
    local _, zones = zonesOf(QueueWindow.wantedQuests())
    return ns.LfgList.searchZones(zones)
end

-- Every click or scroll in this window is player input, so it can refresh
-- the Group Finder results when they are older than `age` seconds.
local function onInput(age)
    if not ns.Input.run() then
        QueueWindow.searchIfStale(age)
    end
end

-- "RoL, WC, DM", or the first few and "+N" for a long list, so a row stays
-- one line.
local MAX_NAMES = 3

local function shortNames(ids)
    local names = {}
    for i, id in ipairs(ids) do
        if i > MAX_NAMES and #ids > MAX_NAMES + 1 then
            names[#names + 1] = "+" .. (#ids - MAX_NAMES)
            break
        end
        local dungeon = Dungeons.get(id)
        names[#names + 1] = dungeon and dungeon.short or id
    end
    return table.concat(names, ", ")
end

-- "Hogger", or "Hogger +2" for more quests, so a row stays one line.
local function shortQuests(keys)
    if #keys == 0 then
        return ""
    end
    local first = ns.Quests.nameOf(keys[1])
    return #keys > 1 and string.format("%s +%d", first, #keys - 1) or first
end

-- The Dungeons column: dungeons, or for quests the quests (Forever Groups)
-- or the zones (WoW's Group Finder).
local function areaText(ids, zones)
    if mode ~= "quests" then
        return shortNames(ids or {})
    end
    if zones then
        return table.concat(zones, ", ")
    end
    return shortQuests(ids or {})
end

local function sharesDungeon(ids, wanted)
    for _, id in ipairs(ids or {}) do
        if wanted[id] then
            return true
        end
    end
    return false
end

-- What the Group Finder lists for the window's subject: the dungeon
-- listings for the wanted dungeons, or the zone listings ("Quests & Zones")
-- in the zones of the wanted quests. Returns the listings and a match test.
local function finderSource(subject)
    if subject == "quests" then
        local zones = zonesOf(QueueWindow.wantedQuests())
        return (ns.LfgList.zoneListings()), function(listing)
            return sharesDungeon(listing.zones, zones)
        end
    end
    local wanted = QueueWindow.wantedDungeons()
    return (ns.LfgList.listings()), function(listing)
        return sharesDungeon(listing.dungeons, wanted)
    end
end

-- The dungeons this player is looking for: the queue entry's, else the ones
-- ticked in the main window.
function QueueWindow.wantedDungeons()
    local entry = ns.engine and ns.engine.myEntry
    local ids = entry and entry.dungeons or ns.Window.selectedDungeonIds()
    local wanted = {}
    for _, id in ipairs(ids) do
        wanted[id] = true
    end
    return wanted
end

-- Listed groups (not solo, not full) for the wanted dungeons (or, with
-- subject "quests", in the zones of the wanted quests).
function QueueWindow.groupFinderGroups(subject)
    local listings, matches = finderSource(subject)
    local result = {}
    if not ns.Features.groupFinder() then
        return result
    end
    local style = ns.Playstyle.mine()
    for _, listing in ipairs(listings) do
        if not listing.solo and (listing.members or 1) < 5 and listing.leader ~= ns.selfName
            and matches(listing) and ns.Playstyle.fits(listing.playstyle, style) then
            result[#result + 1] = listing
        end
    end
    return result
end

-- Listed groups for the given dungeons ({ [id] = true }) that still need one
-- of the player's roles; empty without roles, with the Group Finder off, or
-- when the player would like to lead (then they build their own group).
-- subject "quests": wanted is a set of quest keys, matched by their zones.
function QueueWindow.groupsNeedingMe(wanted, subject)
    local roles = ns.charDb and ns.charDb.lastRoles
    local result = {}
    local leading = ns.charDb[subject == "quests" and "wantsLeadQuests" or "wantsLead"]
    if not roles or not ns.Features.groupFinder() or leading then
        return result
    end
    local style = ns.Playstyle.mine()
    local listings, field = ns.LfgList.listings(), "dungeons"
    if subject == "quests" then
        listings, field, wanted = (ns.LfgList.zoneListings()), "zones", (zonesOf(wanted))
    end
    for _, listing in ipairs(listings) do
        local needs = false
        for role in string.gmatch(roles, ".") do
            needs = needs or (listing.remaining and (listing.remaining[role] or 0) > 0)
        end
        if needs and not listing.solo and (listing.members or 1) < 5 and listing.leader ~= ns.selfName
            and sharesDungeon(listing[field], wanted) and ns.Playstyle.fits(listing.playstyle, style) then
            result[#result + 1] = listing
        end
    end
    return result
end

-- Solo Group Finder listings for the wanted dungeons (or quest zones),
-- longest listed first.
function QueueWindow.groupFinderPlayers(subject)
    local listings, matches = finderSource(subject)
    local result = {}
    if not ns.Features.groupFinder() then
        return result
    end
    local style = ns.Playstyle.mine()
    for _, listing in ipairs(listings) do
        if listing.solo and listing.name ~= ns.selfName and matches(listing)
            and ns.Playstyle.fits(listing.playstyle, style) then
            result[#result + 1] = listing
        end
    end
    table.sort(result, function(a, b)
        return (a.age or 0) > (b.age or 0)
    end)
    return result
end

-- Counts are kept until the Group Finder results, the queue or the
-- player's playstyle change: the window asks for them every second, per row.
local countCache, countToken = {}, nil

local function wantedKey(wanted)
    local ids = {}
    for id in pairs(wanted) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    return table.concat(ids, ",")
end

local function countLooking(wanted, subject)
    local counts = { T = 0, H = 0, D = 0 }
    local function add(roles)
        for role in pairs(counts) do
            if string.find(roles, role, 1, true) then
                counts[role] = counts[role] + 1
            end
        end
    end
    local quests = subject == "quests"
    local engine = quests and ns.questEngine or ns.engine
    local style = ns.Playstyle.mine()
    local listings, field, areas = ns.LfgList.listings(), "dungeons", wanted
    if quests then
        listings, field, areas = (ns.LfgList.zoneListings()), "zones", (zonesOf(wanted))
    end
    if engine then
        for _, entry in ipairs(engine.queue:list()) do
            local mine = engine.myEntry and entry.id == engine.myEntry.id
            if not mine and sharesDungeon(entry.dungeons, wanted)
                and Playstyles.compatible(entry.playstyle, style) then
                for _, member in ipairs(entry.members) do
                    add(member.roles)
                end
            end
        end
    end
    for _, listing in ipairs(ns.Features.groupFinder() and listings or {}) do
        if listing.solo and listing.name ~= ns.selfName and sharesDungeon(listing[field], areas)
            and (quests or ns.Playstyle.fits(listing.playstyle, style)) then
            add(listing.roles)
        end
    end
    return counts
end

-- Other players looking for any of the wanted dungeons (a set of ids), in
-- the Forever Groups queue and solo in WoW's Group Finder. A player who can
-- play several roles counts for each. The result is shared: read it only.
-- subject "quests": wanted is a set of quest keys (the questing queue, and
-- solo players listed in those quests' zones).
function QueueWindow.lookingCounts(wanted, subject)
    local engine = ns.engine
    local _, zonesAt = ns.LfgList.zoneListings()
    local token = string.format("%d:%d:%d:%d:%s:%s", ns.LfgList.version(), engine and engine.queue.version or -1,
        ns.questEngine and ns.questEngine.queue.version or -1, ns.Playstyle.mine(),
        tostring(ns.Features.groupFinder()), tostring(zonesAt))
    if token ~= countToken then
        countCache, countToken = {}, token
    end
    local key = (subject or "dungeons") .. ":" .. wantedKey(wanted)
    if not countCache[key] then
        countCache[key] = countLooking(wanted, subject)
    end
    return countCache[key]
end

-- Whether the counts for quests can be told: WoW's Group Finder is off (only
-- Forever Groups counts) or the quests' zones were searched.
function QueueWindow.questCountsKnown()
    local _, zonesAt = ns.LfgList.zoneListings()
    return not ns.Features.groupFinder() or zonesAt ~= nil
end

-- The table's columns, x within a row (rows start 22 px in from the frame).
-- A column with a sort key sorts the list when its header is clicked.
-- Role: what the players can play (a party or group: the roles in it);
-- Needs: the places a party or group still has open, empty for a solo player.
local ROW_LEFT = 25
local ROW_WIDTH = WIDTH - 46
local NAME_X, LEVEL_X, DUNGEONS_X, TIME_WIDTH = 100, 254, 296, 70
local COLUMNS = {
    { label = "Roles", x = 0, width = 46, sort = "role" },
    { label = "Needs", x = 50, width = 46, sort = "needs" },
    { label = "Name", x = NAME_X, width = 150, sort = "name" },
    { label = "Lvl", x = LEVEL_X, width = 38, sort = "level" },
    { label = "Dungeons", x = DUNGEONS_X, width = 120 },
    { label = "Time", right = true, width = TIME_WIDTH, sort = "waiting" },
}
local TOP = 0
local EXPECTED = { T = 1, H = 1, D = 3 }

-- A row of column headers right above a list's cells; clicking one sorts
-- (every list) by it, clicking it again reverses the order.
local function buildHeaders(section)
    section.columns = {}
    for _, column in ipairs(COLUMNS) do
        local header = CreateFrame("Button", nil, frame)
        header:SetSize(column.width, 16)
        header.column = column
        header.label = Widgets.text(header, "GameFontNormalSmall", column.right and "RIGHT" or "LEFT")
        header.label:SetAllPoints()
        header.label:SetText(column.label)
        header.sort = column.sort
        if column.sort then
            header:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            header:SetScript("OnClick", function()
                if (ns.db.queueSort or "role") == column.sort then
                    ns.db.queueSortReverse = not ns.db.queueSortReverse or nil
                else
                    ns.db.queueSort = column.sort
                    ns.db.queueSortReverse = nil
                end
                onInput(10)
                QueueWindow.refresh()
            end)
            header:SetScript("OnEnter", function(self)
                if GameTooltip then
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText("Sort by " .. string.lower(column.sort == "level" and "level"
                        or self.label:GetText() or ""), 1, 0.82, 0)
                    GameTooltip:AddLine("Click again to reverse the order.", 1, 1, 1, true)
                    GameTooltip:Show()
                end
            end)
            header:SetScript("OnLeave", function()
                if GameTooltip then
                    GameTooltip:Hide()
                end
            end)
        end
        section.columns[#section.columns + 1] = header
    end
    section.line = frame:CreateTexture(nil, "ARTWORK")
    section.line:SetHeight(1)
    section.line:SetColorTexture(1, 1, 1, 0.15)
end

-- Tables fold to their caption and a summary. By default the half that
-- fits what you do is open: players when you'd like to lead (you build a
-- group), groups when you don't (you look for a place in one). A table you
-- fold or open yourself stays so, separately for leading and not leading.
local function foldMode()
    local leading = ns.charDb and ns.charDb[mode == "quests" and "wantsLeadQuests" or "wantsLead"]
    return leading and "lead" or "join"
end

local function isFolded(section)
    local fold = foldMode()
    local chosen = ns.db.queueFold and ns.db.queueFold[fold] and ns.db.queueFold[fold][section.key]
    if chosen ~= nil then
        return chosen
    end
    return (fold == "lead") == (section.kind == "groups")
end

local function toggleFold(section)
    local fold = foldMode()
    ns.db.queueFold = ns.db.queueFold or {}
    ns.db.queueFold[fold] = ns.db.queueFold[fold] or {}
    ns.db.queueFold[fold][section.key] = not isFolded(section)
    QueueWindow.refresh()
end

local function buildSection(title, rows, key, kind)
    local section = { rows = {}, offset = 0, items = {}, maxRows = rows, key = key, kind = kind }
    -- The list's caption (a fold button), then its column headers, then its rows.
    section.caption = CreateFrame("Button", nil, frame)
    section.caption:SetSize(WIDTH - 60, 16)
    section.caption.icon = section.caption:CreateTexture(nil, "ARTWORK")
    section.caption.icon:SetSize(12, 12)
    section.caption.icon:SetPoint("LEFT", 0, 0)
    section.caption:SetScript("OnClick", function()
        if #section.items > 0 then
            toggleFold(section)
        end
    end)
    section.header = Widgets.text(section.caption, "GameFontNormalSmall")
    section.header:SetText(title)
    section.header:SetPoint("LEFT", section.caption.icon, "RIGHT", 5, 0)
    section.header:SetWordWrap(false)
    section.summary = Widgets.text(section.caption, "GameFontDisableSmall")
    section.summary:SetPoint("LEFT", section.header, "RIGHT", 6, 0)
    section.summary:SetWordWrap(false)
    buildHeaders(section)
    section.area = CreateFrame("Frame", nil, frame)
    section.area:SetSize(WIDTH - 36, rows * ROW_HEIGHT)
    section.area:EnableMouseWheel(true)
    section.area:SetScript("OnMouseWheel", function(_, delta)
        local most = math.max(0, #section.items - section.maxRows)
        section.offset = math.min(most, math.max(0, section.offset - delta * 3))
        if not wheelBlocked then
            wheelSearching = true
            ns.LfgList.searchIfStale(10)
            wheelSearching = false
        end
        QueueWindow.refresh()
    end)
    section.track = section.area:CreateTexture(nil, "BACKGROUND")
    section.track:SetWidth(4)
    section.track:SetColorTexture(1, 1, 1, 0.08)
    section.thumb = section.area:CreateTexture(nil, "ARTWORK")
    section.thumb:SetWidth(4)
    section.thumb:SetColorTexture(1, 0.82, 0, 0.6)
    for i = 1, rows do
        local row = CreateFrame("Frame", nil, section.area)
        row:SetSize(WIDTH - 46, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", section.area, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
        row.icons, row.needs = {}, {}
        for j, role in ipairs(Widgets.ROLES) do
            row.icons[j] = Widgets.roleIcon(row, role, 14)
            row.icons[j]:SetPoint("LEFT", (j - 1) * 15, 0)
            row.needs[j] = Widgets.roleIcon(row, role, 14)
            row.needs[j]:SetPoint("LEFT", COLUMNS[2].x + (j - 1) * 15, 0)
            -- How many of that role, on the icon's top right corner, from 2 up.
            for _, icon in ipairs({ row.icons[j], row.needs[j] }) do
                icon.count = Widgets.text(row, "GameFontHighlightSmall")
                local font = GameFontHighlightSmall and GameFontHighlightSmall.GetFont
                    and GameFontHighlightSmall:GetFont()
                if font and icon.count.SetFont then
                    icon.count:SetFont(font, 8, "OUTLINE")
                end
                icon.count:SetPoint("TOPRIGHT", icon, "TOPRIGHT", 3, 2)
            end
        end
        -- Right-click: whisper or invite the player.
        row:EnableMouse(true)
        row.hover = row:CreateTexture(nil, "BACKGROUND")
        row.hover:SetAllPoints()
        row.hover:SetColorTexture(1, 1, 1, 0.06)
        row.hover:Hide()
        row:SetScript("OnEnter", function(self)
            self.hover:SetShown(self.item ~= nil and self.item.player ~= nil)
            QueueWindow.showRowTooltip(self, self.item)
        end)
        row:SetScript("OnLeave", function(self)
            self.hover:Hide()
            if GameTooltip then
                GameTooltip:Hide()
            end
        end)
        row:SetScript("OnMouseUp", function(self, button)
            if button == "RightButton" and self.item and self.item.player then
                QueueWindow.openMenu(self, self.item)
            end
        end)
        -- Fixed columns: roles, needs, name, level, dungeons, time.
        row.name = Widgets.text(row, "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", NAME_X, 0)
        row.name:SetWidth(LEVEL_X - NAME_X - 4)
        row.name:SetWordWrap(false)
        row.level = Widgets.text(row, "GameFontHighlightSmall")
        row.level:SetPoint("LEFT", LEVEL_X, 0)
        row.level:SetWidth(DUNGEONS_X - LEVEL_X - 4)
        row.dungeons = Widgets.text(row, "GameFontHighlightSmall")
        row.dungeons:SetPoint("LEFT", DUNGEONS_X, 0)
        row.dungeons:SetWidth(ROW_WIDTH - DUNGEONS_X - TIME_WIDTH - 6)
        row.dungeons:SetWordWrap(false)
        row.time = Widgets.text(row, "GameFontHighlightSmall", "RIGHT")
        row.time:SetPoint("RIGHT", -4, 0)
        row.time:SetWidth(TIME_WIDTH)
        for _, column in ipairs({ row.level, row.dungeons, row.time }) do
            column:SetTextColor(0.75, 0.75, 0.75)
        end
        section.rows[i] = row
    end
    section.more = Widgets.text(frame, "GameFontDisableSmall")
    return section
end

-- counts (optional): { T = n, H = n, D = n }; a number shows from 2 up.
local function paintIcons(icons, roles, counts)
    local shown = 0
    for _, role in ipairs(Widgets.ROLES) do
        if string.find(roles, role, 1, true) then
            shown = shown + 1
            Widgets.setRoleIcon(icons[shown], role)
            icons[shown]:Show()
            local count = counts and counts[role] or 0
            icons[shown].count:SetText(count >= 2 and tostring(count) or "")
            icons[shown].count:Show()
        end
    end
    for j = shown + 1, 3 do
        icons[j]:Hide()
        icons[j].count:Hide()
    end
end

local function paintRow(row, item)
    row.item = item
    local name, color = item.name, item.color
    paintIcons(row.icons, item.roles)
    paintIcons(row.needs, item.needs or "", item.needCounts)
    row.name:SetText(name)
    row.name:SetTextColor(color[1], color[2], color[3])
    row.level:SetText(item.levelText or (item.level and tostring(item.level)) or "")
    row.dungeons:SetText(item.dungeonText)
    row.time:SetText(item.time)
    row:Show()
end

-- Shows a window of the section's rows starting at its scroll offset;
-- the mouse wheel scrolls. Returns the new y.
-- "5 tanks, 2 healers, 16 DPS" for players; "2 need a tank, 12 need DPS"
-- for groups: what a folded table holds.
local function summarize(section, items)
    local counts = { T = 0, H = 0, D = 0 }
    for _, item in ipairs(items) do
        local letters = section.kind == "groups" and (item.needs or "") or item.roles
        for _, role in ipairs(Widgets.ROLES) do
            if string.find(letters, role, 1, true) then
                counts[role] = counts[role] + 1
            end
        end
    end
    local words = { T = { "tank", "tanks" }, H = { "healer", "healers" }, D = { "DPS", "DPS" } }
    if section.kind == "groups" then
        words = { T = { "need a tank", "need a tank" }, H = { "need a healer", "need a healer" },
            D = { "need DPS", "need DPS" } }
    end
    local parts = {}
    for _, role in ipairs(Widgets.ROLES) do
        if counts[role] > 0 then
            parts[#parts + 1] = string.format("%d %s", counts[role], words[role][counts[role] == 1 and 1 or 2])
        end
    end
    return #parts > 0 and ("·  " .. table.concat(parts, ", ")) or ""
end

local function fillSection(section, y, items, empty)
    section.items = items
    local ROWS = section.maxRows
    section.offset = math.min(section.offset, math.max(0, #items - ROWS))
    section.caption:ClearAllPoints()
    section.caption:SetPoint("TOPLEFT", frame, "TOPLEFT", ROW_LEFT, y - 2)
    local folded = #items > 0 and isFolded(section)
    section.caption.icon:SetShown(#items > 0)
    section.caption.icon:SetTexture(folded and "Interface\\Buttons\\UI-PlusButton-Up"
        or "Interface\\Buttons\\UI-MinusButton-Up")
    section.summary:SetText(folded and summarize(section, items) or "")
    if folded then
        section.line:Hide()
        section.area:Hide()
        section.more:Hide()
        for _, header in ipairs(section.columns) do
            header:Hide()
        end
        return y - 26
    end
    y = y - 20
    -- "Needs" only heads a table that holds a party or group; its space
    -- stays, so the columns of all tables line up.
    local anyNeeds = false
    for _, item in ipairs(items) do
        anyNeeds = anyNeeds or (item.needs or "") ~= ""
    end
    -- An empty table is just its caption and a line of text.
    local listed = #items > 0 and section.area:IsShown()
    section.line:SetShown(listed)
    for _, header in ipairs(section.columns) do
        header:SetShown(listed and (header.column.sort ~= "needs" or anyNeeds))
        header:ClearAllPoints()
        if header.column.right then
            header:SetPoint("TOPRIGHT", frame, "TOPLEFT", ROW_LEFT + ROW_WIDTH - 4, y)
        else
            header:SetPoint("TOPLEFT", frame, "TOPLEFT", ROW_LEFT + header.column.x, y)
        end
    end
    section.line:ClearAllPoints()
    section.line:SetPoint("TOPLEFT", frame, "TOPLEFT", ROW_LEFT, y - 17)
    section.line:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(WIDTH - ROW_LEFT - ROW_WIDTH) + 2, y - 17)
    if listed then
        y = y - 21
    end
    local visible = math.min(#items, ROWS)
    section.area:ClearAllPoints()
    section.area:SetPoint("TOPLEFT", frame, "TOPLEFT", ROW_LEFT, y)
    section.area:SetHeight(math.max(1, visible) * ROW_HEIGHT)
    for i, row in ipairs(section.rows) do
        local item = items[section.offset + i]
        if item and i <= visible then
            paintRow(row, item)
        else
            row:Hide()
        end
    end
    local scrolls = #items > ROWS
    section.track:SetShown(scrolls)
    section.thumb:SetShown(scrolls)
    if scrolls then
        local height = visible * ROW_HEIGHT
        local thumb = math.max(12, height * ROWS / #items)
        section.track:ClearAllPoints()
        section.track:SetPoint("TOPRIGHT", section.area, "TOPRIGHT", 0, 0)
        section.track:SetHeight(height)
        section.thumb:ClearAllPoints()
        section.thumb:SetPoint("TOPRIGHT", section.area, "TOPRIGHT", 0,
            -(height - thumb) * section.offset / (#items - ROWS))
        section.thumb:SetHeight(thumb)
    end
    y = y - visible * ROW_HEIGHT
    section.more:ClearAllPoints()
    section.more:SetPoint("TOPLEFT", frame, "TOPLEFT", ROW_LEFT, y - 2)
    if #items == 0 then
        section.more:SetText(empty)
    elseif scrolls then
        section.more:SetText(string.format("%d-%d of %d, scroll for more", section.offset + 1,
            section.offset + visible, #items))
    else
        section.more:SetText("")
    end
    if section.more:GetText() ~= "" then
        y = y - 18
    end
    return y - 10
end

local ROLE_ORDER = { T = 1, H = 2, D = 3 }
local function roleRank(item)
    return ROLE_ORDER[string.sub(item.roles, 1, 1)] or 4
end

local function needsRank(item)
    return ROLE_ORDER[string.sub(item.needs or "", 1, 1)] or 4
end

-- role: tanks, healers, DPS (a player with several roles counts for the
-- scarcest); waiting: longest first; name: A-Z; level: highest first. Ties
-- fall back to waiting, then name.
local COMPARE = {
    role = function(a, b)
        if roleRank(a) ~= roleRank(b) then
            return roleRank(a) < roleRank(b)
        end
    end,
    needs = function(a, b)
        if needsRank(a) ~= needsRank(b) then
            return needsRank(a) < needsRank(b)
        end
    end,
    waiting = function(a, b)
        if a.waited ~= b.waited then
            return a.waited > b.waited
        end
    end,
    name = function(a, b)
        if a.name ~= b.name then
            return a.name < b.name
        end
    end,
    level = function(a, b)
        if (a.level or 0) ~= (b.level or 0) then
            return (a.level or 0) > (b.level or 0)
        end
    end,
}

-- Roles to show; nil means all.
local function shownRoles()
    return ns.db.queueRoles
end

-- A solo player is shown for the roles they play; a party or group for the
-- places it still has open.
local function filtered(items)
    local roles = shownRoles()
    if not roles then
        return items
    end
    local result = {}
    for _, item in ipairs(items) do
        local letters = (item.needs or "") ~= "" and item.needs or item.roles
        for letter in string.gmatch(letters, ".") do
            if string.find(roles, letter, 1, true) then
                result[#result + 1] = item
                break
            end
        end
    end
    return result
end

local function sorted(items)
    items = filtered(items)
    local key = ns.db.queueSort or "role"
    local reverse = ns.db.queueSortReverse == true
    table.sort(items, function(a, b)
        local result = COMPARE[key](a, b)
        if result == nil then
            result = COMPARE.waiting(a, b)
        end
        if result == nil then
            result = a.name < b.name
            return result
        end
        if reverse then
            return not result
        end
        return result
    end)
    return items
end

local function letterCounts(letters)
    local counts = { T = 0, H = 0, D = 0 }
    for letter in string.gmatch(letters or "", ".") do
        counts[letter] = (counts[letter] or 0) + 1
    end
    return counts
end

local function queueItems()
    local items = {}
    local engine = mode == "quests" and ns.questEngine or ns.engine
    if not engine then
        return items
    end
    local snap = engine:snapshot()
    local now = GetServerTime()
    for _, entry in ipairs(snap.entries) do
        local roles
        for _, member in ipairs(entry.members) do
            for letter in string.gmatch(member.roles, ".") do
                roles = Widgets.toggleRole(roles, letter, true)
            end
        end
        roles = roles or ""
        local tags = {}
        if entry.id == ns.selfName then
            tags[#tags + 1] = "you"
        end
        if snap.fakes[entry.id] then
            tags[#tags + 1] = "fake"
        end
        if engine:isReserved(entry.id) then
            tags[#tags + 1] = "in a proposal"
        end
        local name = entry.id .. (#entry.members > 1 and string.format(" +%d", #entry.members - 1) or "")
        local dungeonText = (#tags > 0 and ("[" .. table.concat(tags, ", ") .. "]  ") or "")
            .. areaText(entry.dungeons)
        local menu = entry.id ~= ns.selfName and not snap.fakes[entry.id]
        local needs, roleCounts = "", nil
        if #entry.members > 1 then
            needs = ns.Filler.missingFor(ns.Roles.withReserved(entry.members, entry.reserved)) or ""
            roleCounts = { T = 0, H = 0, D = 0 }
            for _, member in ipairs(entry.members) do
                for letter in string.gmatch(member.roles, ".") do
                    roleCounts[letter] = roleCounts[letter] + 1
                end
            end
        end
        items[#items + 1] = { roles = roles, needs = needs, roleCounts = roleCounts, needCounts = letterCounts(needs),
            name = name, dungeonText = dungeonText,
            player = menu and entry.id or nil, party = #entry.members > 1 and entry or nil,
            time = Widgets.formatTime(now - entry.joinedAt), waited = now - entry.joinedAt,
            level = entry.members[1].level,
            color = entry.id == ns.selfName and { 1, 0.82, 0 } or { Widgets.classColor(ns.Specs.decode(entry.spec)) } }
    end
    return items
end

-- Queued solo players and queued parties, each list sorted; also whether any
-- party is queued at all (before the role filter).
local function queueLists()
    local solo, parties = {}, {}
    for _, item in ipairs(queueItems()) do
        local list = item.party and parties or solo
        list[#list + 1] = item
    end
    return sorted(solo), sorted(parties), #parties > 0
end

-- A listed group's roles already in it and its open places, e.g. "HD" and
-- "T", with how many of each.
local function groupRoles(listing)
    local present, needs = "", ""
    local presentCounts, needCounts = {}, {}
    for _, role in ipairs(Widgets.ROLES) do
        local left = listing.remaining and listing.remaining[role] or 0
        needCounts[role] = left
        presentCounts[role] = math.max(0, EXPECTED[role] - left)
        if left > 0 then
            needs = needs .. role
        end
        if left < EXPECTED[role] then
            present = present .. role
        end
    end
    return present, needs, presentCounts, needCounts
end


local function groupFinderItems()
    local items = {}
    for _, listing in ipairs(QueueWindow.groupFinderPlayers(mode)) do
        items[#items + 1] = { roles = listing.roles, needs = "", name = listing.name,
            dungeonText = areaText(listing.dungeons, listing.zones), player = listing.name,
            time = Widgets.formatTime(listing.age or 0), waited = listing.age or 0,
            level = listing.level,
            color = { Widgets.classColor(listing.classToken) } }
    end
    return sorted(items)
end

local function groupFinderGroupItems()
    local items = {}
    for _, listing in ipairs(QueueWindow.groupFinderGroups(mode)) do
        local present, needs, presentCounts, needCounts = groupRoles(listing)
        items[#items + 1] = { roles = present, needs = needs, roleCounts = presentCounts, needCounts = needCounts,
            name = string.format("%s +%d", listing.leader, (listing.members or 1) - 1),
            dungeonText = areaText(listing.dungeons, listing.zones), player = listing.leader, group = listing,
            time = Widgets.formatTime(listing.age or 0), waited = listing.age or 0,
            level = listing.level,
            color = { Widgets.classColor(listing.classToken) } }
    end
    return sorted(items)
end

-- "Healer, 2 DPS" from the letters and, when given, how many of each.
local function describe(letters, counts)
    local names = {}
    for letter in string.gmatch(letters or "", ".") do
        local count = counts and counts[letter] or 1
        names[#names + 1] = (count >= 2 and (count .. " ") or "") .. Widgets.ROLE_NAMES[letter]
    end
    return table.concat(names, ", ")
end

-- Hovering a party (Forever Groups) or a listed group: who is in it and
-- what it still needs.
function QueueWindow.showRowTooltip(row, item)
    if not GameTooltip or not item or not (item.party or item.group) then
        return
    end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    local needs = (item.needs or "") ~= "" and ("needs " .. describe(item.needs, item.needCounts)) or "full"
    if item.party then
        local entry = item.party
        GameTooltip:SetText(string.format("Party of %d  ·  %s", #entry.members, needs), 1, 0.82, 0)
        for i, member in ipairs(entry.members) do
            local spec = i == 1 and ns.Spec.label(entry.spec)
            local r, g, b = 1, 1, 1
            if i == 1 then
                r, g, b = Widgets.classColor(ns.Specs.decode(entry.spec))
            end
            GameTooltip:AddLine(string.format("%s%s  ·  %s%s", member.name, i == 1 and " (leader)" or "",
                spec and (spec .. ", ") or "", Widgets.describeRoles(member.roles)), r, g, b)
        end
    else
        local listing = item.group
        GameTooltip:SetText(string.format("Group of %d  ·  %s", listing.members or 1, needs), 1, 0.82, 0)
        local r, g, b = Widgets.classColor(listing.classToken)
        GameTooltip:AddLine(listing.leader .. " (leader)", r, g, b)
        if item.roles ~= "" then
            GameTooltip:AddLine("Has: " .. describe(item.roles, item.roleCounts), 0.85, 0.85, 0.85)
        end
        local names = {}
        for _, id in ipairs(listing.dungeons or {}) do
            names[#names + 1] = Dungeons.name(id)
        end
        for _, zone in ipairs(listing.zones or {}) do
            names[#names + 1] = zone
        end
        GameTooltip:AddLine(table.concat(names, ", ") .. "  ·  listed " .. item.time, 0.85, 0.85, 0.85, true)
    end
    if item.player then
        GameTooltip:AddLine(item.group and "Right-click: request to join, or whisper the leader"
            or "Right-click: whisper the leader", 0.6, 0.6, 0.6)
    end
    GameTooltip:Show()
end

-- The roles to ask a group for: the ones ticked in the window, else the
-- spec's, else DPS.
local function myRoles()
    local spec = ns.Spec.current()
    return ns.charDb.lastRoles or (spec and spec.roles) or "D"
end

local function firstWanted(ids)
    local wanted = QueueWindow.wantedDungeons()
    for _, id in ipairs(ids) do
        if wanted[id] then
            return id
        end
    end
    return ids[1]
end

-- The right-click menu: whisper or invite a player; for a group, ask its
-- leader to invite you (only while you are not in a group yourself).
function QueueWindow.openMenu(row, item)
    if not item.group then
        ns.PlayerMenu.open(row, item.player)
        return
    end
    local request
    if not IsInGroup() then
        request = { label = "Request to join", run = function()
            ns.Apply.request(item.group, myRoles(), firstWanted(item.group.dungeons))
        end }
    end
    ns.PlayerMenu.open(row, item.player, { first = request, whisperLabel = "Whisper leader", noInvite = true })
end

local function refreshSortBar()
    local key = ns.db.queueSort or "role"
    for _, section in ipairs({ sections.queue, sections.parties, sections.finder, sections.groups }) do
        for _, header in ipairs(section.columns) do
            if header.sort ~= nil and header.sort == key then
                header.label:SetTextColor(1, 0.82, 0)
            else
                header.label:SetTextColor(0.85, 0.85, 0.85)
            end
        end
    end
    sections.sortNote:SetText(ns.db.queueSortReverse and "reversed order" or "")
    local roles = shownRoles() or "THD"
    for role, toggle in pairs(sections.roleToggles) do
        Widgets.paintToggle(toggle, string.find(roles, role, 1, true) ~= nil, true)
    end
end

local function showSection(section, shown)
    for _, widget in ipairs({ section.caption, section.area, section.more, section.line }) do
        widget:SetShown(shown)
    end
    for _, header in ipairs(section.columns) do
        header:SetShown(shown)
    end
end

-- Each source gets a framed block: a header band with its icon and name,
-- then its two tables. Its fill is drawn on the window, under the rows; its
-- rounded border (WoW's tooltip edge) is a frame over them. The window's
-- inner panel sits a little right of centre, hence the uneven sides.
local BLOCK_LEFT, BLOCK_RIGHT, BLOCK_BAND, BLOCK_GAP, BLOCK_EDGE = 17, 11, 24, 6, 3

local function buildBlock(title, icon, coords)
    local block = {}
    block.bg = frame:CreateTexture(nil, "BORDER")
    block.bg:SetColorTexture(1, 1, 1, 0.03)
    block.band = frame:CreateTexture(nil, "BORDER", nil, 1)
    block.band:SetColorTexture(1, 0.82, 0, 0.12)
    local ok, border = pcall(CreateFrame, "Frame", nil, frame, "BackdropTemplate")
    block.border = ok and border or CreateFrame("Frame", nil, frame)
    block.border:SetFrameLevel((frame:GetFrameLevel() or 0) + 6)
    if block.border.SetBackdrop then
        block.border:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12 })
        block.border:SetBackdropBorderColor(1, 0.82, 0, 0.6)
    end
    block.icon = frame:CreateTexture(nil, "ARTWORK")
    block.icon:SetSize(18, 18)
    block.icon:SetTexture(icon)
    if coords then
        block.icon:SetTexCoord(unpack(coords))
    end
    block.title = Widgets.text(frame, "GameFontNormal")
    block.title:SetText(title)
    block.note = Widgets.text(frame, "GameFontDisableSmall", "RIGHT")
    return block
end

-- top and bottom: y of the block's edges (negative, from the window's top).
local function placeBlock(block, top, bottom, shown)
    for _, part in ipairs({ block.bg, block.band, block.icon, block.title, block.note, block.border }) do
        part:SetShown(shown)
    end
    if not shown then
        return
    end
    block.border:ClearAllPoints()
    block.border:SetPoint("TOPLEFT", frame, "TOPLEFT", BLOCK_LEFT, top)
    block.border:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", -BLOCK_RIGHT, bottom)
    block.bg:ClearAllPoints()
    block.bg:SetPoint("TOPLEFT", block.border, "TOPLEFT", BLOCK_EDGE, -BLOCK_EDGE)
    block.bg:SetPoint("BOTTOMRIGHT", block.border, "BOTTOMRIGHT", -BLOCK_EDGE, BLOCK_EDGE)
    block.band:ClearAllPoints()
    block.band:SetPoint("TOPLEFT", block.bg, "TOPLEFT")
    block.band:SetPoint("TOPRIGHT", block.bg, "TOPRIGHT")
    block.band:SetHeight(BLOCK_BAND - BLOCK_EDGE)
    block.icon:ClearAllPoints()
    block.icon:SetPoint("LEFT", block.band, "LEFT", 5, 0)
    block.title:ClearAllPoints()
    block.title:SetPoint("LEFT", block.icon, "RIGHT", 6, 0)
    block.note:ClearAllPoints()
    block.note:SetPoint("RIGHT", block.band, "RIGHT", -8, 0)
end

local function caption(word, count, suffix)
    return string.format("%s (%d)%s", word, count, suffix)
end

function QueueWindow.refresh()
    if not frame or not frame:IsShown() then
        return
    end
    refreshSortBar()
    local quests = mode == "quests"
    for _, section in ipairs({ sections.queue, sections.parties, sections.finder, sections.groups }) do
        local finderTable = section == sections.finder or section == sections.groups
        for _, header in ipairs(section.columns) do
            if header.column.label == "Dungeons" then
                header.label:SetText(not quests and "Dungeons" or (finderTable and "Zone" or "Quests"))
            end
        end
    end
    local suffix = shownRoles() and "  ·  filtered" or ""
    local top = -64 - TOP
    local y = top - BLOCK_BAND - 6
    -- Groups first, then players, in both blocks.
    local solo, parties, anyParty = queueLists()
    showSection(sections.parties, true)
    sections.parties.header:SetText(caption("Parties", #parties, suffix))
    y = fillSection(sections.parties, y, parties, anyParty and "No party needs these roles."
        or "No Forever Groups party is queued right now.")
    showSection(sections.queue, true)
    sections.queue.header:SetText(caption("Players", #solo, suffix))
    y = fillSection(sections.queue, y, solo, shownRoles() and "Nobody with these roles in the queue."
        or (quests and "Nobody is looking for a questing group right now."
            or "Nobody is in the Forever Groups queue right now."))
    placeBlock(blocks.addon, top, y + 4, true)
    -- With WoW's Group Finder turned off only Forever Groups players are shown.
    local useFinder = ns.Features.groupFinder()
    sections.refresh:SetShown(useFinder)
    showSection(sections.finder, useFinder)
    showSection(sections.groups, useFinder)
    if not useFinder then
        placeBlock(blocks.finder, 0, 0, false)
        frame:SetHeight(-y + 12)
        return
    end
    top = y - BLOCK_GAP
    y = top - BLOCK_BAND - 6
    local _, updatedAt = ns.LfgList.listings()
    if quests then
        updatedAt = select(2, ns.LfgList.zoneListings())
    end
    local finder = groupFinderItems()
    local groups = groupFinderGroupItems()
    if not quests and ns.LfgList.isSearching() then
        blocks.finder.note:SetText("searching...")
    elseif updatedAt then
        blocks.finder.note:SetText("searched " .. Widgets.formatTime(GetTime() - updatedAt) .. " ago")
    else
        blocks.finder.note:SetText("not searched yet")
    end
    sections.groups.header:SetText(caption("Groups", #groups, suffix))
    local where = quests and "in the zones of your quests" or "for your dungeons"
    y = fillSection(sections.groups, y, groups, shownRoles() and "No group needs these roles."
        or ("No groups listed " .. where .. "."))
    sections.finder.header:SetText(caption("Players", #finder, suffix))
    y = fillSection(sections.finder, y, finder, shownRoles() and "Nobody with these roles listed."
        or ("Nobody listed " .. where .. "."))
    placeBlock(blocks.finder, top, y + 4, true)
    frame:SetHeight(-y + 10)
end

local function build()
    frame = Widgets.window("ForeverGroupsQueueFrame", "Who is looking", WIDTH, 300)
    frame:SetScript("OnShow", QueueWindow.refresh)
    frame:HookScript("OnHide", function()
        ns.PlayerMenu.hide()
    end)
    local show = Widgets.text(frame, "GameFontNormalSmall")
    show:SetPoint("TOPLEFT", 18, -38 - TOP)
    show:SetText("Show:")
    sections.sortNote = Widgets.text(frame, "GameFontDisableSmall", "RIGHT")
    sections.sortNote:SetPoint("TOPRIGHT", -108, -38 - TOP)
    sections.roleToggles = {}
    for i, role in ipairs(Widgets.ROLES) do
        local toggle = Widgets.roleToggle(frame, role, 18, "GameFontHighlightSmall", function(self)
            local roles = Widgets.toggleRole(shownRoles() or "THD", role, self:GetChecked())
            if roles == nil then
                self:SetChecked(true)
                return
            end
            ns.db.queueRoles = roles ~= "THD" and roles or nil
            onInput(10)
            QueueWindow.refresh()
        end)
        toggle:SetPoint("TOPLEFT", 74 + (i - 1) * 96, -32 - TOP)
        sections.roleToggles[role] = toggle
    end
    sections.refresh = Widgets.button(frame, "Refresh", 80)
    sections.refresh:SetHeight(20)
    sections.refresh:SetPoint("TOPRIGHT", -18, -32 - TOP)
    Widgets.tooltip(sections.refresh, "Refresh", "Searches WoW's Group Finder again. The list also refreshes "
        .. "when you scroll it, click in this window, or press keys while playing (at most every 10 seconds).")
    sections.refresh:SetScript("OnClick", function()
        onInput(3)
        QueueWindow.refresh()
    end)
    ns.on("ADDON_ACTION_BLOCKED", function(addon)
        if wheelSearching and addon == ns.addonName then
            wheelBlocked = true
            ns.Log.debug("scrolling may not search the Group Finder; only clicks and keys will")
        end
    end)
    blocks.addon = buildBlock("Forever Groups", Widgets.ICON)
    blocks.finder = buildBlock("WoW Group Finder", "Interface\\LFGFrame\\LFG-Eye", { 0, 0.125, 0, 0.25 })
    sections.queue = buildSection("Players", 6, "addonPlayers", "players")
    sections.parties = buildSection("Parties", 4, "addonParties", "groups")
    sections.finder = buildSection("Players", 8, "finderPlayers", "players")
    sections.groups = buildSection("Groups", 8, "finderGroups", "groups")
end

local docked = false

-- Sticks to the main window's right edge (its left edge when the screen has
-- no room on the right), so the two move as one; it closes with it.
local function dock()
    local main = ns.WindowParts.frame
    if not main then
        return
    end
    if not docked then
        docked = true
        main:HookScript("OnHide", function()
            if frame then
                frame:Hide()
            end
        end)
    end
    local right, screen = main:GetRight(), UIParent:GetRight()
    -- The main window may be scaled down (small screens); compare in
    -- UIParent's units.
    if type(right) == "number" and main.GetEffectiveScale and UIParent.GetEffectiveScale then
        local scale, uiScale = main:GetEffectiveScale(), UIParent:GetEffectiveScale()
        if type(scale) == "number" and type(uiScale) == "number" and uiScale > 0 then
            right = right * scale / uiScale
        end
    end
    frame:ClearAllPoints()
    if type(right) == "number" and type(screen) == "number" and right + WIDTH + 2 > screen then
        frame:SetPoint("TOPRIGHT", main, "TOPLEFT", -2, 0)
    else
        frame:SetPoint("TOPLEFT", main, "TOPRIGHT", 2, 0)
    end
end

-- Called from clicks and typed commands, so opening refreshes the Group
-- Finder. Opens the main window too, with this one docked to it.
function QueueWindow.toggle()
    if not frame then
        build()
    end
    if frame:IsShown() then
        frame:Hide()
        return
    end
    ns.Window.show()
    mode = ns.WindowParts.currentTab() == "quests" and "quests" or "dungeons"
    dock()
    frame:Show()
    QueueWindow.searchIfStale(10)
end

function QueueWindow.hide()
    if frame then
        frame:Hide()
    end
end

function QueueWindow.subject()
    return mode
end

function QueueWindow.isShown()
    return frame ~= nil and frame:IsShown()
end

ns.QueueWindow = QueueWindow
