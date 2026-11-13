local _, ns = ...

local Widgets = ns.Widgets
local Log = ns.Log

-- The settings window, in tabs: Groups, Messages, Display. Every option is
-- stored in ForeverGroupsDB; options that are on by default are stored as
-- their opposite (e.g. noWhisper) so a fresh install needs no defaults table.
local Settings = {}

local WIDTH, HEIGHT = 600, 560
local TAB_WIDTH = 140
local TABS_Y = -30
local CONTENT_Y = -64

local TABS = {
    {
        key = "groups", title = "Groups",
        sections = {
            {
                title = "Finding groups",
                options = {
                    { key = "noGroupFinder", inverted = true, label = "Use WoW's Group Finder",
                        tip = "Off: Forever Groups only works with other Forever Groups players; it does not "
                            .. "search, ask, invite from or list in WoW's Group Finder. On: choose below which "
                            .. "parts it uses." },
                    { key = "autoSearchOff", inverted = true, parent = "noGroupFinder",
                        label = "Refresh WoW's Group Finder while I play",
                        tip = "While your group still needs players, the Group Finder is searched again on your "
                            .. "key presses and clicks in the game world, at most every 10 seconds and never in "
                            .. "combat." },
                    { key = "noApply", inverted = true, parent = "noGroupFinder",
                        label = "Ask groups in WoW's Group Finder to invite me",
                        tip = "When you search alone, first whisper the leader of a listed group that needs your "
                            .. "role, one at a time (the next after 20 seconds, or at once on a no). Without an "
                            .. "invite within a minute you build your own group." },
                    { key = "noFill", inverted = true, parent = "noGroupFinder",
                        label = "Invite players listed in WoW's Group Finder",
                        tip = "When no other Forever Groups player fits, build your group from players listed in "
                            .. "WoW's Group Finder (also the open places of a group the queue formed, and players "
                            .. "in the zone of a group quest). Off: only Forever Groups players; the Fill button "
                            .. "still works." },
                    { key = "noListing", inverted = true, parent = "noGroupFinder",
                        label = "List my group in WoW's Group Finder",
                        tip = "While your group still needs players, it is listed so others can apply; applicants "
                            .. "with a role you need are invited." },
                    { key = "noWhisperInvite", inverted = true, parent = "noGroupFinder",
                        label = "Invite players who whisper me a needed role",
                        tip = "While Forever Groups builds your group or has it listed (dungeons and quests), a "
                            .. "whisper like 'heal?' or 'dps lf group' gets an invite if that role is still open. "
                            .. "A whisper asking to join without a role gets asked which role they play." },
                    { key = "ownLanguageOnly", inverted = true, parent = "noGroupFinder",
                        label = "Find players of every language",
                        tip = "Without this, WoW's Group Finder only shows players listed in your own game "
                            .. "language." },
                    { key = "dryRun", parent = "noGroupFinder",
                        label = "Dry run: only list Group Finder picks, do not invite",
                        tip = "Shows in chat who would be whispered and invited, without doing it." },
                },
            },
            {
                title = "Joining",
                options = {
                    { key = "noAutoAccept", inverted = true,
                        label = "Join the group by itself once everyone accepted",
                        tip = "After you accepted a group proposal, the invite from that group's leader is "
                            .. "accepted for you, so you are in the group right away. Invites from anyone else "
                            .. "are never accepted for you." },
                    { key = "noAutoAcceptAsked", inverted = true,
                        label = "Join a group I asked to invite me by itself",
                        tip = "When the leader of a group you (or Forever Groups for you) whispered to ask for an "
                            .. "invite sends it, you join at once while you're still looking. Invites from leaders "
                            .. "you didn't ask are never accepted for you." },
                },
            },
        },
    },
    {
        key = "messages", title = "Messages", editor = true,
        sections = {
            {
                title = "Sending",
                options = {
                    { key = "noWhisper", inverted = true, label = "Whisper players before inviting them",
                        tip = "A short whisper with the dungeon and role, sent right before the invite." },
                    { key = "showSentWhispers", inverted = true,
                        label = "Hide the whispers Forever Groups sends for me",
                        tip = "The players still get them; only the copy in your own chat (\"To ...\") is left "
                            .. "out, and so are the answers of a leader Forever Groups asked for you (it answers "
                            .. "their questions about your level, class or spec). Whispers you type yourself, and "
                            .. "from anyone else, always show. /fg debug on shows everything." },
                    { key = "noPartyAnnounce", inverted = true, label = "Post in party chat",
                        tip = "As leader, says in party chat that the group is complete, and when you look for "
                            .. "a replacement." },
                },
            },
        },
    },
    {
        key = "display", title = "Display", extras = true,
        sections = {
            {
                title = "Display",
                options = {
                    { key = "statusHidden", inverted = true, label = "Show the status bar",
                        tip = "The small bar that shows the queue, proposals and your group while something "
                            .. "happens." },
                    { key = "minimapHidden", inverted = true, label = "Show the minimap button" },
                },
            },
            {
                title = "Sound",
                options = {
                    { key = "noSound", inverted = true, label = "Play a sound for proposals and a complete group" },
                    { key = "noFlash", inverted = true,
                        label = "Flash the WoW icon in the taskbar when you need to answer",
                        tip = "For group proposals and invites, so you notice them while the game is in the "
                            .. "background." },
                },
            },
            {
                title = "Advanced",
                options = {
                    { key = "debug", label = "Debug messages in chat",
                        tip = "Shows every message the addon sends and receives, and why groups do or do not "
                            .. "form." },
                },
            },
        },
    },
}

local frame
local checks = {}
local styleRows = {}
local tabs, pages = {}, {}
local baseLines = {}

local function findOption(key)
    for _, tab in ipairs(TABS) do
        for _, section in ipairs(tab.sections) do
            for _, option in ipairs(section.options) do
                if option.key == key then
                    return option
                end
            end
        end
    end
end

-- true when the feature is on.
function Settings.isOn(key)
    local option = findOption(key)
    if not option then
        return false
    end
    local stored = ns.db[key] == true
    if option.inverted then
        return not stored
    end
    return stored
end

local function applied()
    ns.Status.refresh()
    ns.MinimapButton.refresh()
    ns.Window.refresh()
end

local function currentTab()
    local key = ns.db.settingsTab
    for _, tab in ipairs(TABS) do
        if tab.key == key then
            return key
        end
    end
    return TABS[1].key
end

-- Options with a parent (the Group Finder parts) are greyed out while the
-- parent is off; their own value stays as it was.
local function refresh()
    for _, check in ipairs(checks) do
        check:SetChecked(Settings.isOn(check.option.key))
        local parent = check.option.parent
        Widgets.setEnabled(check, not parent or Settings.isOn(parent))
    end
    local current = Widgets.roleStyleKey()
    for _, row in ipairs(styleRows) do
        row.selected:SetShown(row.style.key == current)
    end
end

-- The chosen tab's page shows; the base line runs under the other tabs.
local function showTab(key)
    ns.db.settingsTab = key
    for _, tab in ipairs(TABS) do
        pages[tab.key]:SetShown(tab.key == key)
        Widgets.paintTab(tabs[tab.key], tab.key == key)
    end
    local chosen = tabs[key]
    baseLines[1]:ClearAllPoints()
    baseLines[1]:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, TABS_Y - 27)
    baseLines[1]:SetPoint("TOPRIGHT", chosen, "BOTTOMLEFT", 0, 1)
    baseLines[2]:ClearAllPoints()
    baseLines[2]:SetPoint("TOPLEFT", chosen, "BOTTOMRIGHT", 0, 1)
    baseLines[2]:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, TABS_Y - 27)
    refresh()
    if key == "messages" then
        ns.MessagesWindow.refresh()
    end
end

local function buildStyleRow(parent, style, y)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(WIDTH - 44, 32)
    row:SetPoint("TOPLEFT", 22, y)
    row.style = style
    row.selected = row:CreateTexture(nil, "BACKGROUND")
    row.selected:SetAllPoints()
    row.selected:SetColorTexture(1, 0.82, 0, 0.15)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    for i, role in ipairs(Widgets.ROLES) do
        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(28, 28)
        icon:SetPoint("LEFT", 4 + (i - 1) * 32, 0)
        Widgets.paintRoleIcon(icon, role, style)
    end
    local label = Widgets.text(row, "GameFontHighlight")
    label:SetPoint("LEFT", 112, 0)
    label:SetText(style.label)
    row:SetScript("OnClick", function()
        Widgets.setRoleStyle(style.key)
        refresh()
        applied()
    end)
    styleRows[#styleRows + 1] = row
end

local function buildSections(page, sections)
    local y = -8
    for _, section in ipairs(sections) do
        local header = Widgets.header(page, section.title)
        header:SetPoint("TOPLEFT", 18, y)
        y = y - 26
        for _, option in ipairs(section.options) do
            local check = Widgets.check(page, option.label, function(self)
                local on = self:GetChecked() and true or false
                if option.inverted then
                    ns.db[option.key] = not on or nil
                else
                    ns.db[option.key] = on or nil
                end
                if option.key == "noGroupFinder" and on then
                    -- A click may search: fill the lists right away.
                    ns.LfgList.search()
                end
                refresh()
                applied()
            end)
            check.option = option
            check:SetPoint("TOPLEFT", option.parent and 44 or 22, y)
            if option.tip then
                Widgets.tooltip(check, option.label, option.tip)
            end
            checks[#checks + 1] = check
            y = y - 26
        end
        y = y - 8
    end
    return y
end

local function buildExtras(page, y)
    local iconsHeader = Widgets.header(page, "Role icons")
    iconsHeader:SetPoint("TOPLEFT", 18, y)
    y = y - 26
    for _, style in ipairs(Widgets.ROLE_STYLES) do
        if Widgets.roleStyleAvailable(style) then
            buildStyleRow(page, style, y)
            y = y - 34
        end
    end
    y = y - 8
    local reset = Widgets.button(page, "Reset status bar position", 200)
    reset:SetPoint("TOPLEFT", 22, y)
    reset:SetScript("OnClick", function()
        ns.db.statusPosition = nil
        ns.Status.resetPosition()
        Log.info("Status bar moved back under the minimap.")
    end)
end

local function build()
    frame = Widgets.window("ForeverGroupsSettingsFrame", "Forever Groups Settings", WIDTH, HEIGHT)
    for i, tab in ipairs(TABS) do
        tabs[tab.key] = Widgets.tab(frame, tab.title, TAB_WIDTH, function()
            showTab(tab.key)
        end)
        tabs[tab.key]:SetPoint("TOPLEFT", 20 + (i - 1) * TAB_WIDTH, TABS_Y)
        local page = CreateFrame("Frame", nil, frame)
        page:SetPoint("TOPLEFT", 0, CONTENT_Y)
        page:SetPoint("BOTTOMRIGHT", 0, 12)
        pages[tab.key] = page
        local y = buildSections(page, tab.sections)
        if tab.editor then
            ns.MessagesWindow.build(page, WIDTH, y)
        end
        if tab.extras then
            buildExtras(page, y)
        end
    end
    for i = 1, 2 do
        local line = frame:CreateTexture(nil, "ARTWORK")
        line:SetHeight(1)
        line:SetColorTexture(1, 0.82, 0, 0.6)
        baseLines[i] = line
    end
    frame:SetScript("OnShow", function()
        showTab(currentTab())
    end)
end

-- tab: "groups", "messages" or "display"; without one the last tab used.
function Settings.show(tab)
    if not frame then
        build()
    end
    frame:Show()
    showTab(tab or currentTab())
end

function Settings.toggle(tab)
    if frame and frame:IsShown() and (not tab or tab == currentTab()) then
        frame:Hide()
    else
        Settings.show(tab)
    end
end

-- Adds an entry to WoW's own AddOns settings that opens this window, if this
-- client has that settings API.
function Settings.register()
    local api = _G.Settings
    if type(api) ~= "table" or type(api.RegisterCanvasLayoutCategory) ~= "function" then
        return
    end
    local panel = CreateFrame("Frame")
    local text = Widgets.text(panel, "GameFontNormalLarge")
    text:SetPoint("TOPLEFT", 16, -16)
    text:SetText("Forever Groups")
    local open = Widgets.button(panel, "Open Forever Groups settings", 220)
    open:SetPoint("TOPLEFT", 16, -48)
    open:SetScript("OnClick", function()
        Settings.show()
    end)
    pcall(function()
        local category = api.RegisterCanvasLayoutCategory(panel, "Forever Groups")
        api.RegisterAddOnCategory(category)
    end)
end

ns.Settings = Settings
