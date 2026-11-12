local _, ns = ...

local Widgets = ns.Widgets

-- A round button on the edge of the minimap: left-click opens the window,
-- right-click the settings, drag moves it around the minimap. While searching
-- it shows WoW's animated Looking For Group eye and a small role icon, and it
-- pulses while a group proposal waits for an answer.
local MinimapButton = {}

local ICON = ns.Widgets.ICON
local DEFAULT_ANGLE = 200
local EYE_SHEET = "Interface\\LFGFrame\\LFG-Eye"
local EYE_FRAMES, EYE_COLUMNS, EYE_ROWS = 29, 8, 4
local EYE_FRAME_TIME = 0.08

local button
local pulsing = false
local eye
local searching = false

local function position()
    local angle = math.rad(ns.db.minimapAngle or DEFAULT_ANGLE)
    local radius = (Minimap:GetWidth() or 140) / 2 + 6
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function followCursor()
    local centerX, centerY = Minimap:GetCenter()
    local cursorX, cursorY = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    if not centerX or not cursorX or not scale then
        return
    end
    local angle = math.deg(math.atan2(cursorY / scale - centerY, cursorX / scale - centerX))
    ns.db.minimapAngle = math.floor(angle + 0.5) % 360
    position()
end

local function showTooltip(self)
    if not GameTooltip then
        return
    end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Forever Groups")
    local status = ns.Status.current()
    if status then
        GameTooltip:AddLine(status.text, 1, 1, 1, true)
        if status.detail then
            GameTooltip:AddLine(status.detail, 0.8, 0.8, 0.8, true)
        end
    else
        GameTooltip:AddLine("Not in the queue.", 1, 1, 1)
    end
    local connection = ns.Comm.connection()
    GameTooltip:AddLine("Channel: " .. connection.text, 0.6, 0.8, 1)
    GameTooltip:AddLine("Left-click: open. Right-click: settings. Drag: move.", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local function showSheetFrame(texture, index)
    local column, row = index % EYE_COLUMNS, math.floor(index / EYE_COLUMNS)
    texture:SetTexCoord(column / EYE_COLUMNS, (column + 1) / EYE_COLUMNS, row / EYE_ROWS, (row + 1) / EYE_ROWS)
end

-- WoW's own animated eye (the one on the queue button) when this client has
-- its template; otherwise the eye picture sheet, animated here.
local function buildEye()
    local ok, frame = pcall(CreateFrame, "Frame", nil, button, "EyeTemplate")
    if ok and frame and type(frame.StartSearchingAnimation) == "function" then
        frame:SetSize(26, 26)
        frame:SetPoint("CENTER", button.icon, "CENTER")
        frame:Hide()
        ns.Log.debug("minimap eye: EyeTemplate")
        return { frame = frame, template = true }
    end
    if ok and frame then
        frame:Hide()
    end
    local texture = button:CreateTexture(nil, "ARTWORK", nil, 1)
    texture:SetTexture(EYE_SHEET)
    texture:SetSize(26, 26)
    texture:SetPoint("CENTER", button.icon, "CENTER")
    showSheetFrame(texture, 0)
    texture:Hide()
    ns.Log.debug("minimap eye: picture sheet")
    return { frame = texture, index = 0, elapsed = 0 }
end

local function setSearching(on)
    if on == searching then
        return
    end
    searching = on
    eye = eye or buildEye()
    eye.frame:SetShown(on)
    button.icon:SetShown(not on)
    if eye.template then
        if on then
            eye.frame:StartSearchingAnimation()
        elseif eye.frame.StopAnimating then
            eye.frame:StopAnimating()
        end
    end
end

local function onUpdate(self, elapsed)
    local shown = searching and eye and eye.frame or self.icon
    if pulsing then
        shown:SetAlpha(0.55 + 0.45 * math.abs(math.sin(GetTime() * 3)))
    end
    if searching and eye and not eye.template then
        eye.elapsed = eye.elapsed + (elapsed or 0)
        if eye.elapsed >= EYE_FRAME_TIME then
            eye.elapsed = 0
            eye.index = (eye.index + 1) % EYE_FRAMES
            showSheetFrame(eye.frame, eye.index)
        end
    end
end

local function build()
    button = CreateFrame("Button", "ForeverGroupsMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetSize(20, 20)
    background:SetPoint("TOPLEFT", 7, -5)
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetTexture(ICON)
    button.icon:SetSize(20, 20)
    button.icon:SetPoint("TOPLEFT", 7, -6)
    button.icon:SetTexCoord(0.06, 0.94, 0.06, 0.94)
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")
    button.badge = Widgets.roleIcon(button, "D", 13)
    button.badge:SetDrawLayer("OVERLAY", 2)
    button.badge:SetPoint("BOTTOMRIGHT", -2, 2)
    button.badge:Hide()
    button:SetScript("OnClick", function(_, mouseButton)
        if not ns.Input.run() then
            ns.Filler.searchIfUseful(30)
        end
        if mouseButton == "RightButton" then
            ns.Settings.toggle()
        else
            ns.Window.toggle()
        end
    end)
    button:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", followCursor)
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", onUpdate)
    end)
    button:SetScript("OnEnter", showTooltip)
    button:SetScript("OnLeave", function()
        if GameTooltip then
            GameTooltip:Hide()
        end
    end)
    button:SetScript("OnUpdate", onUpdate)
    position()
end

function MinimapButton.refresh()
    if not Minimap or not ns.db then
        return
    end
    if not button then
        build()
    end
    if ns.db.minimapHidden then
        button:Hide()
        return
    end
    button:Show()
    local status = ns.Status.current()
    local role = status and status.roles and string.sub(status.roles, 1, 1)
    if role and role ~= "" then
        Widgets.setRoleIcon(button.badge, role)
        button.badge:Show()
    else
        button.badge:Hide()
    end
    local engine = ns.engine
    setSearching((engine ~= nil and engine.myEntry ~= nil) or ns.Filler.isActive())
    pulsing = status ~= nil and status.alert == true
    if not pulsing then
        button.icon:SetAlpha(1)
        if eye then
            eye.frame:SetAlpha(1)
        end
    end
end

function MinimapButton.isSearching()
    return searching
end

function MinimapButton.toggle()
    ns.db.minimapHidden = not ns.db.minimapHidden
    MinimapButton.refresh()
    return not ns.db.minimapHidden
end

ns.MinimapButton = MinimapButton
