local _, ns = ...

local Widgets = ns.Widgets

local Popup = {}

local STATUS_TEXTURES = {
    waiting = "Interface\\RaidFrame\\ReadyCheck-Waiting",
    yes = "Interface\\RaidFrame\\ReadyCheck-Ready",
    no = "Interface\\RaidFrame\\ReadyCheck-NotReady",
}

local frame
local ui = {}
local rows = {}
local current
local currentEngine
local endTime

local function statusOf(answer)
    if answer == "Y" then
        return "yes"
    elseif answer == "N" or answer == "C" then
        return "no"
    end
    return "waiting"
end

local function myAnswer(view)
    for _, member in ipairs(view.members) do
        if member.owner == ns.selfName then
            return member.answer
        end
    end
end

local WIDTH = 320
-- Rows span the banner's width; icons, notes and checks share its 10 px
-- inner margin, so everything lines up under the picture.
local ROW_HEIGHT = 32
local ROWS_TOP = 80
-- The dungeon's picture as a banner under the title bar (Dungeons.art gives
-- the texture and its crop).
local BANNER_TOP, BANNER_HEIGHT, BANNER_INSET = 24, 112, 8
local ROW_WIDTH = WIDTH - 2 * BANNER_INSET
local MARGIN = 10
local CONTENT_LEFT = BANNER_INSET + MARGIN
local NAME_X = MARGIN + 28
local ROLE_ORDER = { T = 1, H = 2, D = 3 }

-- Tank, healer, then DPS; within a role the order of the proposal.
local function ordered(members)
    local list = {}
    for i, member in ipairs(members) do
        list[i] = { member = member, index = i }
    end
    table.sort(list, function(a, b)
        local ra, rb = ROLE_ORDER[a.member.role] or 4, ROLE_ORDER[b.member.role] or 4
        if ra ~= rb then
            return ra < rb
        end
        if (a.member.open or false) ~= (b.member.open or false) then
            return not a.member.open
        end
        return a.index < b.index
    end)
    for i, item in ipairs(list) do
        list[i] = item.member
    end
    return list
end

local function classOf(member)
    if member.name == ns.selfName then
        local _, token = UnitClass("player")
        return token
    end
    return (ns.Specs.decode(member.spec))
end

-- A place the leader fills from WoW's Group Finder after everyone accepted.
local function paintOpenRow(row, role)
    row.openRole = role
    Widgets.setRoleIcon(row.icon, role)
    row.icon:SetAlpha(0.4)
    row.name:SetText("Open")
    row.name:SetTextColor(0.6, 0.6, 0.6)
    row.detail:SetText("from the Group Finder")
    row.name:ClearAllPoints()
    row.name:SetPoint("TOPLEFT", NAME_X, -2)
    row.crown:Hide()
    row.highlight:Hide()
    row.status:SetTexture(nil)
end

local function paintRow(row, member, leader)
    local mine = member.name == ns.selfName
    row.openRole = nil
    Widgets.setRoleIcon(row.icon, member.role)
    row.icon:SetAlpha(1)
    row.name:SetText(member.name .. (mine and " (you)" or ""))
    row.name:SetTextColor(Widgets.classColor(classOf(member)))
    local spec = ns.Spec.label(member.spec) or (mine and ns.Spec.myLabel()) or nil
    local detail = member.fake and (spec and (spec .. "  ·  fake") or "fake") or spec or ""
    row.detail:SetText(detail)
    row.name:ClearAllPoints()
    if detail ~= "" then
        row.name:SetPoint("TOPLEFT", NAME_X, -2)
    else
        row.name:SetPoint("LEFT", NAME_X, 0)
    end
    row.crown:ClearAllPoints()
    row.crown:SetPoint("LEFT", row.name, "LEFT", (row.name:GetStringWidth() or 0) + 4, 1)
    row.crown:SetShown(member.name == leader)
    row.highlight:SetShown(mine)
    row.status:SetTexture(STATUS_TEXTURES[statusOf(member.answer)])
end

-- With a picture the popup takes ForeverDungeonJournal's card look: the
-- picture at full strength, the name in a dark band on top, small notes in
-- its lower corners and a bronze edge. Without one it looks as before.
-- info: { styles, role, levels }. Returns where the member rows start.
local function layoutTop(art, crop, info)
    local pictured = art ~= nil
    for _, part in ipairs({ ui.banner, ui.bannerTop, ui.bannerBottom, ui.bannerEdge, ui.bannerStyle,
        ui.bannerLevels, ui.bannerRole }) do
        part:SetShown(pictured)
    end
    ui.line:SetShown(not pictured)
    ui.subtitle:SetShown(not pictured)
    ui.dungeon:ClearAllPoints()
    if not pictured then
        ui.dungeon:SetJustifyH("CENTER")
        ui.dungeon:SetWidth(WIDTH - 20)
        ui.dungeon:SetPoint("TOP", 0, -32)
        ui.subtitle:ClearAllPoints()
        ui.subtitle:SetPoint("TOP", 0, -54)
        return ROWS_TOP
    end
    ui.banner:SetTexture(art)
    ui.banner:SetTexCoord(unpack(crop))
    ui.dungeon:SetJustifyH("LEFT")
    ui.dungeon:SetWidth(WIDTH - 2 * BANNER_INSET - 90)
    ui.dungeon:SetPoint("TOPLEFT", ui.banner, "TOPLEFT", 10, -8)
    ui.bannerStyle:SetText(info.styles or "")
    ui.bannerLevels:SetText(info.levels and ("LV " .. info.levels) or "")
    ui.bannerRole:SetText(info.role or "")
    return BANNER_TOP + BANNER_HEIGHT + 8
end

local function render(view)
    ui.dungeon:SetText(ns.Quests.nameOf(view.dungeon))
    local members = view.members
    local styles = ns.Playstyle.describe(view.playstyles)
    local role
    local accepted = 0
    for _, member in ipairs(members) do
        if member.name == ns.selfName then
            role = "you play " .. Widgets.ROLE_NAMES[member.role]
        end
        if member.answer == "Y" then
            accepted = accepted + 1
        end
    end
    local parts = {}
    parts[#parts + 1] = styles
    parts[#parts + 1] = role
    ui.subtitle:SetText(table.concat(parts, "  ·  "))
    local art, crop
    if view.queue ~= "quests" then
        art, crop = ns.Dungeons.art(view.dungeon)
    end
    local dungeon = ns.Dungeons.get(view.dungeon)
    local rowsTop = layoutTop(art, crop, {
        styles = styles, role = role, levels = dungeon and dungeon.min and ns.Dungeons.rangeText(dungeon),
    })
    local players = #members
    local places = {}
    for i, member in ipairs(members) do
        places[i] = member
    end
    for letter in string.gmatch(view.missing or "", ".") do
        places[#places + 1] = { role = letter, open = true }
    end
    places = ordered(places)
    for i, row in ipairs(rows) do
        local member = places[i]
        if member then
            if member.open then
                paintOpenRow(row, member.role)
            else
                paintRow(row, member, view.leader)
            end
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", BANNER_INSET, -rowsTop - (i - 1) * ROW_HEIGHT)
            row:Show()
        else
            row:Hide()
        end
    end
    local y = rowsTop + math.min(#places, #rows) * ROW_HEIGHT + 4
    ui.count:SetText(string.format("%d/%d accepted", accepted, players))
    local answered = myAnswer(view) == "Y"
    ui.accept:SetShown(not answered)
    ui.decline:SetShown(not answered)
    ui.waiting:SetShown(answered)
    frame:SetHeight(y + 70)
end

local function onUpdate()
    if not endTime then
        return
    end
    local left = math.max(0, endTime - GetTime())
    ui.bar:SetValue(left)
    ui.bar.text:SetText(string.format("%d s", math.ceil(left)))
end

local function buildBanner()
    ui.banner = frame:CreateTexture(nil, "BORDER")
    ui.banner:SetPoint("TOPLEFT", BANNER_INSET, -BANNER_TOP)
    ui.banner:SetPoint("TOPRIGHT", -BANNER_INSET, -BANNER_TOP)
    ui.banner:SetHeight(BANNER_HEIGHT)
    ui.bannerTop = frame:CreateTexture(nil, "BORDER", nil, 1)
    ui.bannerTop:SetPoint("TOPLEFT", ui.banner, "TOPLEFT")
    ui.bannerTop:SetPoint("TOPRIGHT", ui.banner, "TOPRIGHT")
    ui.bannerTop:SetHeight(44)
    -- Dark behind the name, fading out downwards: no hard edge on the picture.
    ui.bannerTop:SetColorTexture(1, 1, 1, 1)
    local faded = type(CreateColor) == "function" and pcall(ui.bannerTop.SetGradient, ui.bannerTop,
        "VERTICAL", CreateColor(0, 0, 0, 0), CreateColor(0, 0, 0, 0.7))
    if not faded then
        ui.bannerTop:SetColorTexture(0, 0, 0, 0.4)
    end
    -- A light shade along the bottom, for the small notes there.
    ui.bannerBottom = frame:CreateTexture(nil, "BORDER", nil, 1)
    ui.bannerBottom:SetPoint("BOTTOMLEFT", ui.banner, "BOTTOMLEFT")
    ui.bannerBottom:SetPoint("BOTTOMRIGHT", ui.banner, "BOTTOMRIGHT")
    ui.bannerBottom:SetHeight(26)
    ui.bannerBottom:SetColorTexture(1, 1, 1, 1)
    local shaded = type(CreateColor) == "function" and pcall(ui.bannerBottom.SetGradient, ui.bannerBottom,
        "VERTICAL", CreateColor(0, 0, 0, 0.55), CreateColor(0, 0, 0, 0))
    if not shaded then
        ui.bannerBottom:SetColorTexture(0, 0, 0, 0.3)
    end
    ui.bannerEdge = frame:CreateTexture(nil, "BORDER", nil, 2)
    ui.bannerEdge:SetPoint("TOPLEFT", ui.banner, "BOTTOMLEFT")
    ui.bannerEdge:SetPoint("TOPRIGHT", ui.banner, "BOTTOMRIGHT")
    ui.bannerEdge:SetHeight(2)
    ui.bannerEdge:SetColorTexture(0.72, 0.46, 0.2, 1)
    ui.bannerStyle = Widgets.text(frame, "GameFontHighlightSmall", "RIGHT")
    ui.bannerStyle:SetPoint("TOPRIGHT", ui.banner, "TOPRIGHT", -10, -11)
    ui.bannerLevels = Widgets.text(frame, "GameFontHighlightSmall")
    ui.bannerLevels:SetPoint("BOTTOMLEFT", ui.banner, "BOTTOMLEFT", 10, 6)
    ui.bannerRole = Widgets.text(frame, "GameFontHighlightSmall", "RIGHT")
    ui.bannerRole:SetPoint("BOTTOMRIGHT", ui.banner, "BOTTOMRIGHT", -10, 6)
end

local function buildRow()
    local row = CreateFrame("Frame", nil, frame)
    row:SetSize(ROW_WIDTH, ROW_HEIGHT - 2)
    row.panel = row:CreateTexture(nil, "BACKGROUND")
    row.panel:SetAllPoints()
    row.panel:SetColorTexture(0, 0, 0, 0.35)
    row.highlight = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    row.highlight:SetAllPoints()
    row.highlight:SetColorTexture(1, 0.82, 0, 0.14)
    row.icon = Widgets.roleIcon(row, "D", 20)
    row.icon:SetPoint("LEFT", MARGIN, 0)
    row.name = Widgets.text(row, "GameFontHighlight")
    row.detail = Widgets.text(row, "GameFontDisableSmall")
    row.detail:SetPoint("BOTTOMLEFT", NAME_X, 3)
    row.crown = row:CreateTexture(nil, "ARTWORK")
    row.crown:SetSize(14, 14)
    row.crown:SetTexture("Interface\\GroupFrame\\UI-Group-LeaderIcon")
    row.crown.iconLabel = "Leader"
    row.status = row:CreateTexture(nil, "ARTWORK")
    row.status:SetSize(18, 18)
    row.status:SetPoint("RIGHT", -MARGIN, 0)
    return row
end

local function build()
    frame = Widgets.window("ForeverGroupsProposalFrame", "Group found!", WIDTH, 300, false)
    if type(frame.CloseButton) == "table" then
        frame.CloseButton:Hide()
    end
    frame:ClearAllPoints()
    frame:SetPoint("TOP", 0, -140)
    ui.dungeon = Widgets.text(frame, "GameFontNormalLarge", "CENTER")
    ui.dungeon:SetWidth(WIDTH - 20)
    ui.subtitle = Widgets.text(frame, "GameFontDisableSmall", "CENTER")
    ui.subtitle:SetWidth(WIDTH - 20)
    ui.line = frame:CreateTexture(nil, "ARTWORK")
    ui.line:SetSize(ROW_WIDTH, 1)
    ui.line:SetPoint("TOP", 0, -72)
    ui.line:SetColorTexture(1, 0.82, 0, 0.35)
    buildBanner()
    for i = 1, 5 do
        rows[i] = buildRow()
    end
    ui.count = Widgets.text(frame, "GameFontHighlightSmall")
    ui.count:SetPoint("BOTTOMLEFT", CONTENT_LEFT, 48)
    local barLeft = CONTENT_LEFT + 92
    local barWidth = WIDTH - CONTENT_LEFT - barLeft
    ui.barBorder = frame:CreateTexture(nil, "BORDER")
    ui.barBorder:SetSize(barWidth + 2, 14)
    ui.barBorder:SetPoint("BOTTOMLEFT", barLeft - 1, 45)
    ui.barBorder:SetColorTexture(1, 0.82, 0, 0.35)
    ui.bar = CreateFrame("StatusBar", nil, frame)
    ui.bar:SetSize(barWidth, 12)
    ui.bar:SetPoint("BOTTOMLEFT", barLeft, 46)
    ui.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    ui.bar:SetStatusBarColor(1, 0.8, 0)
    ui.barBack = ui.bar:CreateTexture(nil, "BACKGROUND")
    ui.barBack:SetAllPoints()
    ui.barBack:SetColorTexture(0, 0, 0, 0.8)
    ui.bar.text = Widgets.text(ui.bar, "GameFontHighlightSmall", "CENTER")
    ui.bar.text:SetPoint("CENTER")
    ui.waiting = Widgets.text(frame, "GameFontNormal", "CENTER")
    ui.waiting:SetPoint("BOTTOM", 0, 18)
    ui.waiting:SetText("Accepted. Waiting for the others...")
    ui.accept = Widgets.button(frame, ACCEPT or "Accept", 120)
    ui.accept:SetPoint("BOTTOMLEFT", CONTENT_LEFT, 14)
    ui.accept:SetScript("OnClick", function()
        if currentEngine then
            currentEngine:respond(true)
        end
        if current and current.missing ~= "" and current.leader == ns.selfName then
            ns.LfgList.search()
        end
    end)
    ui.decline = Widgets.button(frame, DECLINE or "Decline", 120)
    ui.decline:SetPoint("BOTTOMRIGHT", -CONTENT_LEFT, 14)
    ui.decline:SetScript("OnClick", function()
        if currentEngine then
            currentEngine:respond(false)
        end
    end)
    frame:SetScript("OnUpdate", onUpdate)
end

-- engine: the queue the proposal came from (the dungeon queue when nil).
function Popup.show(view, engine)
    if not frame then
        build()
    end
    ns.Spec.remember(view)
    current = view
    currentEngine = engine or ns.engine
    local seconds = math.max(1, view.deadline - GetServerTime())
    endTime = GetTime() + seconds
    ui.bar:SetMinMaxValues(0, seconds)
    render(view)
    frame:Show()
    onUpdate()
    ns.Notify.attention()
end

function Popup.update(view)
    if current and frame and view.key == current.key then
        current = view
        render(view)
    end
end

-- engine: only hide when the popup shows that queue's proposal.
function Popup.hide(engine)
    if engine and currentEngine and engine ~= currentEngine then
        return
    end
    current = nil
    currentEngine = nil
    endTime = nil
    if frame then
        frame:Hide()
    end
end

function Popup.isShown()
    return frame ~= nil and frame:IsShown()
end

ns.Popup = Popup
