local _, ns = ...

local L = ns.L

local Widgets = ns.Widgets

-- How far everyone in the group is with the group's quests, folded out
-- under the status bar. The bar's quest progress icon, the card's "Quest
-- progress" button and /fg progress fold it out or in; it folds out by
-- itself when a group with quests forms. Whether it is out is saved.
local ProgressWindow = {}

local LINE = 16
local panel
local titles, names, texts = {}, {}, {}
local others

local function fontString(pool, i, font, justify)
    if not pool[i] then
        pool[i] = Widgets.text(panel, font, justify)
    end
    return pool[i]
end

local function expanded()
    return ns.db and ns.db.progressExpanded == true
end

local function build(bar)
    panel = CreateFrame("Frame", nil, bar)
    panel:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, 0)
    panel:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", 0, 0)
    panel:SetHeight(40)
    local background = panel:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(0, 0, 0, 0.7)
    others = Widgets.text(panel, "GameFontDisableSmall")
    panel:Hide()
end

function ProgressWindow.refresh()
    local bar = ns.Status.frame()
    if not bar then
        return
    end
    if not panel then
        build(bar)
    end
    local rows, without = {}, {}
    if expanded() then
        rows, without = ns.QuestGroup.rows()
    end
    local width = bar:GetWidth()
    width = type(width) == "number" and width or 420
    local y, t, n = -6, 0, 0
    for _, row in ipairs(rows) do
        t = t + 1
        local title = fontString(titles, t, "GameFontNormalSmall")
        title:ClearAllPoints()
        title:SetPoint("TOPLEFT", 10, y)
        title:SetText(row.title)
        title:Show()
        y = y - LINE
        for _, line in ipairs(row.lines) do
            n = n + 1
            local name = fontString(names, n, "GameFontHighlightSmall")
            name:ClearAllPoints()
            name:SetPoint("TOPLEFT", 22, y)
            name:SetText(line.name)
            name:Show()
            local text = fontString(texts, n, "GameFontHighlightSmall", "RIGHT")
            text:ClearAllPoints()
            text:SetPoint("TOPRIGHT", -10, y)
            text:SetText(line.text)
            text:Show()
            y = y - LINE + 2
        end
        y = y - 4
    end
    for i = t + 1, #titles do
        titles[i]:Hide()
    end
    for i = n + 1, #names do
        names[i]:Hide()
        texts[i]:Hide()
    end
    others:SetShown(#rows > 0 and #without > 0)
    if #rows > 0 and #without > 0 then
        others:ClearAllPoints()
        others:SetPoint("TOPLEFT", 10, y)
        others:SetWidth(width - 20)
        others:SetText(string.format(L["Without Forever Groups: %s"], table.concat(without, ", ")))
        local height = others:GetStringHeight()
        y = y - math.max(LINE, (type(height) == "number" and height or 0) + 4)
    end
    panel:SetHeight(-y + 4)
    panel:SetShown(#rows > 0)
    -- Keeps the folded-out list on screen too, not only the bar.
    if bar.SetClampRectInsets then
        bar:SetClampRectInsets(0, 0, 0, #rows > 0 and -(-y + 4) or 0)
    end
end

-- auto: a new group opened it, not the player; then nothing is said.
function ProgressWindow.show(auto)
    if ns.db then
        ns.db.progressExpanded = true
    end
    ns.Status.refresh()
    if auto then
        return
    end
    if not ns.QuestGroup.current() or #ns.QuestGroup.rows() == 0 then
        ns.Log.info("No group quests to follow right now.")
    elseif ns.db and ns.db.statusHidden then
        ns.Log.info("Turn on the status bar in the settings to see the quest progress under it.")
    end
end

function ProgressWindow.hide()
    if ns.db then
        ns.db.progressExpanded = false
    end
    ns.Status.refresh()
    ProgressWindow.refresh()
end

function ProgressWindow.toggle()
    if expanded() then
        ProgressWindow.hide()
    else
        ProgressWindow.show()
    end
end

-- Whether the progress is folded out under a visible status bar.
function ProgressWindow.isShown()
    return panel ~= nil and panel:IsShown() and ns.Status.isShown()
end

function ProgressWindow.isExpanded()
    return expanded()
end

ns.ProgressWindow = ProgressWindow
