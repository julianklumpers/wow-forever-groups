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
local ROW_WIDTH = 268
local ROW_HEIGHT = 30
local ROWS_TOP = 80
-- The dungeon's picture as a banner under the title bar (Dungeons.art gives
-- the texture and its crop).
local BANNER_TOP, BANNER_HEIGHT, BANNER_INSET = 24, 112, 8
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

local function paintRow(row, member, leader)
    local mine = member.name == ns.selfName
    Widgets.setRoleIcon(row.icon, member.role)
    row.name:SetText(member.name .. (mine and " (you)" or ""))
    row.name:SetTextColor(Widgets.classColor(classOf(member)))
    local spec = ns.Spec.label(member.spec) or (mine and ns.Spec.myLabel()) or nil
    local detail = member.fake and (spec and (spec .. "  ·  fake") or "fake") or spec or ""
    row.detail:SetText(detail)
    row.name:ClearAllPoints()
    if detail ~= "" then
        row.name:SetPoint("TOPLEFT", 30, -2)
    else
        row.name:SetPoint("LEFT", 30, 0)
    end
    row.crown:ClearAllPoints()
    row.crown:SetPoint("LEFT", row.name, "LEFT", (row.name:GetStringWidth() or 0) + 4, 1)
    row.crown:SetShown(member.name == leader)
    row.highlight:SetShown(mine)
    row.status:SetTexture(STATUS_TEXTURES[statusOf(member.answer)])
end

-- With a picture the name sits on the banner's lower part; without one the
-- popup looks as before. Returns where the member rows start.
local function layoutTop(art, crop)
    ui.banner:SetShown(art ~= nil)
    ui.bannerFade:SetShown(art ~= nil)
    ui.line:SetShown(art == nil)
    ui.dungeon:ClearAllPoints()
    ui.subtitle:ClearAllPoints()
    if not art then
        ui.dungeon:SetPoint("TOP", 0, -32)
        ui.subtitle:SetPoint("TOP", 0, -54)
        return ROWS_TOP
    end
    ui.banner:SetTexture(art)
    ui.banner:SetTexCoord(unpack(crop))
    local bottom = BANNER_TOP + BANNER_HEIGHT
    ui.dungeon:SetPoint("TOP", 0, -(bottom - 50))
    ui.subtitle:SetPoint("TOP", 0, -(bottom - 28))
    return bottom + 8
end

local function render(view)
    ui.dungeon:SetText(ns.Quests.nameOf(view.dungeon))
    local art, crop
    if view.queue ~= "quests" then
        art, crop = ns.Dungeons.art(view.dungeon)
    end
    local rowsTop = layoutTop(art, crop)
    local members = ordered(view.members)
    local parts = {}
    local styles = ns.Playstyle.describe(view.playstyles)
    if styles then
        parts[#parts + 1] = styles
    end
    local accepted = 0
    for _, member in ipairs(members) do
        if member.name == ns.selfName then
            parts[#parts + 1] = "you play " .. Widgets.ROLE_NAMES[member.role]
        end
        if member.answer == "Y" then
            accepted = accepted + 1
        end
    end
    ui.subtitle:SetText(table.concat(parts, "  ·  "))
    for i, row in ipairs(rows) do
        local member = members[i]
        if member then
            paintRow(row, member, view.leader)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", (WIDTH - ROW_WIDTH) / 2, -rowsTop - (i - 1) * ROW_HEIGHT)
            row:Show()
        else
            row:Hide()
        end
    end
    local y = rowsTop + #members * ROW_HEIGHT + 6
    if view.missing and view.missing ~= "" then
        local names = {}
        for letter in string.gmatch(view.missing, ".") do
            names[#names + 1] = Widgets.ROLE_NAMES[letter]
        end
        ui.missing:SetText("From the Group Finder: " .. table.concat(names, ", "))
        ui.missing:ClearAllPoints()
        ui.missing:SetPoint("TOP", 0, -y)
        ui.missing:Show()
        y = y + 20
    else
        ui.missing:SetText("")
        ui.missing:Hide()
    end
    ui.count:SetText(string.format("%d/%d accepted", accepted, #members))
    local answered = myAnswer(view) == "Y"
    ui.accept:SetShown(not answered)
    ui.decline:SetShown(not answered)
    ui.waiting:SetShown(answered)
    frame:SetHeight(y + 82)
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
    -- The banner's lower part fades into the dark panel, under the name.
    ui.bannerFade = frame:CreateTexture(nil, "BORDER", nil, 2)
    ui.bannerFade:SetPoint("BOTTOMLEFT", ui.banner, "BOTTOMLEFT")
    ui.bannerFade:SetPoint("BOTTOMRIGHT", ui.banner, "BOTTOMRIGHT")
    ui.bannerFade:SetHeight(BANNER_HEIGHT * 0.5)
    ui.bannerFade:SetColorTexture(1, 1, 1, 1)
    local faded = type(CreateColor) == "function" and pcall(ui.bannerFade.SetGradient, ui.bannerFade,
        "VERTICAL", CreateColor(0, 0, 0, 0.65), CreateColor(0, 0, 0, 0))
    if not faded then
        ui.bannerFade:SetColorTexture(0, 0, 0, 0.3)
    end
end

local function buildRow()
    local row = CreateFrame("Frame", nil, frame)
    row:SetSize(ROW_WIDTH, ROW_HEIGHT - 2)
    row.highlight = row:CreateTexture(nil, "BACKGROUND")
    row.highlight:SetAllPoints()
    row.highlight:SetColorTexture(1, 0.82, 0, 0.12)
    row.icon = Widgets.roleIcon(row, "D", 20)
    row.icon:SetPoint("LEFT", 4, 0)
    row.name = Widgets.text(row, "GameFontHighlight")
    row.detail = Widgets.text(row, "GameFontDisableSmall")
    row.detail:SetPoint("BOTTOMLEFT", 30, 2)
    row.crown = row:CreateTexture(nil, "ARTWORK")
    row.crown:SetSize(14, 14)
    row.crown:SetTexture("Interface\\GroupFrame\\UI-Group-LeaderIcon")
    row.crown.iconLabel = "Leader"
    row.status = row:CreateTexture(nil, "ARTWORK")
    row.status:SetSize(18, 18)
    row.status:SetPoint("RIGHT", -4, 0)
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
    ui.missing = Widgets.text(frame, "GameFontNormalSmall", "CENTER")
    ui.count = Widgets.text(frame, "GameFontHighlightSmall")
    ui.count:SetPoint("BOTTOMLEFT", (WIDTH - ROW_WIDTH) / 2, 48)
    local barLeft = (WIDTH - ROW_WIDTH) / 2 + 96
    local barWidth = ROW_WIDTH - 96
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
    ui.accept:SetPoint("BOTTOMLEFT", 30, 14)
    ui.accept:SetScript("OnClick", function()
        if currentEngine then
            currentEngine:respond(true)
        end
        if current and current.missing ~= "" and current.leader == ns.selfName then
            ns.LfgList.search()
        end
    end)
    ui.decline = Widgets.button(frame, DECLINE or "Decline", 120)
    ui.decline:SetPoint("BOTTOMRIGHT", -30, 14)
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
