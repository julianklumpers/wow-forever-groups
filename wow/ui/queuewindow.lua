local _, ns = ...

local Widgets = ns.Widgets
local Dungeons = ns.Dungeons
local Playstyles = ns.Playstyles

-- Who is looking right now: Forever Groups players in the queue, and the solo
-- players listed in WoW's Group Finder for the dungeons you are looking for.
local QueueWindow = {}

local WIDTH = 560
local ROWS = 12
local ROW_HEIGHT = 18

local frame
local sections = {}
local wheelSearching = false
local wheelBlocked = false

-- Every click or scroll in this window is player input, so it can refresh
-- the Group Finder results when they are older than `age` seconds.
local function onInput(age)
    if not ns.Input.run() then
        ns.LfgList.searchIfStale(age)
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

local function sharesDungeon(ids, wanted)
    for _, id in ipairs(ids) do
        if wanted[id] then
            return true
        end
    end
    return false
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

-- Solo Group Finder listings for the wanted dungeons, longest listed first.
function QueueWindow.groupFinderPlayers()
    local wanted = QueueWindow.wantedDungeons()
    local result = {}
    if not ns.Features.groupFinder() then
        return result
    end
    local style = ns.Playstyle.mine()
    local listings = ns.LfgList.listings()
    for _, listing in ipairs(listings) do
        if listing.solo and listing.name ~= ns.selfName and sharesDungeon(listing.dungeons, wanted)
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

local function countLooking(wanted)
    local counts = { T = 0, H = 0, D = 0 }
    local function add(roles)
        for role in pairs(counts) do
            if string.find(roles, role, 1, true) then
                counts[role] = counts[role] + 1
            end
        end
    end
    local engine = ns.engine
    local style = ns.Playstyle.mine()
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
    for _, listing in ipairs(ns.Features.groupFinder() and ns.LfgList.listings() or {}) do
        if listing.solo and listing.name ~= ns.selfName and sharesDungeon(listing.dungeons, wanted)
            and ns.Playstyle.fits(listing.playstyle, style) then
            add(listing.roles)
        end
    end
    return counts
end

-- Other players looking for any of the wanted dungeons (a set of ids), in
-- the Forever Groups queue and solo in WoW's Group Finder. A player who can
-- play several roles counts for each. The result is shared: read it only.
function QueueWindow.lookingCounts(wanted)
    local engine = ns.engine
    local token = string.format("%d:%d:%d:%s", ns.LfgList.version(), engine and engine.queue.version or -1,
        ns.Playstyle.mine(), tostring(ns.Features.groupFinder()))
    if token ~= countToken then
        countCache, countToken = {}, token
    end
    local key = wantedKey(wanted)
    if not countCache[key] then
        countCache[key] = countLooking(wanted)
    end
    return countCache[key]
end

local function buildSection(title)
    local section = { rows = {}, offset = 0, items = {} }
    section.header = Widgets.header(frame, title)
    section.header:SetWidth(WIDTH - 36)
    section.header:SetWordWrap(false)
    section.area = CreateFrame("Frame", nil, frame)
    section.area:SetSize(WIDTH - 36, ROWS * ROW_HEIGHT)
    section.area:EnableMouseWheel(true)
    section.area:SetScript("OnMouseWheel", function(_, delta)
        local most = math.max(0, #section.items - ROWS)
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
    for i = 1, ROWS do
        local row = CreateFrame("Frame", nil, section.area)
        row:SetSize(WIDTH - 46, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", section.area, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
        row.icons = {}
        for j, role in ipairs(Widgets.ROLES) do
            row.icons[j] = Widgets.roleIcon(row, role, 14)
            row.icons[j]:SetPoint("LEFT", (j - 1) * 15, 0)
        end
        -- Fixed columns: roles, name, level, dungeons, time.
        row.name = Widgets.text(row, "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", 50, 0)
        row.name:SetWidth(150)
        row.name:SetWordWrap(false)
        row.level = Widgets.text(row, "GameFontHighlightSmall")
        row.level:SetPoint("LEFT", 204, 0)
        row.level:SetWidth(54)
        row.dungeons = Widgets.text(row, "GameFontHighlightSmall")
        row.dungeons:SetPoint("LEFT", 260, 0)
        row.dungeons:SetWidth(WIDTH - 46 - 260 - 96)
        row.dungeons:SetWordWrap(false)
        row.time = Widgets.text(row, "GameFontHighlightSmall", "RIGHT")
        row.time:SetPoint("RIGHT", -4, 0)
        row.time:SetWidth(92)
        for _, column in ipairs({ row.level, row.dungeons, row.time }) do
            column:SetTextColor(0.75, 0.75, 0.75)
        end
        section.rows[i] = row
    end
    section.more = Widgets.text(frame, "GameFontDisableSmall")
    return section
end

local function paintRow(row, item)
    local roles, name, color = item.roles, item.name, item.color
    local shown = 0
    for _, role in ipairs(Widgets.ROLES) do
        if string.find(roles, role, 1, true) then
            shown = shown + 1
            Widgets.setRoleIcon(row.icons[shown], role)
            row.icons[shown]:Show()
        end
    end
    for j = shown + 1, 3 do
        row.icons[j]:Hide()
    end
    row.name:SetText(name)
    row.name:SetTextColor(color[1], color[2], color[3])
    row.level:SetText(item.level and ("level " .. item.level) or "")
    row.dungeons:SetText(item.dungeonText)
    row.time:SetText(item.time)
    row:Show()
end

-- Shows a window of ROWS items starting at the section's scroll offset;
-- the mouse wheel scrolls. Returns the new y.
local function fillSection(section, y, items, empty)
    section.items = items
    section.offset = math.min(section.offset, math.max(0, #items - ROWS))
    section.header:ClearAllPoints()
    section.header:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, y)
    y = y - 24
    local visible = math.min(#items, ROWS)
    section.area:ClearAllPoints()
    section.area:SetPoint("TOPLEFT", frame, "TOPLEFT", 22, y)
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
    section.more:SetPoint("TOPLEFT", frame, "TOPLEFT", 22, y - 2)
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
local SORTS = { "role", "waiting", "name", "level" }
local SORT_LABELS = { role = "Role", waiting = "Waiting", name = "Name", level = "Level" }

local function roleRank(item)
    return ROLE_ORDER[string.sub(item.roles, 1, 1)] or 4
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

local function filtered(items)
    local roles = shownRoles()
    if not roles then
        return items
    end
    local result = {}
    for _, item in ipairs(items) do
        for letter in string.gmatch(item.roles, ".") do
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

local function queueItems()
    local items = {}
    local engine = ns.engine
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
            .. shortNames(entry.dungeons)
        items[#items + 1] = { roles = roles, name = name, dungeonText = dungeonText,
            time = "waiting " .. Widgets.formatTime(now - entry.joinedAt), waited = now - entry.joinedAt,
            level = entry.members[1].level,
            color = entry.id == ns.selfName and { 1, 0.82, 0 } or { 1, 1, 1 } }
    end
    return sorted(items)
end

local function groupFinderItems()
    local items = {}
    for _, listing in ipairs(QueueWindow.groupFinderPlayers()) do
        items[#items + 1] = { roles = listing.roles, name = listing.name, dungeonText = shortNames(listing.dungeons),
            time = "listed " .. Widgets.formatTime(listing.age or 0), waited = listing.age or 0,
            level = listing.level,
            color = { Widgets.classColor(listing.classToken) } }
    end
    return sorted(items)
end

local function refreshSortBar()
    local key = ns.db.queueSort or "role"
    for _, sort in ipairs(SORTS) do
        local button = sections.sortButtons[sort]
        if sort == key then
            button:LockHighlight()
        else
            button:UnlockHighlight()
        end
    end
    sections.sortNote:SetText(ns.db.queueSortReverse and "(reversed)" or "")
    local roles = shownRoles() or "THD"
    for role, toggle in pairs(sections.roleToggles) do
        Widgets.paintToggle(toggle, string.find(roles, role, 1, true) ~= nil, true)
    end
end

function QueueWindow.refresh()
    if not frame or not frame:IsShown() then
        return
    end
    refreshSortBar()
    local y = -88
    local suffix = shownRoles() and " (filtered)" or ""
    sections.queue.header:SetText("Forever Groups players" .. suffix)
    y = fillSection(sections.queue, y, queueItems(), shownRoles() and "Nobody with these roles in the queue."
        or "Nobody is in the Forever Groups queue right now.")
    -- With WoW's Group Finder turned off only Forever Groups players are shown.
    local useFinder = ns.Features.groupFinder()
    sections.refresh:SetShown(useFinder)
    for _, widget in ipairs({ sections.finder.header, sections.finder.header.line, sections.finder.area,
        sections.finder.more }) do
        if widget then
            widget:SetShown(useFinder)
        end
    end
    if not useFinder then
        frame:SetHeight(-y + 12)
        return
    end
    local _, updatedAt = ns.LfgList.listings()
    local finder = groupFinderItems()
    if ns.LfgList.isSearching() then
        sections.finder.header:SetText("WoW Group Finder: searching...")
    elseif updatedAt then
        local total = ns.LfgList.totalResults()
        sections.finder.header:SetText(string.format(
            "WoW Group Finder: %d solo players, %s listings for your dungeons (searched %s ago)%s",
            #finder, total >= 100 and "100+" or tostring(total), Widgets.formatTime(GetTime() - updatedAt), suffix))
    else
        sections.finder.header:SetText("WoW Group Finder (not searched yet)")
    end
    y = fillSection(sections.finder, y, finder, shownRoles() and "Nobody with these roles listed."
        or "Nobody listed for your dungeons.")
    frame:SetHeight(-y + 12)
end

local function build()
    frame = Widgets.window("ForeverGroupsQueueFrame", "Who is looking", WIDTH, 300)
    frame:SetScript("OnShow", QueueWindow.refresh)
    local label = Widgets.text(frame, "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", 18, -36)
    label:SetText("Sort by:")
    sections.sortButtons = {}
    local x = 74
    for _, sort in ipairs(SORTS) do
        local button = Widgets.button(frame, SORT_LABELS[sort], 76)
        button:SetHeight(20)
        button:SetPoint("TOPLEFT", x, -32)
        button:SetScript("OnClick", function()
            if (ns.db.queueSort or "role") == sort then
                ns.db.queueSortReverse = not ns.db.queueSortReverse or nil
            else
                ns.db.queueSort = sort
                ns.db.queueSortReverse = nil
            end
            onInput(10)
            QueueWindow.refresh()
        end)
        sections.sortButtons[sort] = button
        x = x + 80
    end
    sections.sortNote = Widgets.text(frame, "GameFontDisableSmall")
    sections.sortNote:SetPoint("TOPLEFT", x + 4, -36)
    local show = Widgets.text(frame, "GameFontNormalSmall")
    show:SetPoint("TOPLEFT", 18, -64)
    show:SetText("Show:")
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
        toggle:SetPoint("TOPLEFT", 74 + (i - 1) * 96, -58)
        sections.roleToggles[role] = toggle
    end
    sections.refresh = Widgets.button(frame, "Refresh", 80)
    sections.refresh:SetHeight(20)
    sections.refresh:SetPoint("TOPRIGHT", -18, -32)
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
    sections.queue = buildSection("Forever Groups players")
    sections.finder = buildSection("WoW Group Finder")
end

-- Called from clicks and typed commands, so opening refreshes the Group Finder.
function QueueWindow.toggle()
    if not frame then
        build()
    end
    frame:SetShown(not frame:IsShown())
    if frame:IsShown() then
        ns.LfgList.searchIfStale(10)
    end
end

function QueueWindow.isShown()
    return frame ~= nil and frame:IsShown()
end

ns.QueueWindow = QueueWindow
