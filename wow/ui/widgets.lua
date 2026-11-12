local addonName, ns = ...

local Widgets = {}

Widgets.ROLE_NAMES = { T = "Tank", H = "Healer", D = "DPS" }
Widgets.ROLES = { "T", "H", "D" }

function Widgets.describeRoles(roles)
    local names = {}
    for _, role in ipairs(Widgets.ROLES) do
        if roles and string.find(roles, role, 1, true) then
            names[#names + 1] = Widgets.ROLE_NAMES[role]
        end
    end
    return table.concat(names, "/")
end

-- Adds or removes one role; returns nil when no role is left.
function Widgets.toggleRole(roles, role, on)
    local result = ""
    for _, r in ipairs(Widgets.ROLES) do
        local has = roles ~= nil and string.find(roles, r, 1, true) ~= nil
        if (r == role and on) or (r ~= role and has) then
            result = result .. r
        end
    end
    return result ~= "" and result or nil
end

local ROLE_TEXTURE = "Interface\\LFGFrame\\UI-LFG-ICON-ROLES"
local ROLE_COORDS = {
    T = { 0, 19 / 64, 22 / 64, 41 / 64 },
    H = { 20 / 64, 39 / 64, 1 / 64, 20 / 64 },
    D = { 20 / 64, 39 / 64, 22 / 64, 41 / 64 },
}
-- Role icon styles, best first; "sheet" is the classic round icons file.
Widgets.ROLE_STYLES = {
    { key = "large", label = "Flat", atlas = { T = "groupfinder-icon-role-large-tank",
        H = "groupfinder-icon-role-large-heal", D = "groupfinder-icon-role-large-dps" } },
    { key = "round", label = "Round (atlas)", atlas = { T = "UI-LFG-RoleIcon-Tank", H = "UI-LFG-RoleIcon-Healer",
        D = "UI-LFG-RoleIcon-DPS" } },
    { key = "sheet", label = "Round (classic file)" },
    { key = "tiny", label = "Tiny", atlas = { T = "roleicon-tiny-tank", H = "roleicon-tiny-healer",
        D = "roleicon-tiny-dps" } },
}
local WOW_ROLES = { T = "TANK", H = "HEALER", D = "DAMAGER" }
local shownIcons = setmetatable({}, { __mode = "k" })

local function atlasExists(atlas)
    return C_Texture ~= nil and C_Texture.GetAtlasInfo ~= nil and C_Texture.GetAtlasInfo(atlas) ~= nil
end

Widgets.atlasExists = atlasExists

function Widgets.roleStyleAvailable(style)
    return style.atlas == nil or atlasExists(style.atlas.T)
end

local function currentStyle()
    for _, style in ipairs(Widgets.ROLE_STYLES) do
        if style.key == (ns.db and ns.db.roleIcons) and Widgets.roleStyleAvailable(style) then
            return style
        end
    end
    for _, style in ipairs(Widgets.ROLE_STYLES) do
        if Widgets.roleStyleAvailable(style) then
            return style
        end
    end
end

function Widgets.paintRoleIcon(icon, role, style)
    if style.atlas then
        icon:SetAtlas(style.atlas[role])
        return
    end
    icon:SetTexture(ROLE_TEXTURE)
    if GetTexCoordsForRole then
        icon:SetTexCoord(GetTexCoordsForRole(WOW_ROLES[role]))
    else
        icon:SetTexCoord(unpack(ROLE_COORDS[role]))
    end
end

function Widgets.setRoleIcon(icon, role)
    shownIcons[icon] = role
    Widgets.paintRoleIcon(icon, role, currentStyle())
end

function Widgets.roleStyleKey()
    return currentStyle().key
end

function Widgets.setRoleStyle(key)
    ns.db.roleIcons = key
    for icon, role in pairs(shownIcons) do
        Widgets.paintRoleIcon(icon, role, currentStyle())
    end
end

function Widgets.roleIcon(parent, role, size)
    local icon = parent:CreateTexture(nil, "ARTWORK")
    icon:SetSize(size, size)
    Widgets.setRoleIcon(icon, role)
    return icon
end

-- Falls back to a plain dark frame if the template is missing in this client.
-- escapable = false keeps Escape from closing it. The window is held by its
-- top edge, also after dragging, so a change in height never moves its top.
-- Which frame each window got ("gold" or "plain"), for /fg selftest.
Widgets.frameStyles = {}

-- A small round icon at the left of the title bar, on a frame above the
-- template's border so the border does not cover it.
-- The addon's own icon (media/icon.tga: round, the party in a gold ring).
Widgets.ICON = "Interface\\AddOns\\" .. tostring(addonName) .. "\\media\\icon"

function Widgets.roundIcon(parent, icon, size)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(size, size)
    local texture = holder:CreateTexture(nil, "ARTWORK")
    texture:SetAllPoints()
    texture:SetTexture(icon)
    local mask = type(holder.CreateMaskTexture) == "function" and holder:CreateMaskTexture()
    if type(mask) == "table" then
        mask:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE",
            "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(texture)
        texture:AddMaskTexture(mask)
    end
    return holder
end

local function addTitleIcon(frame, icon)
    local holder = Widgets.roundIcon(frame, icon, 18)
    holder:SetPoint("TOPLEFT", 8, -3)
    local level = frame:GetFrameLevel()
    if type(level) == "number" then
        holder:SetFrameLevel(level + 10)
    end
    frame.icon = holder
end

-- plain: the dark frame with a slim title bar (for small windows); otherwise
-- WoW's panel frame with the gold metal border, like most Blizzard windows
-- (without its big portrait). icon: a small round icon in the title bar.
function Widgets.window(name, title, width, height, escapable, plain, icon)
    local ok, frame, gold = false, nil, false
    if not plain then
        ok, frame = pcall(CreateFrame, "Frame", name, UIParent, "ButtonFrameTemplate")
        gold = ok and frame ~= nil
        if gold then
            for _, hide in ipairs({ "ButtonFrameTemplate_HideButtonBar", "ButtonFrameTemplate_HidePortrait" }) do
                if type(_G[hide]) == "function" then
                    pcall(_G[hide], frame)
                end
            end
        end
    end
    if not gold then
        ok, frame = pcall(CreateFrame, "Frame", name, UIParent, "BasicFrameTemplateWithInset")
    end
    Widgets.frameStyles[name] = gold and "gold" or "plain"
    if ns.Log then
        ns.Log.debug("window %s: %s", tostring(name), gold and "gold panel frame" or "plain frame")
    end
    if not ok or not frame then
        frame = CreateFrame("Frame", name, UIParent)
        local background = frame:CreateTexture(nil, "BACKGROUND")
        background:SetAllPoints()
        background:SetColorTexture(0.05, 0.05, 0.08, 0.92)
        local closeOk, close = pcall(CreateFrame, "Button", nil, frame, "UIPanelCloseButton")
        if closeOk and close then
            close:SetPoint("TOPRIGHT", 0, 0)
            frame.CloseButton = close
        end
    end
    -- The template's button closes through HideUIPanel, which WoW refuses in
    -- combat for an addon frame; Escape and this hide the frame directly.
    if frame.CloseButton then
        frame.CloseButton:SetScript("OnClick", function()
            frame:Hide()
        end)
    end
    if icon then
        addTitleIcon(frame, icon)
    end
    frame:SetSize(width, height)
    frame:SetPoint("TOP", UIParent, "TOP", 0, -120)
    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local left, top = self:GetLeft(), self:GetTop()
        if left and top then
            self:ClearAllPoints()
            self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        end
    end)
    local container = type(frame.TitleContainer) == "table" and frame.TitleContainer or frame
    local templateTitle = gold and type(container.TitleText) == "table" and container.TitleText or nil
    if templateTitle then
        templateTitle:SetText(title)
        frame.title = templateTitle
    else
        local titleText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        titleText:SetPoint("TOP", 0, -5)
        titleText:SetText(title)
        frame.title = titleText
    end
    frame:Hide()
    if UISpecialFrames and escapable ~= false then
        table.insert(UISpecialFrames, name)
    end
    return frame
end

function Widgets.text(parent, font, justify)
    local text = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    text:SetJustifyH(justify or "LEFT")
    return text
end

function Widgets.button(parent, label, width)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width or 100, 22)
    button:SetText(label)
    return button
end

-- Stretches a check box's click area over its label (and an optional second
-- text after it), and no further.
function Widgets.fitClickArea(check, extra)
    local width = (check.label:GetStringWidth() or 0) + 3
    if extra and extra:IsShown() and (extra:GetText() or "") ~= "" then
        width = width + 6 + (extra:GetStringWidth() or 0)
    end
    check:SetHitRectInsets(0, -math.ceil(width), 0, 0)
end

function Widgets.check(parent, label, onClick)
    local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    check:SetSize(22, 22)
    local text = check:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", check, "RIGHT", 1, 0)
    text:SetText(label or "")
    check.label = text
    Widgets.fitClickArea(check)
    if onClick then
        check:SetScript("OnClick", onClick)
    end
    check:SetScript("OnEnter", function(self)
        if self.reason and GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.reason)
            GameTooltip:Show()
        end
    end)
    check:SetScript("OnLeave", function()
        if GameTooltip then
            GameTooltip:Hide()
        end
    end)
    return check
end

-- A tooltip like WoW's own: a short gold title and the explanation in white,
-- wrapped to the tooltip's normal width.
function Widgets.tooltip(frame, title, text)
    frame:SetScript("OnEnter", function(self)
        if GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(title, 1, 0.82, 0)
            if text then
                GameTooltip:AddLine(text, 1, 1, 1, true)
            end
            GameTooltip:Show()
        end
    end)
    frame:SetScript("OnLeave", function()
        if GameTooltip then
            GameTooltip:Hide()
        end
    end)
end

function Widgets.setEnabled(widget, enabled)
    if enabled then
        widget:Enable()
    else
        widget:Disable()
    end
    if widget.label then
        widget.label:SetAlpha(enabled and 1 or 0.5)
    end
end

function Widgets.classColor(classToken)
    local color = RAID_CLASS_COLORS and classToken and RAID_CLASS_COLORS[classToken]
    if color then
        return color.r, color.g, color.b
    end
    return 1, 1, 1
end

-- Like WoW's quest colours: green when the level fits, orange/red when the
-- dungeon is above the player, grey when below.
function Widgets.levelColor(level, min, max)
    if not min or not max then
        return 0.8, 0.8, 0.8
    end
    if level < min - 2 then
        return 1, 0.25, 0.25
    elseif level < min then
        return 1, 0.55, 0.15
    elseif level > max then
        return 0.6, 0.6, 0.6
    end
    return 0.35, 1, 0.35
end

-- A gold section title with a thin line under it.
function Widgets.header(parent, text, right)
    local label = Widgets.text(parent, "GameFontNormal")
    label:SetText(text)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetColorTexture(1, 0.82, 0, 0.25)
    line:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -3)
    line:SetPoint("RIGHT", parent, "RIGHT", -(right or 16), 0)
    label.line = line
    return label
end

-- A role choice drawn like WoW's own role buttons: the icon is bright with a
-- check mark when chosen and grey when not.
function Widgets.roleToggle(parent, role, size, font, onClick)
    local toggle = CreateFrame("CheckButton", nil, parent)
    toggle:SetSize(size + 96, size + 6)
    toggle.role = role
    toggle.icon = toggle:CreateTexture(nil, "ARTWORK")
    toggle.icon:SetSize(size, size)
    toggle.icon:SetPoint("LEFT", 2, 0)
    Widgets.setRoleIcon(toggle.icon, role)
    toggle.mark = toggle:CreateTexture(nil, "OVERLAY")
    toggle.mark:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    toggle.mark:SetSize(size * 0.6, size * 0.6)
    toggle.mark:SetPoint("CENTER", toggle.icon, "BOTTOMRIGHT", 0, size * 0.1)
    toggle.label = toggle:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    toggle.label:SetPoint("LEFT", toggle.icon, "RIGHT", size * 0.35 + 6, 0)
    toggle.label:SetText(Widgets.ROLE_NAMES[role])
    toggle:SetWidth(size + size * 0.35 + 10 + math.ceil(toggle.label:GetStringWidth() or 60))
    toggle:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    toggle:SetScript("OnClick", onClick)
    toggle:SetScript("OnEnter", function(self)
        if self.reason and GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.reason)
            GameTooltip:Show()
        end
    end)
    toggle:SetScript("OnLeave", function()
        if GameTooltip then
            GameTooltip:Hide()
        end
    end)
    return toggle
end

function Widgets.paintToggle(toggle, checked, enabled)
    toggle:SetChecked(checked)
    Widgets.setEnabled(toggle, enabled)
    toggle.icon:SetDesaturated(not checked)
    toggle.icon:SetAlpha(not enabled and 0.2 or (checked and 1 or 0.5))
    toggle.mark:SetShown(checked and true or false)
    if checked then
        toggle.label:SetTextColor(1, 0.82, 0)
    else
        toggle.label:SetTextColor(0.65, 0.65, 0.65)
    end
end

local ROLE_COLORS = { T = { 0.25, 0.5, 1 }, H = { 0.25, 0.9, 0.45 }, D = { 1, 0.3, 0.25 } }

-- A role tile for choosing roles. Not chosen still looks available (full
-- colour, light border); only a role the class cannot play is greyed out.
-- The tooltip border: rounded corners, tinted per state.
local ROUNDED = {
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 14,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

-- Gives a frame (made with "BackdropTemplate") a rounded outline and fill;
-- without backdrops, a plain fill and four (three with openBottom) lines.
local function addOutline(frame, openBottom)
    if type(frame.SetBackdrop) == "function" and pcall(frame.SetBackdrop, frame, ROUNDED) then
        frame.rounded = true
        return
    end
    frame.background = frame:CreateTexture(nil, "BACKGROUND")
    frame.background:SetAllPoints()
    frame.border = {}
    local sides = { { "TOPLEFT", "TOPRIGHT", true }, { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }
    if not openBottom then
        sides[#sides + 1] = { "BOTTOMLEFT", "BOTTOMRIGHT", true }
    end
    for i, side in ipairs(sides) do
        local line = frame:CreateTexture(nil, "BORDER")
        line:SetPoint(side[1])
        line:SetPoint(side[2])
        if side[3] then
            line:SetHeight(1)
        else
            line:SetWidth(1)
        end
        frame.border[i] = line
    end
end

local function paintOutline(frame, background, border)
    if frame.rounded then
        frame:SetBackdropColor(background[1], background[2], background[3], background[4])
        frame:SetBackdropBorderColor(border[1], border[2], border[3], border[4])
        return
    end
    frame.background:SetColorTexture(background[1], background[2], background[3], background[4])
    for _, line in ipairs(frame.border) do
        line:SetColorTexture(border[1], border[2], border[3], border[4])
    end
end

local function backdropFrame(kind, parent)
    local ok, frame = pcall(CreateFrame, kind, nil, parent, "BackdropTemplate")
    if ok and frame then
        return frame
    end
    return CreateFrame(kind, nil, parent)
end

function Widgets.roleTile(parent, role, width, onClick)
    local tile = backdropFrame("CheckButton", parent)
    tile:SetSize(width, 76)
    tile.role = role
    addOutline(tile)
    local hover = tile:CreateTexture(nil, "HIGHLIGHT")
    hover:SetPoint("TOPLEFT", 4, -4)
    hover:SetPoint("BOTTOMRIGHT", -4, 4)
    hover:SetColorTexture(1, 1, 1, 0.07)
    tile.icon = Widgets.roleIcon(tile, role, 40)
    tile.icon:SetPoint("TOP", 0, -8)
    tile.box = tile:CreateTexture(nil, "ARTWORK")
    tile.box:SetTexture("Interface\\Buttons\\UI-CheckBox-Up")
    tile.box:SetSize(24, 24)
    tile.box:SetPoint("TOPRIGHT", -4, -4)
    tile.mark = tile:CreateTexture(nil, "OVERLAY")
    tile.mark:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    tile.mark:SetAllPoints(tile.box)
    tile.label = Widgets.text(tile, "GameFontHighlight", "CENTER")
    tile.label:SetPoint("BOTTOM", 0, 8)
    tile.label:SetText(Widgets.ROLE_NAMES[role])
    tile:SetScript("OnClick", onClick)
    tile:SetScript("OnEnter", function(self)
        if GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(Widgets.ROLE_NAMES[role], 1, 0.82, 0)
            GameTooltip:AddLine(self.reason or "Tick every role you can play; Forever Groups picks the one a group "
                .. "needs most.", 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    tile:SetScript("OnLeave", function()
        if GameTooltip then
            GameTooltip:Hide()
        end
    end)
    return tile
end

function Widgets.paintTile(tile, checked, enabled)
    tile:SetChecked(checked and enabled)
    if enabled then
        tile:Enable()
    else
        tile:Disable()
    end
    local color = ROLE_COLORS[tile.role]
    local background, borderColor
    if not enabled then
        background = { 0, 0, 0, 0.3 }
        borderColor = { 1, 1, 1, 0.12 }
        tile.icon:SetDesaturated(true)
        tile.icon:SetAlpha(0.35)
        tile.label:SetTextColor(0.45, 0.45, 0.45)
    elseif checked then
        background = { color[1], color[2], color[3], 0.22 }
        borderColor = { 1, 0.82, 0, 1 }
        tile.icon:SetDesaturated(false)
        tile.icon:SetAlpha(1)
        tile.label:SetTextColor(1, 1, 1)
    else
        background = { 1, 1, 1, 0.04 }
        borderColor = { 1, 1, 1, 0.35 }
        tile.icon:SetDesaturated(false)
        tile.icon:SetAlpha(1)
        tile.label:SetTextColor(0.9, 0.9, 0.9)
    end
    paintOutline(tile, background, borderColor)
    tile.mark:SetShown(checked and enabled and true or false)
    tile.box:SetDesaturated(not enabled)
    tile.box:SetAlpha(enabled and 1 or 0.35)
end

-- One option of a row where exactly one is chosen, drawn like a small tile.
function Widgets.choice(parent, label, width, onClick)
    local choice = backdropFrame("CheckButton", parent)
    choice:SetSize(width, 28)
    addOutline(choice)
    local hover = choice:CreateTexture(nil, "HIGHLIGHT")
    hover:SetPoint("TOPLEFT", 4, -4)
    hover:SetPoint("BOTTOMRIGHT", -4, 4)
    hover:SetColorTexture(1, 1, 1, 0.07)
    choice.label = Widgets.text(choice, "GameFontHighlightSmall", "CENTER")
    choice.label:SetPoint("LEFT", 4, 0)
    choice.label:SetPoint("RIGHT", -4, 0)
    choice.label:SetWordWrap(false)
    choice.label:SetText(label)
    choice:SetScript("OnClick", onClick)
    return choice
end

function Widgets.paintChoice(choice, chosen)
    choice:SetChecked(chosen and true or false)
    if chosen then
        paintOutline(choice, { 1, 0.82, 0, 0.16 }, { 1, 0.82, 0, 1 })
        choice.label:SetTextColor(1, 1, 1)
    else
        paintOutline(choice, { 1, 1, 1, 0.04 }, { 1, 1, 1, 0.35 })
        choice.label:SetTextColor(0.75, 0.75, 0.75)
    end
end

-- A small round status dot: WoW's white circle mask, coloured per state.
function Widgets.dot(parent, size)
    local dot = parent:CreateTexture(nil, "ARTWORK")
    dot:SetSize(size or 9, size or 9)
    dot:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
    return dot
end

function Widgets.paintDot(dot, color)
    dot:SetVertexColor(color[1], color[2], color[3], 1)
end

-- A tab of a tab row: the chosen one is drawn as a folder tab (a frame on
-- the top and sides, open at the bottom), the others as plain text.
-- The chosen tab's outline: 1 px lines on its top and sides, exactly on its
-- edges so the tab row's base line meets them, with small round corners
-- (two pixels each) and an open bottom.
-- Each piece: { anchor, x, y [, anchor2, x2, y2] } with a 1 px size; the
-- lines run between two anchors, the corner pixels sit at one.
local TAB_OUTLINE = {
    { "TOPLEFT", 3, 0, "TOPRIGHT", -3, 0 },
    { "TOPLEFT", 0, -3, "BOTTOMLEFT", 0, 0 },
    { "TOPRIGHT", 0, -3, "BOTTOMRIGHT", 0, 0 },
    { "TOPLEFT", 1, -2 },
    { "TOPLEFT", 2, -1 },
    { "TOPRIGHT", -1, -2 },
    { "TOPRIGHT", -2, -1 },
}

function Widgets.tab(parent, label, width, onClick)
    local tab = CreateFrame("Button", nil, parent)
    tab:SetSize(width, 28)
    tab.fill = tab:CreateTexture(nil, "BACKGROUND")
    tab.fill:SetPoint("TOPLEFT", 1, -1)
    tab.fill:SetPoint("BOTTOMRIGHT", -1, 0)
    tab.outline = {}
    for i, piece in ipairs(TAB_OUTLINE) do
        local line = tab:CreateTexture(nil, "BORDER")
        line:SetSize(1, 1)
        line:SetPoint(piece[1], tab, piece[1], piece[2], piece[3])
        if piece[4] then
            line:SetPoint(piece[4], tab, piece[4], piece[5], piece[6])
        end
        tab.outline[i] = line
    end
    local text = tab:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("CENTER", 0, -1)
    tab:SetFontString(text)
    tab:SetText(label)
    tab.label = text
    tab.dot = Widgets.dot(tab)
    tab.dot:SetPoint("LEFT", text, "RIGHT", 7, 0)
    tab.status = Widgets.text(tab, "GameFontHighlightSmall")
    tab.status:SetPoint("LEFT", tab.dot, "RIGHT", 4, 0)
    Widgets.setTabStatus(tab, nil)
    tab:SetScript("OnClick", onClick)
    tab:SetScript("OnEnter", function(self)
        self.hovered = true
        Widgets.paintTab(self, self.chosen)
    end)
    tab:SetScript("OnLeave", function(self)
        self.hovered = false
        Widgets.paintTab(self, self.chosen)
    end)
    return tab
end

local TAB_STATUS_COLORS = { queued = { 1, 0.82, 0 }, found = { 0.3, 1, 0.3 }, paused = { 0.6, 0.6, 0.6 } }

-- kind: "queued", "found", "paused" or nil (nothing going on); text: a
-- short status next to the dot ("2:15", "!").
function Widgets.setTabStatus(tab, kind, text)
    local color = TAB_STATUS_COLORS[kind]
    tab.statusKind = kind
    tab.dot:SetShown(color ~= nil)
    tab.status:SetShown(color ~= nil)
    if color then
        Widgets.paintDot(tab.dot, color)
        tab.status:SetText(text or "")
        tab.status:SetTextColor(color[1], color[2], color[3])
    end
    local width = color and (8 + 7 + 4 + math.ceil(tab.status:GetStringWidth() or 0)) or 0
    tab.label:ClearAllPoints()
    tab.label:SetPoint("CENTER", -math.floor(width / 2), -1)
end

-- The chosen tab has a gold outline; a tab under the mouse shows the same
-- outline in light grey, so it reads as a tab you can open.
function Widgets.paintTab(tab, chosen)
    tab.chosen = chosen
    local shown = chosen or tab.hovered == true
    tab.fill:SetColorTexture(1, 1, 1, chosen and 0.06 or 0.03)
    tab.fill:SetShown(shown)
    for _, line in ipairs(tab.outline) do
        if chosen then
            line:SetColorTexture(1, 0.82, 0, 0.6)
        else
            line:SetColorTexture(1, 1, 1, 0.3)
        end
        line:SetShown(shown)
    end
    if chosen then
        tab.label:SetTextColor(1, 0.82, 0)
    elseif tab.hovered then
        tab.label:SetTextColor(0.95, 0.95, 0.95)
    else
        tab.label:SetTextColor(0.6, 0.6, 0.6)
    end
end

-- A section toggle: WoW's plus/minus button, a label, a grey count and a
-- thin line to the right edge, so it reads as the start of a section.
function Widgets.expander(parent, label, width, onClick)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(width, 20)
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetSize(14, 14)
    button.icon:SetPoint("LEFT", 0, 0)
    local text = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("LEFT", button.icon, "RIGHT", 6, 0)
    button:SetFontString(text)
    button:SetText(label)
    button.label = text
    button.count = Widgets.text(button, "GameFontDisableSmall")
    button.count:SetPoint("LEFT", text, "RIGHT", 6, 0)
    button.line = button:CreateTexture(nil, "ARTWORK")
    button.line:SetHeight(1)
    button.line:SetPoint("LEFT", button.count, "RIGHT", 8, 0)
    button.line:SetPoint("RIGHT", button, "RIGHT", 0, 0)
    button.line:SetColorTexture(1, 0.82, 0, 0.25)
    button:SetScript("OnClick", onClick)
    button:SetScript("OnEnter", function(self)
        self.label:SetTextColor(1, 1, 1)
    end)
    button:SetScript("OnLeave", function(self)
        self.label:SetTextColor(1, 0.82, 0)
    end)
    return button
end

function Widgets.paintExpander(button, open, countText)
    button.open = open
    button.icon:SetTexture(open and "Interface\\Buttons\\UI-MinusButton-Up" or "Interface\\Buttons\\UI-PlusButton-Up")
    button.count:SetText(countText or "")
end

-- A small gold text link, white on hover; the click area is the text.
function Widgets.link(parent, label, onClick)
    local link = CreateFrame("Button", nil, parent)
    local text = link:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    link:SetFontString(text)
    link.label = text
    link:SetNormalFontObject(GameFontNormalSmall)
    link:SetHighlightFontObject(GameFontHighlightSmall)
    link:SetText(label)
    link:SetSize(math.ceil(text:GetStringWidth() or 40) + 2, 16)
    link:SetScript("OnClick", onClick)
    return link
end

-- Three role icons with a number each: { T = n, H = n, D = n }, or a dash
-- for each while the numbers are not known yet.
function Widgets.roleCounts(parent, size)
    local counts = CreateFrame("Frame", nil, parent)
    counts:SetSize(3 * (size + 32) - 8, size)
    counts.icons, counts.texts = {}, {}
    for i, role in ipairs(Widgets.ROLES) do
        local icon = Widgets.roleIcon(counts, role, size)
        icon:SetPoint("LEFT", (i - 1) * (size + 32), 0)
        local text = Widgets.text(counts, "GameFontHighlightSmall")
        text:SetPoint("LEFT", icon, "RIGHT", 4, 0)
        counts.icons[role], counts.texts[role] = icon, text
    end
    return counts
end

function Widgets.setRoleCounts(counts, values)
    for _, role in ipairs(Widgets.ROLES) do
        local n = values and values[role] or 0
        counts.texts[role]:SetText(values and tostring(n) or "-")
        counts.texts[role]:SetTextColor(n > 0 and 1 or 0.5, n > 0 and 1 or 0.5, n > 0 and 1 or 0.5)
        counts.icons[role]:SetAlpha(n > 0 and 1 or 0.4)
    end
end

-- One place in the group: role icon with the player's name in class colour,
-- or a dim icon with "open".
function Widgets.slot(parent)
    local slot = CreateFrame("Frame", nil, parent)
    slot:SetSize(100, 50)
    local background = slot:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(1, 1, 1, 0.05)
    slot.icon = Widgets.roleIcon(slot, "D", 20)
    slot.icon:SetPoint("TOP", 0, -4)
    slot.name = Widgets.text(slot, "GameFontHighlightSmall", "CENTER")
    slot.name:SetPoint("TOP", slot.icon, "BOTTOM", 0, -3)
    slot.name:SetWidth(94)
    if slot.name.SetMaxLines then
        pcall(slot.name.SetMaxLines, slot.name, 2)
    end
    slot.spec = Widgets.text(slot, "GameFontHighlightSmall", "CENTER")
    slot.spec:SetWidth(94)
    slot.distance = Widgets.text(slot, "GameFontDisableSmall", "CENTER")
    slot.distanceDot = Widgets.dot(slot, 7)
    slot.distanceDot:SetPoint("RIGHT", slot.distance, "LEFT", -3, 0)
    slot.quests = Widgets.text(slot, "GameFontDisableSmall", "CENTER")
    slot.quests:SetWidth(94)
    return slot
end

local NEAR = 1000
local DISTANCE_COLORS = { here = { 0.3, 1, 0.3 }, near = { 1, 0.82, 0 }, far = { 0.55, 0.55, 0.55 } }

-- "inside", "at entrance", "620 yd", "far away" or "unknown", and the dot's
-- colour.
local function describeDistance(yards)
    if yards == "in" then
        return "inside", DISTANCE_COLORS.here
    elseif yards == "?" then
        return "unknown", DISTANCE_COLORS.far
    elseif yards == "none" then
        return "", DISTANCE_COLORS.far
    elseif yards == false or yards == nil then
        return "far away", DISTANCE_COLORS.far
    elseif yards <= 40 then
        return "at entrance", DISTANCE_COLORS.here
    elseif yards < NEAR then
        return string.format("%d yd", math.floor(yards / 10 + 0.5) * 10), DISTANCE_COLORS.near
    end
    return string.format("%.1fk yd", yards / 1000), DISTANCE_COLORS.far
end

-- data: { role, name, classToken, spec, distance (yards, "in" = inside,
-- false = far away, "?" = unknown, "none" = left empty),
-- quests (a count, or "?") }; layout: which lines the row of slots shows
-- ({ spec, distance, quests } true/false), so every slot has the same lines
-- in the same place. Returns the slot's height.
function Widgets.paintSlot(slot, data, layout)
    Widgets.setRoleIcon(slot.icon, data.role)
    if data.name then
        slot.icon:SetAlpha(1)
        slot.name:SetText(data.name)
        slot.name:SetTextColor(Widgets.classColor(data.classToken))
    else
        slot.icon:SetAlpha(0.3)
        slot.name:SetText("open")
        slot.name:SetTextColor(0.5, 0.5, 0.5)
    end
    local y = -54
    local function line(widget, shown, text)
        widget:SetShown(shown)
        if shown then
            widget:ClearAllPoints()
            widget:SetPoint("TOP", slot, "TOP", widget == slot.distance and 5 or 0, y)
            widget:SetText(text or "")
            y = y - 13
        end
    end
    line(slot.spec, layout.spec, data.spec)
    local text, color = describeDistance(data.distance)
    local showDistance = layout.distance and data.name ~= nil and data.distance ~= "none"
    line(slot.distance, layout.distance, showDistance and text or "")
    slot.distanceDot:SetShown(showDistance)
    if showDistance then
        slot.distance:SetTextColor(color[1], color[2], color[3])
        Widgets.paintDot(slot.distanceDot, color)
    end
    local quests = data.quests
    local questText
    if not data.name or quests == nil then
        questText = ""
    elseif quests == "none" then
        questText = "no addon"
    elseif quests == "?" then
        questText = "?"
    else
        questText = string.format("%d quest%s", quests, quests == 1 and "" or "s")
    end
    line(slot.quests, layout.quests, questText)
    local height = -y + 4
    slot:SetHeight(height)
    return height
end

function Widgets.formatTime(seconds)
    seconds = math.max(0, math.floor(seconds))
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

ns.Widgets = Widgets
