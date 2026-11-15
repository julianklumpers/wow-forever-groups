local _, ns = ...

local L = ns.L

local W = ns.WindowParts
local Widgets = ns.Widgets

-- One card for a place in a group, wherever the window shows the group's
-- five places: the class choices of "Choose the classes in my party"
-- (compose.lua) and the group's places while searching and in a group
-- (card.lua). In the window's quiet style: a thin rounded edge, the role
-- small in the top-left corner; a member's spec art (or dimmed class emblem)
-- fills the card, with their class icon and name and their spec under it at
-- the bottom; an invited player is dimmed with the time left; an open place
-- has a dashed edge, or a gold edge with the icons of the classes wished
-- for it (by name in their class colour, two and "+n more", on a client
-- without the icons). In a group, lines for the distance to the entrance
-- and the dungeon quests come in a row under it (where left, quests right).
-- Every card has the same height, room for that row included, in each view.
W.PLACE_HEIGHT = 102
local SPEC_GAP = 15
local BOTTOM_INSET = 9
local SIDE_INSET = 8
-- Name and spec (12 px and a line under it) in the middle of the card.
local NAME_TOP = math.floor((W.PLACE_HEIGHT - (12 + SPEC_GAP)) / 2)
local NAME_LINES = 2
local ROLE_ICON = 20
local ICON_GAP = 3
local NAME_ICON, NAME_ICON_GAP = 14, 2
local DASH, DASH_GAP = 4, 4
-- The cards draw their own edge, a thin line with rounded corners: the
-- rounded tooltip border shows its soft outer edge only when bright, so a gold
-- card looked bigger than a grey or dashed one.
local ROUNDED_INSET, RADIUS = 3, 5
local TEXT_INSET = ROUNDED_INSET + 3
local ROUND_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

-- Where the dashes go between from and to, centred so both ends look alike.
local function dashesBetween(from, to)
    local step = DASH + DASH_GAP
    local count = math.max(0, math.floor((to - from + DASH_GAP) / step))
    local first = from + math.floor((to - from - (count * step - DASH_GAP)) / 2)
    local list = {}
    for i = 0, count - 1 do
        list[#list + 1] = first + i * step
    end
    return list
end

-- The card's edge, solid or dashed, in one colour; rounded like the other
-- rounded frames when the card has their fill.
local function paintEdge(card, color, dashed)
    card.edge, card.dashed = card.edge or {}, dashed == true
    for _, piece in ipairs(card.edge) do
        piece:Hide()
    end
    local inset = card.rounded and ROUNDED_INSET or 0
    local radius = card.rounded and RADIUS or 0
    local width, height = card.placeWidth, card.placeHeight
    local used = 0
    local function piece(x, y, w, h)
        used = used + 1
        local texture = card.edge[used]
        if not texture then
            texture = card:CreateTexture(nil, "BORDER")
            card.edge[used] = texture
        end
        texture:SetColorTexture(color[1], color[2], color[3], color[4])
        texture:ClearAllPoints()
        texture:SetPoint("TOPLEFT", card, "TOPLEFT", x, -y)
        texture:SetSize(w, h)
        texture:Show()
    end
    local left, right = inset, width - inset - 1
    local top, bottom = inset, height - inset - 1
    if radius > 0 then
        local seen = {}
        for i = 0, radius * 2 do
            local angle = (i / (radius * 2)) * math.pi / 2
            local dx = math.floor(radius - radius * math.cos(angle) + 0.5)
            local dy = math.floor(radius - radius * math.sin(angle) + 0.5)
            local key = dx * 100 + dy
            if not seen[key] then
                seen[key] = true
                piece(left + dx, top + dy, 1, 1)
                piece(right - dx, top + dy, 1, 1)
                piece(left + dx, bottom - dy, 1, 1)
                piece(right - dx, bottom - dy, 1, 1)
            end
        end
    end
    if not dashed then
        local across, down = right - left - 2 * radius - 1, bottom - top - 2 * radius - 1
        piece(left + radius + 1, top, across, 1)
        piece(left + radius + 1, bottom, across, 1)
        piece(left, top + radius + 1, 1, down)
        piece(right, top + radius + 1, 1, down)
        return
    end
    local gap = radius > 0 and DASH_GAP or 0
    for _, x in ipairs(dashesBetween(left + radius + gap, right - radius - gap + 1)) do
        piece(x, top, DASH, 1)
        piece(x, bottom, DASH, 1)
    end
    local away = radius > 0 and radius + gap or DASH + DASH_GAP
    for _, y in ipairs(dashesBetween(top + away, bottom - away + 1)) do
        piece(left, y, 1, DASH)
        piece(right, y, 1, DASH)
    end
end

local function iconAtlas(class)
    return "classicon-" .. string.lower(class)
end

-- The class icons are square; a round mask makes them round where the
-- client has masks.
local function classIcon(card, i)
    local icon = card.classIcons[i]
    if not icon then
        icon = card:CreateTexture(nil, "ARTWORK")
        if type(card.CreateMaskTexture) == "function" then
            local ok, mask = pcall(card.CreateMaskTexture, card)
            if ok and mask and pcall(mask.SetTexture, mask, ROUND_MASK, "CLAMPTOBLACKADDITIVE",
                "CLAMPTOBLACKADDITIVE") then
                mask:SetAllPoints(icon)
                icon:AddMaskTexture(mask)
            end
        end
        card.classIcons[i] = icon
    end
    return icon
end

-- The wished classes' icons as a grid in the middle of the card: one row up
-- to three, two by two for four, then rows of three.
local function placeClassIcons(card, classes)
    local count = #classes
    local columns = count <= 3 and count or (count == 4 and 2 or 3)
    local size = 20
    local rows = math.ceil(count / columns)
    local top = math.floor((card.placeHeight - (rows * size + (rows - 1) * ICON_GAP)) / 2)
    for i, class in ipairs(classes) do
        local row, column = math.floor((i - 1) / columns), (i - 1) % columns
        local inRow = math.min(columns, count - row * columns)
        local left = math.floor((card.placeWidth - (inRow * size + (inRow - 1) * ICON_GAP)) / 2)
        local icon = classIcon(card, i)
        icon:SetAtlas(iconAtlas(class))
        icon:SetSize(size, size)
        icon:ClearAllPoints()
        icon:SetPoint("TOPLEFT", card, "TOPLEFT", left + column * (size + ICON_GAP), -(top + row * (size + ICON_GAP)))
        icon:Show()
    end
end

-- A line of small text across the card, centred; cut off with "..." when
-- too long.
local function placeLine(card, line, top)
    line:SetFontObject("GameFontHighlightSmall")
    if line.shrunk then
        line:SetFont(line.shrunk[1], line.shrunk[2], line.shrunk[3])
        line.shrunk = nil
    end
    line:SetWordWrap(false)
    line:SetJustifyH("CENTER")
    line:SetWidth(card.placeWidth - 2 * TEXT_INSET)
    line:ClearAllPoints()
    line:SetPoint("TOP", card, "TOP", 0, -top)
end

-- The name on one line in the small font, the class's round icon (atlas;
-- nil for none) right before it, the two centred together.
local function placeName(card, atlas, top)
    local line = card.lines[1]
    placeLine(card, line, top)
    if not atlas then
        if card.nameIcon then
            card.nameIcon:Hide()
        end
        return
    end
    if not card.nameIcon then
        card.nameIcon = classIcon(card, "name")
    end
    local room = card.placeWidth - 2 * TEXT_INSET - NAME_ICON - NAME_ICON_GAP
    local text = math.min(math.ceil(line:GetStringWidth() or room), room)
    local left = math.floor((card.placeWidth - (text + NAME_ICON + NAME_ICON_GAP)) / 2)
    line:SetJustifyH("LEFT")
    line:SetWidth(text + 1)
    line:ClearAllPoints()
    line:SetPoint("TOPLEFT", card, "TOPLEFT", left + NAME_ICON + NAME_ICON_GAP, -top)
    card.nameIcon:SetAtlas(atlas)
    card.nameIcon:SetSize(NAME_ICON, NAME_ICON)
    card.nameIcon:ClearAllPoints()
    card.nameIcon:SetPoint("TOPLEFT", card, "TOPLEFT", left, -(top - 2))
    card.nameIcon:Show()
end

-- Adds a place card's parts to a frame made with Widgets.backdropFrame (or
-- the BackdropTemplate).
function W.addPlaceParts(card)
    card:SetHeight(W.PLACE_HEIGHT)
    Widgets.addOutline(card)
    Widgets.addArt(card)
    card.lines = {}
    for i = 1, NAME_LINES do
        card.lines[i] = Widgets.text(card, "GameFontHighlightSmall", "CENTER")
    end
    card.name = card.lines[1]
    card.classIcons = {}
    -- The role in the top left corner, as on the role tiles; on a frame of
    -- its own, so the card's edge and art never cover it.
    card.badge = CreateFrame("Frame", nil, card)
    card.badge:SetSize(ROLE_ICON, ROLE_ICON)
    card.badge:SetPoint("TOPLEFT", card, "TOPLEFT", 4, -4)
    card.badge:SetFrameLevel((card:GetFrameLevel() or 0) + 5)
    card.icon = Widgets.roleIcon(card.badge, "D", ROLE_ICON)
    card.icon:SetAllPoints()
    card.plus = Widgets.text(card, "GameFontNormalHuge", "CENTER")
    card.plus:SetPoint("CENTER", 0, 8)
    card.plus:SetText("+")
    card.plus:SetTextColor(0.6, 0.6, 0.6)
    card.text = Widgets.text(card, "GameFontHighlightSmall", "CENTER")
    card.text:SetPoint("BOTTOM", 0, 9)
    card.distance = Widgets.text(card, "GameFontDisableSmall", "CENTER")
    card.distanceDot = Widgets.dot(card, 7)
    card.distanceDot:SetPoint("RIGHT", card.distance, "LEFT", -3, 0)
    card.quests = Widgets.text(card, "GameFontDisableSmall", "CENTER")
end

-- The lines under the spec in a group: where the member is and their
-- quests, the same lines on every card of the row.
local function paintExtras(card, data, layout, member)
    local text, color = Widgets.describeDistance(data.distance)
    local showDistance = member and layout.distance and data.distance ~= "none"
    card.distance:SetShown(showDistance and true or false)
    card.distanceDot:SetShown(showDistance and true or false)
    if showDistance then
        card.distance:SetText(text)
        card.distance:SetTextColor(color[1], color[2], color[3])
        Widgets.paintDot(card.distanceDot, color)
    end
    local quests = member and layout.quests and Widgets.describeQuests(data.quests) or ""
    card.quests:SetShown(quests ~= "")
    card.quests:SetText(quests)
end

-- The lines a member or invite card shows: name and spec in the middle, and
-- in a group where they are at the bottom left and their quests at the
-- bottom right.
-- The line under the name (spec, role, "invited 0:24") a size smaller than
-- the name; the font is shrunk rather than swapped for one this client may
-- not have.
local SPEC_FONT_SHRINK = 2
-- Where they are and their quests: smaller still.
local ROW_FONT_SHRINK = 3

-- From the font object's own size: a font set by hand stays on the line
-- through SetFontObject, so shrinking the line's current size would shrink
-- it again at every refresh.
local function shrinkFont(line, by)
    local base = _G.GameFontHighlightSmall
    if type(base) ~= "table" or type(base.GetFont) ~= "function" then
        return
    end
    local font, size, flags = base:GetFont()
    by = by or SPEC_FONT_SHRINK
    if type(font) == "string" and type(size) == "number" and size - by > 0 then
        line:SetFont(font, size - by, flags)
        line.shrunk = { font, size, flags }
    end
end

local function placeText(card, nameAtlas)
    local spec = (card.lines[2]:GetText() or "") ~= ""
    local top = math.floor((card.placeHeight - (12 + (spec and SPEC_GAP or 0))) / 2)
    placeName(card, nameAtlas, top)
    if spec then
        placeLine(card, card.lines[2], top + SPEC_GAP)
        shrinkFont(card.lines[2])
    end
    -- Each a half of the bottom row in the spec's smaller font, cut off
    -- with "..." rather than running into the other.
    local half = math.floor(card.placeWidth / 2) - SIDE_INSET
    if card.distance:IsShown() then
        local line = card.distance
        shrinkFont(line, ROW_FONT_SHRINK)
        line:SetWordWrap(false)
        line:SetJustifyH("LEFT")
        line:SetWidth(half - 10)
        line:ClearAllPoints()
        line:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", SIDE_INSET + 10, BOTTOM_INSET)
    end
    if card.quests:IsShown() then
        local line = card.quests
        line:SetFontObject("GameFontHighlightSmall")
        shrinkFont(line, ROW_FONT_SHRINK)
        line:SetWordWrap(false)
        line:SetJustifyH("RIGHT")
        line:SetWidth(half)
        line:ClearAllPoints()
        line:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -SIDE_INSET, BOTTOM_INSET)
    end
end

-- data: { role, name, self (shown as "You"), classToken, specIndex,
-- invite ({ name, held, left }), classes (the classes an open place is
-- wished for) }, and in a group distance and quests (Widgets.describeDistance,
-- Widgets.describeQuests). opts: { width, layout ({ distance, quests }, the
-- extra lines of the row), editable (an open place offers "Any class"; else
-- it says "open") }.
function W.paintPlace(card, data, opts)
    local layout = opts.layout or {}
    card.placeWidth, card.placeHeight = opts.width, W.PLACE_HEIGHT
    card:SetWidth(card.placeWidth)
    card:SetHeight(card.placeHeight)
    card.role = data.role
    Widgets.setRoleIcon(card.icon, data.role)
    for _, line in ipairs(card.lines) do
        line:SetText("")
    end
    for _, icon in ipairs(card.classIcons) do
        icon:Hide()
    end
    placeName(card, nil, NAME_TOP)
    placeLine(card, card.lines[2], NAME_TOP + SPEC_GAP)
    local member = data.name ~= nil and not data.invite
    local invite = not member and data.invite
    local classes = not member and not invite and data.classes or {}
    local icons = Widgets.atlasExists(iconAtlas("WARRIOR"))
    card.icon:SetAlpha(1)
    if member then
        local specName = Widgets.paintArt(card, data, card.placeWidth, card.placeHeight)
        local art = card.art:IsShown()
        card.lines[1]:SetText(data.self and L["You"] or data.name)
        card.lines[1]:SetTextColor(Widgets.classColor(data.classToken))
        local class = data.classToken and ns.Spec.className(data.classToken) or ""
        local withIcon = data.classToken ~= nil and Widgets.atlasExists(iconAtlas(data.classToken))
        -- A spec that doesn't play the place's role (a Shadow priest in a
        -- healer's place), or none known yet: the place's role instead.
        -- The trees they put points in when known ("Shadow/Holy" for a
        -- hybrid); else the tree that plays the place, or the place's role.
        local spec
        local trees = data.name and ns.Spec.treesOf(data.self and ns.selfName or data.name)
        if trees then
            local names = {}
            for i, tree in ipairs(trees) do
                names[i] = L[tree]
            end
            spec = table.concat(names, "/")
        end
        spec = spec or (specName and L[specName]) or (data.role and Widgets.roleName(data.role))
        if withIcon then
            card.lines[2]:SetText(spec or "")
            card.lines[2]:SetTextColor(0.9, 0.76, 0.45)
        else
            card.lines[2]:SetText(spec and (class .. " |cffe6c273" .. spec .. "|r") or class)
            if art then
                card.lines[2]:SetTextColor(1, 1, 1)
            else
                card.lines[2]:SetTextColor(0.6, 0.6, 0.6)
            end
        end
        card.nameAtlas = withIcon and iconAtlas(data.classToken) or nil
    else
        Widgets.hideArt(card)
    end
    if invite then
        card.lines[1]:SetText(invite.name or "")
        card.lines[1]:SetTextColor(0.75, 0.75, 0.75)
        local word = L[invite.held and "frees in" or "invited"]
        card.lines[2]:SetText(invite.left and (word .. " " .. Widgets.formatTime(invite.left)) or word)
        card.lines[2]:SetTextColor(0.6, 0.6, 0.6)
    elseif #classes > 0 and icons then
        placeClassIcons(card, classes)
    elseif #classes > 0 then
        for i = 1, math.min(#classes, NAME_LINES) do
            card.lines[i]:SetText(ns.Spec.className(classes[i]))
            card.lines[i]:SetTextColor(Widgets.classColor(classes[i]))
        end
        placeLine(card, card.lines[1], 26)
        placeLine(card, card.lines[2], 26 + SPEC_GAP)
    end
    local open = not member and not invite and #classes == 0
    card.plus:SetShown(open and opts.editable == true)
    if open then
        card.text:SetText(L[opts.editable and "Any class" or "open"])
    elseif #classes > NAME_LINES and not icons then
        card.text:SetText(string.format(L["+%d more"], #classes - NAME_LINES))
    else
        card.text:SetText("")
    end
    card.text:SetTextColor(0.6, 0.6, 0.6)
    -- "+" and "Any class" together in the middle, "open" alone in the middle,
    -- "+n more" under the class names.
    card.text:ClearAllPoints()
    if open and opts.editable then
        card.text:SetPoint("TOP", card.plus, "BOTTOM", 0, -1)
    elseif open then
        card.text:SetPoint("CENTER", 0, 0)
    else
        card.text:SetPoint("BOTTOM", 0, 9)
    end
    paintExtras(card, data, layout, member)
    if member or invite then
        placeText(card, member and card.nameAtlas or nil)
    end
    if member then
        Widgets.paintOutline(card, { 0, 0, 0, 0.25 }, { 1, 1, 1, 0 })
        paintEdge(card, { 1, 1, 1, 0.25 })
    elseif invite then
        Widgets.paintOutline(card, { 0, 0, 0, 0.15 }, { 1, 1, 1, 0 })
        paintEdge(card, { 1, 1, 1, 0.15 })
    elseif open then
        Widgets.paintOutline(card, { 1, 1, 1, 0.02 }, { 1, 1, 1, 0 })
        paintEdge(card, { 1, 1, 1, 0.3 }, true)
    else
        -- A place with a wish has the gold edge of a chosen role tile.
        Widgets.paintOutline(card, { 0, 0, 0, 0.3 }, { 1, 0.82, 0, 1 })
        paintEdge(card, { 1, 0.82, 0, 0 })
    end
end
