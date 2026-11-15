local _, ns = ...

local Widgets = ns.Widgets
local L = ns.L

-- On a client without WoW's own dropdown menu: the list under a place card
-- of "Choose the classes in my party", "Any class" and every class that can
-- play the place's role in its class colour, ticked when wished for.
-- Several can be ticked; it stays open until a click elsewhere or Escape.
local ClassMenu = {}

local WIDTH, ITEM_HEIGHT = 170, 20
local MAX_ITEMS = 10

local menu

local function build()
    menu = CreateFrame("Frame", "ForeverGroupsClassMenu", UIParent)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetClampedToScreen(true)
    menu:EnableMouse(true)
    local background = menu:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(0.05, 0.05, 0.06, 0.96)
    local border = menu:CreateTexture(nil, "BORDER")
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetColorTexture(1, 0.82, 0, 0.35)
    menu.items = {}
    for i = 1, MAX_ITEMS do
        local item = CreateFrame("Button", nil, menu)
        item:SetSize(WIDTH - 8, ITEM_HEIGHT)
        item:SetPoint("TOPLEFT", 4, -4 - (i - 1) * ITEM_HEIGHT)
        item:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        item.check = item:CreateTexture(nil, "ARTWORK")
        item.check:SetSize(14, 14)
        item.check:SetPoint("LEFT", 4, 0)
        item.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
        item.label = Widgets.text(item, "GameFontHighlightSmall")
        item.label:SetPoint("LEFT", 22, 0)
        menu.items[i] = item
    end
    table.insert(UISpecialFrames, "ForeverGroupsClassMenu")
    pcall(menu.RegisterEvent, menu, "GLOBAL_MOUSE_DOWN")
    menu:SetScript("OnEvent", function(self)
        if self:IsShown() and not self:IsMouseOver() and not (self.owner and self.owner:IsMouseOver()) then
            self:Hide()
        end
    end)
    menu:Hide()
end

local function paint(classes, chosen)
    local wished = {}
    for _, class in ipairs(chosen) do
        wished[class] = true
    end
    menu.items[1].check:SetShown(#chosen == 0)
    for i, class in ipairs(classes) do
        menu.items[i + 1].check:SetShown(wished[class] == true)
    end
end

-- owner: the place's card; classes: those that can play its role; chosen:
-- the ticked ones; onChange(list) runs with the new list after each click.
function ClassMenu.toggle(owner, classes, chosen, onChange)
    if not menu then
        build()
    end
    if menu:IsShown() and menu.owner == owner then
        menu:Hide()
        return
    end
    local current = { unpack(chosen) }
    local any = menu.items[1]
    any.label:SetText(L["Any class"])
    any.label:SetTextColor(1, 1, 1)
    any:SetScript("OnClick", function()
        current = {}
        paint(classes, current)
        onChange(current)
    end)
    any:Show()
    for i = 2, MAX_ITEMS do
        local item, class = menu.items[i], classes[i - 1]
        item:SetShown(class ~= nil)
        if class then
            item.label:SetText(ns.Spec.className(class))
            item.label:SetTextColor(Widgets.classColor(class))
            item:SetScript("OnClick", function()
                local next, found = {}, false
                for _, other in ipairs(current) do
                    if other == class then
                        found = true
                    else
                        next[#next + 1] = other
                    end
                end
                if not found then
                    next[#next + 1] = class
                end
                current = next
                paint(classes, current)
                onChange(current)
            end)
        end
    end
    paint(classes, current)
    menu:SetSize(WIDTH, 8 + (#classes + 1) * ITEM_HEIGHT)
    menu.owner = owner
    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -2)
    menu:Show()
end

function ClassMenu.hide()
    if menu then
        menu:Hide()
    end
end

ns.ClassMenu = ClassMenu
