local _, ns = ...

local Widgets = ns.Widgets

-- The list under the playstyle dropdown: each playstyle with its words, the
-- chosen one ticked. Closes on a choice, Escape or a click elsewhere.
local PlaystyleMenu = {}

local WIDTH = 260
local ITEM_HEIGHT = 34

local menu

local function build()
    menu = CreateFrame("Frame", "ForeverGroupsPlaystyleMenu", UIParent)
    menu:SetFrameStrata("DIALOG")
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
    for i, id in ipairs(ns.Playstyle.ORDER) do
        local item = CreateFrame("Button", nil, menu)
        item:SetSize(WIDTH - 8, ITEM_HEIGHT)
        item:SetPoint("TOPLEFT", 4, -4 - (i - 1) * ITEM_HEIGHT)
        item:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        item.check = item:CreateTexture(nil, "ARTWORK")
        item.check:SetSize(14, 14)
        item.check:SetPoint("TOPLEFT", 4, -4)
        item.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
        item.label = Widgets.text(item, "GameFontHighlightSmall")
        item.label:SetPoint("TOPLEFT", 22, -4)
        item.label:SetText(ns.Playstyle.word(id))
        item.note = Widgets.text(item, "GameFontDisableSmall")
        item.note:SetPoint("TOPLEFT", 22, -18)
        item.note:SetWidth(WIDTH - 34)
        item.note:SetWordWrap(false)
        item.note:SetText(ns.Playstyle.partnersText(id))
        item.playstyle = id
        menu.items[i] = item
    end
    menu:SetSize(WIDTH, 8 + #ns.Playstyle.ORDER * ITEM_HEIGHT)
    table.insert(UISpecialFrames, "ForeverGroupsPlaystyleMenu")
    pcall(menu.RegisterEvent, menu, "GLOBAL_MOUSE_DOWN")
    menu:SetScript("OnEvent", function(self)
        if self:IsShown() and not self:IsMouseOver() and not (self.owner and self.owner:IsMouseOver()) then
            self:Hide()
        end
    end)
    menu:Hide()
end

-- owner: the dropdown button; onPick(id) runs with the chosen playstyle.
function PlaystyleMenu.toggle(owner, onPick)
    if not menu then
        build()
    end
    if menu:IsShown() then
        menu:Hide()
        return
    end
    local mine = ns.Playstyle.mine()
    for _, item in ipairs(menu.items) do
        item.check:SetShown(item.playstyle == mine)
        item:SetScript("OnClick", function(self)
            menu:Hide()
            onPick(self.playstyle)
        end)
    end
    menu.owner = owner
    menu:ClearAllPoints()
    menu:SetPoint("TOPRIGHT", owner, "BOTTOMRIGHT", 0, -2)
    menu:Show()
end

function PlaystyleMenu.hide()
    if menu then
        menu:Hide()
    end
end

ns.PlaystyleMenu = PlaystyleMenu
