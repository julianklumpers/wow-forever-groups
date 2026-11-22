local _, ns = ...

local L = ns.L

local W = ns.WindowParts
local Widgets = ns.Widgets
local Compose = ns.Compose
local PartyCompose = ns.PartyCompose
local PAD = W.PAD
local ui = W.ui

-- Choosing the classes in the party, on the Dungeons tab under "Lead a
-- group": a title and the group's five places side by side as place cards
-- (wow/ui/window/placecard.lua): the classes wished for as their round icons;
-- the player's and the party's places show who is there; a place open to any
-- class has a dashed edge, a "+" and "Any class". Each card is a dropdown
-- like the playstyle's: WoW's own menu with "Any class" and a check per class
-- that can play the place's role, in its class colour (our own list,
-- wow/ui/classmenu.lua, on a client without it). Only while the player builds
-- the group (wow/partycompose.lua).
local CARD_GAP = W.SPACE.s
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

local function chosenIn(place)
    return Compose.classesOf(PartyCompose.masks()[place] or 0)
end

-- WoW's own menu: "Any class" and a check per class in its colour; it stays
-- open while ticking.
local function classMenu(placeOf, change)
    return function(card)
        card:SetupMenu(function(_, root)
            local place = placeOf(card)
            if not place then
                return
            end
            local keep = MenuResponse and MenuResponse.Refresh
            root:CreateCheckbox(L["Any class"], function()
                return #chosenIn(place) == 0
            end, function()
                change(place, {})
                return keep
            end)
            local classes = Compose.classesFor(Compose.SLOT_ROLES[place])
            table.sort(classes, function(a, b)
                return ns.Spec.className(a) < ns.Spec.className(b)
            end)
            Widgets.classesByArmor(root, classes, function(menu, class)
                menu:CreateCheckbox(colored(class), function()
                    local mask = PartyCompose.masks()[place] or 0
                    return mask ~= 0 and Compose.allows(mask, class)
                end, function()
                    local list, found = {}, false
                    for _, other in ipairs(chosenIn(place)) do
                        if other == class then
                            found = true
                        else
                            list[#list + 1] = other
                        end
                    end
                    if not found then
                        list[#list + 1] = class
                    end
                    change(place, list)
                    return keep
                end)
            end, function(group)
                local mask = PartyCompose.masks()[place] or 0
                for _, class in ipairs(group) do
                    if mask == 0 or not Compose.allows(mask, class) then
                        return false
                    end
                end
                return true
            end, function(group, on)
                local inGroup, list = {}, {}
                for _, class in ipairs(group) do
                    inGroup[class] = true
                end
                for _, other in ipairs(chosenIn(place)) do
                    if not inGroup[other] then
                        list[#list + 1] = other
                    end
                end
                if on then
                    for _, class in ipairs(group) do
                        list[#list + 1] = class
                    end
                end
                change(place, list)
                return keep
            end)
        end)
    end
end

-- A place card that opens WoW's own dropdown menu of the classes for a party
-- place, or a plain button that opens our list on a client without one.
-- placeOf(card) names the place it chooses for (nil: none), change(place,
-- classes) keeps the choice. Also the open places of a run (card.lua).
function W.newClassCard(parent, placeOf, change)
    local ok, card = pcall(CreateFrame, "DropdownButton", nil, parent, "BackdropTemplate")
    if not ok or not card then
        ok, card = pcall(CreateFrame, "DropdownButton", nil, parent)
    end
    local native = ok and card and type(card.SetupMenu) == "function"
    if not native then
        if ok and card then
            card:Hide()
        end
        card = Widgets.backdropFrame("Button", parent)
        card:SetScript("OnClick", function(self)
            local place = placeOf(self)
            if place then
                ns.ClassMenu.toggle(self, Compose.classesFor(Compose.SLOT_ROLES[place]), chosenIn(place),
                    function(list)
                        change(place, list)
                    end)
            end
        end)
    else
        classMenu(placeOf, change)(card)
    end
    card.native = native
    W.addPlaceParts(card)
    -- Inside the rounded fill (its backdrop insets), as on the role tiles.
    card.hover = card:CreateTexture(nil, "HIGHLIGHT")
    card.hover:SetPoint("TOPLEFT", 4, -4)
    card.hover:SetPoint("BOTTOMRIGHT", -4, 4)
    card.hover:SetColorTexture(1, 1, 1, 0.07)
    card.arrow = card:CreateTexture(nil, "ARTWORK")
    card.arrow:SetSize(Widgets.DROPDOWN_ARROW, Widgets.DROPDOWN_ARROW)
    card.arrow:SetPoint("BOTTOMRIGHT", -4, 4)
    if Widgets.atlasExists("common-dropdown-a-button") then
        card.arrow:SetAtlas("common-dropdown-a-button")
    else
        card.arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
    end
    return card
end

function W.closeClassCard(card)
    if card.native and type(card.CloseMenu) == "function" then
        pcall(card.CloseMenu, card)
    end
end

local function changed(slot, classes)
    PartyCompose.setClasses(slot, classes)
    ns.Window.refresh()
end

function W.buildCompose()
    ui.composeTitle = CreateFrame("Frame", nil, W.frame)
    ui.composeTitle:EnableMouse(true)
    local title = Widgets.text(ui.composeTitle, "GameFontNormalSmall")
    title:SetPoint("LEFT")
    title:SetText(L["Choose the classes in my party"])
    ui.composeTitle.label = title
    ui.composeTitle:SetSize(title:GetStringWidth() + 4, 18)
    Widgets.tooltip(ui.composeTitle, "Choose the classes in my party", "Choose the classes you want for each "
        .. "open place. Forever Groups then only puts players of those classes in your group, from its queue and "
        .. "from WoW's Group Finder.")
    ui.composeReset = Widgets.link(W.frame, "Reset", function()
        PartyCompose.reset()
        ns.ClassMenu.hide()
        ns.Window.refresh()
    end)
    for slot, role in ipairs(Compose.SLOT_ROLES) do
        local card = W.newClassCard(W.frame, function()
            return slot
        end, changed)
        card.slot, card.role, card.classes = slot, role, {}
        card:HookScript("OnEnter", W.showRoleInfo)
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
    if not ui.composeTitle then
        return
    end
    ui.composeTitle:Hide()
    ui.composeReset:Hide()
    for _, card in ipairs(cards) do
        card:Hide()
        W.closeClassCard(card)
    end
    ns.ClassMenu.hide()
end

-- Who is on a fixed place, or the classes wished for; an open place offers
-- "Any class". Only an open place opens the dropdown.
local function paintCard(card, person, classes, width)
    card.person, card.classes = person, classes
    card.roleName = person and person.name
    card.roleInfo = person and not person.self and W.memberRoleInfo(person.name) or nil
    local data = { role = card.role, classes = classes }
    if person then
        data.name, data.self, data.classToken = person.name, person.self, person.class
        data.specIndex = ns.Spec.indexOf(person.name)
    end
    W.paintPlace(card, data, { width = width, editable = true })
    Widgets.setEnabled(card, person == nil)
    card.arrow:SetShown(person == nil)
end

-- Places the block from y down while the player builds the group; returns
-- the new y.
function W.layoutCompose(y)
    if not PartyCompose.isBuilder() then
        W.hideCompose()
        return y
    end
    local masks, fixed = PartyCompose.chosenMasks(), PartyCompose.fixed()
    ui.composeTitle:Show()
    W.place(ui.composeTitle, PAD, y - 2)
    ui.composeReset:SetShown(hasWishes(masks) > 0)
    ui.composeReset:ClearAllPoints()
    ui.composeReset:SetPoint("TOPRIGHT", W.frame, "TOPRIGHT", W.RIGHT_OFFSET, y - 3)
    y = y - 26
    for slot, column in ipairs(W.columns(#cards, CARD_GAP)) do
        local card = cards[slot]
        paintCard(card, fixed[slot], Compose.classesOf(masks[slot] or 0), column.width)
        W.place(card, column.x, y - 2)
        card:Show()
    end
    return y - W.PLACE_HEIGHT - 10
end
