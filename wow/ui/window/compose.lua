local _, ns = ...

local L = ns.L

local W = ns.WindowParts
local Widgets = ns.Widgets
local Compose = ns.Compose
local PartyCompose = ns.PartyCompose
local PAD = W.PAD
local ui = W.ui

-- Choosing the classes in the party, on the Dungeons tab under "Lead a
-- group": a switch, and while it is on the group's five places side by side
-- as cards, in the window's quiet style: the role small in the corner and
-- the classes wished for as their round icons, up to three by three (by name
-- in their class colour, two and "+n more", on a client without the icons);
-- the player's and the party's places show who is there. A place open to any
-- class is an empty slot with a dashed edge and a "+". Each card is a dropdown like the
-- playstyle's: WoW's own menu with "Any class" and a check per class that can
-- play the place's role, in its class colour (our own list,
-- wow/ui/classmenu.lua, on a client without it). Switched off the wishes
-- stay, unused. Only while the player builds the group
-- (wow/partycompose.lua).
local CARD_HEIGHT, CARD_GAP = 84, W.SPACE.s
local NAME_LINES = 2
local ROLE_ICON = 16
local ICON_GAP = 3
local DASH, DASH_GAP = 4, 4
-- The cards draw their own edge, a thin line with rounded corners: the
-- rounded tooltip border shows its soft outer edge only when bright, so a gold
-- card looked bigger than a grey or dashed one.
local ROUNDED_INSET, RADIUS = 3, 5
local ROUND_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local cards = {}
W.composeCards = cards

local function hasWishes(masks)
    local count = 0
    for _, mask in ipairs(masks) do
        if mask ~= 0 then
            count = count + 1
        end
    end
    return count
end

local function colored(class)
    local r, g, b = Widgets.classColor(class)
    return string.format("|cff%02x%02x%02x%s|r", math.floor(r * 255), math.floor(g * 255), math.floor(b * 255),
        ns.Spec.className(class))
end

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
    local width, height = card:GetWidth() or 0, CARD_HEIGHT
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

local function showCardTooltip(card)
    if not GameTooltip then
        return
    end
    GameTooltip:SetOwner(card, "ANCHOR_BOTTOM")
    GameTooltip:SetText(Widgets.roleName(card.role), 1, 0.82, 0)
    if card.person then
        local name = card.person.self and L["You"] or card.person.name
        GameTooltip:AddLine(card.person.class and colored(card.person.class) and string.format("%s (%s)", name,
            colored(card.person.class)) or name, 1, 1, 1)
    elseif #card.classes == 0 then
        GameTooltip:AddLine(L["Any class"], 1, 1, 1)
    else
        local names = {}
        for i, class in ipairs(card.classes) do
            names[i] = colored(class)
        end
        GameTooltip:AddLine(table.concat(names, ", "), 1, 1, 1, true)
    end
    GameTooltip:Show()
end

local function changed(slot, classes)
    PartyCompose.setClasses(slot, classes)
    ns.Window.refresh()
end

local function chosenIn(slot)
    return Compose.classesOf(PartyCompose.settings().masks[slot] or 0)
end

-- WoW's own menu: "Any class" and a check per class in its colour; it stays
-- open while ticking.
local function classMenu(slot, role)
    return function(card)
        card:SetupMenu(function(_, root)
            local keep = MenuResponse and MenuResponse.Refresh
            root:CreateCheckbox(L["Any class"], function()
                return #chosenIn(slot) == 0
            end, function()
                changed(slot, {})
                return keep
            end)
            for _, class in ipairs(Compose.classesFor(role)) do
                root:CreateCheckbox(colored(class), function()
                    local mask = PartyCompose.settings().masks[slot] or 0
                    return mask ~= 0 and Compose.allows(mask, class)
                end, function()
                    local list, found = {}, false
                    for _, other in ipairs(chosenIn(slot)) do
                        if other == class then
                            found = true
                        else
                            list[#list + 1] = other
                        end
                    end
                    if not found then
                        list[#list + 1] = class
                    end
                    changed(slot, list)
                    return keep
                end)
            end
        end)
    end
end

-- A card that opens WoW's own dropdown menu, or a plain button that opens
-- our list on a client without one.
local function newCard(slot, role)
    local ok, card = pcall(CreateFrame, "DropdownButton", nil, W.frame, "BackdropTemplate")
    if not ok or not card then
        ok, card = pcall(CreateFrame, "DropdownButton", nil, W.frame)
    end
    local native = ok and card and type(card.SetupMenu) == "function"
    if not native then
        if ok and card then
            card:Hide()
        end
        card = Widgets.backdropFrame("Button", W.frame)
        card:SetScript("OnClick", function(self)
            ns.ClassMenu.toggle(self, Compose.classesFor(role), chosenIn(slot), function(list)
                changed(slot, list)
            end)
        end)
    else
        classMenu(slot, role)(card)
    end
    card.native = native
    return card
end

function W.buildCompose()
    ui.composeToggle = Widgets.check(W.frame, "Choose the classes in my party", function(self)
        PartyCompose.setOn(self:GetChecked())
        ns.ClassMenu.hide()
        ns.Window.refresh()
    end)
    Widgets.tooltip(ui.composeToggle, "Choose the classes in my party", "Choose the classes you want for each "
        .. "open place. Forever Groups then only puts players of those classes in your group, from its queue and "
        .. "from WoW's Group Finder.")
    ui.composeReset = Widgets.link(W.frame, "Reset", function()
        PartyCompose.reset()
        ns.ClassMenu.hide()
        ns.Window.refresh()
    end)
    for slot, role in ipairs(Compose.SLOT_ROLES) do
        local card = newCard(slot, role)
        card:SetHeight(CARD_HEIGHT)
        Widgets.addOutline(card)
        Widgets.addArt(card)
        card.slot, card.role, card.classes = slot, role, {}
        card.lines = {}
        for i = 1, NAME_LINES do
            card.lines[i] = Widgets.text(card, "GameFontHighlight", "CENTER")
        end
        card.classIcons = {}
        card.icon = Widgets.roleIcon(card, role, ROLE_ICON)
        card.icon:SetPoint("TOPLEFT", 6, -6)
        card.plus = Widgets.text(card, "GameFontNormalHuge", "CENTER")
        card.plus:SetPoint("CENTER", 0, 2)
        card.plus:SetText("+")
        card.plus:SetTextColor(0.6, 0.6, 0.6)
        card.text = Widgets.text(card, "GameFontHighlightSmall", "CENTER")
        card.text:SetPoint("BOTTOM", 0, 9)
        card:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        card.arrow = card:CreateTexture(nil, "ARTWORK")
        card.arrow:SetSize(Widgets.DROPDOWN_ARROW, Widgets.DROPDOWN_ARROW)
        card.arrow:SetPoint("BOTTOMRIGHT", -4, 4)
        if Widgets.atlasExists("common-dropdown-a-button") then
            card.arrow:SetAtlas("common-dropdown-a-button")
        else
            card.arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
        end
        card:HookScript("OnEnter", showCardTooltip)
        card:HookScript("OnLeave", function()
            if GameTooltip then
                GameTooltip:Hide()
            end
        end)
        cards[slot] = card
    end
    W.hideCompose()
end

function W.hideCompose()
    if not ui.composeToggle then
        return
    end
    ui.composeToggle:Hide()
    ui.composeReset:Hide()
    for _, card in ipairs(cards) do
        card:Hide()
        if card.native and type(card.CloseMenu) == "function" then
            pcall(card.CloseMenu, card)
        end
    end
    ns.ClassMenu.hide()
end

local function iconAtlas(class)
    return "classicon-" .. string.lower(class)
end

local function hasClassIcons()
    return Widgets.atlasExists(iconAtlas("WARRIOR"))
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
    local size = count <= 4 and 24 or 20
    local rows = math.ceil(count / columns)
    local top = math.floor((CARD_HEIGHT - (rows * size + (rows - 1) * ICON_GAP)) / 2)
    local width = card:GetWidth() or 0
    for i, class in ipairs(classes) do
        local row, column = math.floor((i - 1) / columns), (i - 1) % columns
        local inRow = math.min(columns, count - row * columns)
        local left = math.floor((width - (inRow * size + (inRow - 1) * ICON_GAP)) / 2)
        local icon = classIcon(card, i)
        icon:SetAtlas(iconAtlas(class))
        icon:SetSize(size, size)
        icon:ClearAllPoints()
        icon:SetPoint("TOPLEFT", card, "TOPLEFT", left + column * (size + ICON_GAP), -(top + row * (size + ICON_GAP)))
        icon:Show()
    end
end

-- A name too wide for the card gets the small font, and is cut off with
-- "..." if even that does not fit.
local function placeLines(card, top)
    local width = (card:GetWidth() or 0) - 2 * (ROUNDED_INSET + 3)
    for i, line in ipairs(card.lines) do
        line:SetFontObject("GameFontHighlight")
        if (line:GetStringWidth() or 0) > width then
            line:SetFontObject("GameFontHighlightSmall")
        end
        line:SetWidth(width)
        line:SetWordWrap(false)
        line:ClearAllPoints()
        line:SetPoint("TOP", 0, -(top + (i - 1) * 16))
    end
end

local NAME_ICON, NAME_ICON_GAP = 14, 2

-- The class's round icon just before the first line (the name), the two
-- centred together; nil hides it.
local function placeNameIcon(card, class, top)
    if not class then
        if card.nameIcon then
            card.nameIcon:Hide()
        end
        return
    end
    if not card.nameIcon then
        card.nameIcon = classIcon(card, "name")
    end
    local line = card.lines[1]
    local room = (line:GetWidth() or 0) - NAME_ICON - NAME_ICON_GAP
    line:SetWidth(room)
    line:ClearAllPoints()
    line:SetPoint("TOP", math.floor((NAME_ICON + NAME_ICON_GAP) / 2), -top)
    local text = math.min(line:GetStringWidth() or room, room)
    local left = math.floor(((card:GetWidth() or 0) - (text + NAME_ICON + NAME_ICON_GAP)) / 2)
    card.nameIcon:SetAtlas(iconAtlas(class))
    card.nameIcon:SetSize(NAME_ICON, NAME_ICON)
    card.nameIcon:ClearAllPoints()
    card.nameIcon:SetPoint("TOPLEFT", card, "TOPLEFT", left, -top + 1)
    card.nameIcon:Show()
end

-- Who is on a fixed place (their class's icon, name and class), or the
-- classes wished for as icons (on a client without them: two names and
-- "+n more"); an open place shows a dashed edge and a "+".
local function paintCard(card, person, classes)
    card.person, card.classes = person, classes
    for _, line in ipairs(card.lines) do
        line:SetText("")
    end
    for _, icon in ipairs(card.classIcons) do
        icon:Hide()
    end
    placeNameIcon(card, nil)
    local icons = hasClassIcons()
    -- The player's and the party's places look like the party's places
    -- above: their spec art, class and spec.
    local specName
    if person then
        specName = Widgets.paintArt(card, { name = person.name, classToken = person.class, role = card.role,
            specIndex = ns.Spec.indexOf(person.name) }, card:GetWidth() or 0, CARD_HEIGHT)
    else
        Widgets.hideArt(card)
    end
    local art = card.art:IsShown()
    if person then
        card.lines[1]:SetText(person.self and L["You"] or person.name)
        card.lines[1]:SetTextColor(Widgets.classColor(person.class))
        local class = person.class and ns.Spec.className(person.class) or ""
        local withIcon = art and icons and person.class ~= nil
        if withIcon then
            card.lines[2]:SetText(specName and ("|cffe6c273" .. L[specName] .. "|r") or "")
        else
            card.lines[2]:SetText(art and specName and (class .. " |cffe6c273" .. L[specName] .. "|r") or class)
        end
        if art then
            card.lines[2]:SetTextColor(1, 1, 1)
        else
            card.lines[2]:SetTextColor(0.6, 0.6, 0.6)
        end
        if art then
            placeLines(card, 42)
            if withIcon then
                placeNameIcon(card, person.class, 42)
            end
        elseif icons and person.class then
            placeClassIcons(card, { person.class })
            card.classIcons[1]:ClearAllPoints()
            card.classIcons[1]:SetPoint("TOP", 0, -12)
            placeLines(card, 40)
        else
            placeLines(card, 26)
        end
    elseif icons then
        placeClassIcons(card, classes)
    else
        for i = 1, math.min(#classes, NAME_LINES) do
            card.lines[i]:SetText(ns.Spec.className(classes[i]))
            card.lines[i]:SetTextColor(Widgets.classColor(classes[i]))
        end
        placeLines(card, 26)
    end
    local open = person == nil and #classes == 0
    card.plus:SetShown(open)
    if open then
        card.text:SetText(L["Any class"])
    elseif not person and not icons and #classes > NAME_LINES then
        card.text:SetText(string.format(L["+%d more"], #classes - NAME_LINES))
    else
        card.text:SetText("")
    end
    card.text:SetTextColor(0.6, 0.6, 0.6)
    Widgets.setEnabled(card, person == nil)
    card.arrow:SetShown(person == nil)
    if person then
        Widgets.paintOutline(card, { 0, 0, 0, 0.25 }, { 1, 1, 1, 0 })
        paintEdge(card, { 1, 1, 1, 0.25 })
    elseif open then
        Widgets.paintOutline(card, { 1, 1, 1, 0.02 }, { 1, 1, 1, 0 })
        paintEdge(card, { 1, 1, 1, 0.3 }, true)
    else
        Widgets.paintOutline(card, { 0, 0, 0, 0.3 }, { 1, 1, 1, 0 })
        paintEdge(card, { 1, 0.82, 0, 0.9 })
    end
end

-- Places the block from y down while the player builds the group; returns
-- the new y.
function W.layoutCompose(y)
    if not PartyCompose.isBuilder() then
        W.hideCompose()
        return y
    end
    local masks, fixed = PartyCompose.chosenMasks(), PartyCompose.fixed()
    local on = PartyCompose.isOn()
    ui.composeToggle:Show()
    ui.composeToggle:SetChecked(on)
    W.place(ui.composeToggle, PAD - W.CHECK_INSET, y)
    ui.composeReset:SetShown(on and hasWishes(masks) > 0)
    ui.composeReset:ClearAllPoints()
    ui.composeReset:SetPoint("TOPRIGHT", W.frame, "TOPRIGHT", W.RIGHT_OFFSET, y - 3)
    y = y - 26
    if not on then
        for _, card in ipairs(cards) do
            card:Hide()
        end
        ns.ClassMenu.hide()
        return y - 4
    end
    for slot, column in ipairs(W.columns(#cards, CARD_GAP)) do
        local card = cards[slot]
        card:SetWidth(column.width)
        paintCard(card, fixed[slot], Compose.classesOf(masks[slot] or 0))
        W.place(card, column.x, y - 2)
        card:Show()
    end
    return y - CARD_HEIGHT - 10
end
