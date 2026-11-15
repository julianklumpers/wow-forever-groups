local _, ns = ...

local L = ns.L

local W = ns.WindowParts
local Widgets = ns.Widgets
local PartyLevels = ns.PartyLevels
local PAD = W.PAD
local ui = W.ui

-- "Limit levels" under "Lead a group" (Dungeons and Quests tabs): a switch
-- with the lowest and highest level (a default in grey, a typed level in
-- white), and a warning per ticked dungeon the limit leaves no level of
-- (wow/partylevels.lua).
local BOX_WIDTH, BOX_HEIGHT = 34, 20

local function levelBox(side)
    local box = CreateFrame("EditBox", nil, W.frame, "InputBoxTemplate")
    box:SetSize(BOX_WIDTH, BOX_HEIGHT)
    box:SetAutoFocus(false)
    box:SetNumeric(true)
    box:SetMaxLetters(2)
    box:SetJustifyH("CENTER")
    local function save(self)
        if self:GetText() == self.shownText then
            return
        end
        PartyLevels.set(side, self:GetText())
        ns.Window.refresh()
    end
    box:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    box:SetScript("OnEditFocusLost", save)
    box:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    return box
end

function W.buildLevels()
    ui.levelsToggle = Widgets.check(W.frame, "Limit levels", function(self)
        PartyLevels.setOn(self:GetChecked())
        ns.Window.refresh()
    end)
    Widgets.tooltip(ui.levelsToggle, "Limit levels", "Only players from the lowest to the highest level join your "
        .. "group, for every dungeon or quest you ticked: from Forever Groups' queue and from WoW's Group Finder. "
        .. "At first the levels of the dungeons you ticked (on the Quests tab your level, 3 either way, in grey); "
        .. "a level you type stays. Empty a box to go back.")
    ui.levelsFrom = Widgets.text(W.frame, "GameFontHighlightSmall")
    ui.levelsFrom:SetText(L["from"])
    ui.levelsMin = levelBox("min")
    ui.levelsTo = Widgets.text(W.frame, "GameFontHighlightSmall")
    ui.levelsTo:SetText(L["to"])
    ui.levelsMax = levelBox("max")
    ui.levelsWarning = Widgets.text(W.frame, "GameFontNormalSmall")
    ui.levelsWarning:SetTextColor(1, 0.6, 0.2)
    ui.levelsWarning:SetWidth(W.CONTENT - 22)
    ui.levelsWarning:SetJustifyH("LEFT")
    W.hideLevels()
end

function W.hideLevels()
    if not ui.levelsToggle then
        return
    end
    for _, widget in ipairs({ ui.levelsToggle, ui.levelsFrom, ui.levelsMin, ui.levelsTo, ui.levelsMax,
        ui.levelsWarning }) do
        widget:Hide()
    end
end

local function boxText(level)
    return level and level > 0 and tostring(level) or ""
end

-- tab: "dungeons" or "quests"; dungeonIds: the ticked dungeons, for the
-- warning. Returns the new y.
function W.layoutLevels(y, tab, dungeonIds)
    if not PartyLevels.isBuilder(tab) then
        W.hideLevels()
        return y
    end
    local on = PartyLevels.isOn()
    local locked = W.locked(tab)
    ui.levelsToggle:Show()
    ui.levelsToggle:SetChecked(on)
    for _, widget in ipairs({ ui.levelsToggle, ui.levelsMin, ui.levelsMax }) do
        Widgets.setEnabled(widget, not locked)
    end
    W.place(ui.levelsToggle, PAD - W.CHECK_INSET, y)
    for _, widget in ipairs({ ui.levelsFrom, ui.levelsMin, ui.levelsTo, ui.levelsMax }) do
        widget:SetShown(on)
    end
    ui.levelsWarning:Hide()
    if not on then
        return y - 26
    end
    local limit, typed = PartyLevels.limit(tab)
    for side, box in pairs({ min = ui.levelsMin, max = ui.levelsMax }) do
        if not box:HasFocus() then
            box.shownText = boxText(limit[side])
            box:SetText(box.shownText)
        end
        if typed[side] then
            box:SetTextColor(1, 1, 1)
        else
            box:SetTextColor(0.6, 0.6, 0.6)
        end
    end
    ui.levelsFrom:ClearAllPoints()
    ui.levelsFrom:SetPoint("LEFT", ui.levelsToggle.label, "RIGHT", 12, 0)
    ui.levelsMin:ClearAllPoints()
    ui.levelsMin:SetPoint("LEFT", ui.levelsFrom, "RIGHT", 10, 0)
    ui.levelsTo:ClearAllPoints()
    ui.levelsTo:SetPoint("LEFT", ui.levelsMin, "RIGHT", 8, 0)
    ui.levelsMax:ClearAllPoints()
    ui.levelsMax:SetPoint("LEFT", ui.levelsTo, "RIGHT", 10, 0)
    y = y - 26
    local outside = tab == "dungeons" and PartyLevels.outside(dungeonIds) or {}
    if #outside > 0 then
        local names = {}
        for i, dungeon in ipairs(outside) do
            names[i] = string.format("%s (%d-%d)", dungeon.name, dungeon.min, dungeon.max)
        end
        ui.levelsWarning:SetText(string.format(L["Nobody fits your level limit for: %s"], table.concat(names, ", ")))
        W.place(ui.levelsWarning, PAD + 22, y + 2)
        ui.levelsWarning:Show()
        y = y - math.ceil(ui.levelsWarning:GetStringHeight() or 14) - 6
    end
    return y
end
