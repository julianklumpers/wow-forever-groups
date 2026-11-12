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

local function render(view)
    local styles = ns.Playstyle.describe(view.playstyles)
    ui.dungeon:SetText(ns.Quests.nameOf(view.dungeon) .. (styles and ("  |cffbbbbbb" .. styles .. "|r") or ""))
    local mine
    for _, member in ipairs(view.members) do
        if member.name == ns.selfName then
            mine = member.role
        end
    end
    ui.leader:SetText("Leader: " .. view.leader .. (mine and (".  You play " .. Widgets.ROLE_NAMES[mine] .. ".") or ""))
    for i, row in ipairs(rows) do
        local member = view.members[i]
        if member then
            Widgets.setRoleIcon(row.icon, member.role)
            local suffix = (member.name == ns.selfName and " (you)") or (member.fake and " (fake)") or ""
            local spec = ns.Spec.label(member.spec)
            row.name:SetText(member.name .. suffix .. (spec and ("  |cff999999" .. spec .. "|r") or ""))
            row.status:SetTexture(STATUS_TEXTURES[statusOf(member.answer)])
            row:Show()
        else
            row:Hide()
        end
    end
    if view.missing and view.missing ~= "" then
        local names = {}
        for letter in string.gmatch(view.missing, ".") do
            names[#names + 1] = Widgets.ROLE_NAMES[letter]
        end
        ui.missing:SetText("From the Group Finder: " .. table.concat(names, ", "))
    else
        ui.missing:SetText("")
    end
    local answered = myAnswer(view) == "Y"
    Widgets.setEnabled(ui.accept, not answered)
    Widgets.setEnabled(ui.decline, not answered)
    ui.waiting:SetShown(answered)
end

local function onUpdate()
    if not endTime then
        return
    end
    local left = math.max(0, endTime - GetTime())
    ui.bar:SetValue(left)
    ui.bar.text:SetText(string.format("%d s", math.ceil(left)))
end

local function build()
    frame = Widgets.window("ForeverGroupsProposalFrame", "Group found!", 320, 300, false)
    if type(frame.CloseButton) == "table" then
        frame.CloseButton:Hide()
    end
    frame:ClearAllPoints()
    frame:SetPoint("TOP", 0, -140)
    ui.dungeon = Widgets.text(frame, "GameFontNormalLarge", "CENTER")
    ui.dungeon:SetPoint("TOP", 0, -32)
    ui.dungeon:SetWidth(300)
    ui.leader = Widgets.text(frame, "GameFontHighlightSmall", "CENTER")
    ui.leader:SetPoint("TOP", 0, -56)
    for i = 1, 5 do
        local row = CreateFrame("Frame", nil, frame)
        row:SetSize(260, 22)
        row:SetPoint("TOPLEFT", 30, -76 - (i - 1) * 24)
        row.icon = Widgets.roleIcon(row, "D", 18)
        row.icon:SetPoint("LEFT", 0, 0)
        row.name = Widgets.text(row, "GameFontHighlight")
        row.name:SetPoint("LEFT", 26, 0)
        row.status = row:CreateTexture(nil, "ARTWORK")
        row.status:SetSize(18, 18)
        row.status:SetPoint("RIGHT", 0, 0)
        rows[i] = row
    end
    ui.bar = CreateFrame("StatusBar", nil, frame)
    ui.bar:SetSize(260, 12)
    ui.bar:SetPoint("BOTTOM", 0, 46)
    ui.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    ui.bar:SetStatusBarColor(1, 0.8, 0)
    ui.bar.text = Widgets.text(ui.bar, "GameFontHighlightSmall", "CENTER")
    ui.bar.text:SetPoint("CENTER")
    ui.missing = Widgets.text(frame, "GameFontNormalSmall", "CENTER")
    ui.missing:SetPoint("BOTTOM", 0, 80)
    ui.waiting = Widgets.text(frame, "GameFontNormalSmall", "CENTER")
    ui.waiting:SetPoint("BOTTOM", 0, 64)
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
