local _, ns = ...

local L = ns.L

local Widgets = ns.Widgets
local Messages = ns.Messages

-- The message editor on the settings' Messages tab: every text Forever
-- Groups sends to other players, to rewrite in the player's own words or
-- language, or to turn off. /fg messages opens that tab.
local MessagesWindow = {}

local ROW = 92

local rows = {}

local INTRO = "Write the messages in your own words or language. Placeholders: {dungeon} {quest} {zone} "
    .. "{size} {role} {roles} {spec} {level}. A sentence whose placeholder has no value is left out. "
    .. "Messages start with [Forever Groups], so other players' addons know not to answer them."

local function paint(row)
    local id = row.message.id
    row.check:SetChecked(Messages.isOn(id))
    if not row.edit:HasFocus() then
        row.edit:SetText(Messages.template(id))
        row.edit:SetCursorPosition(0)
    end
    local preview = Messages.sample(id)
    row.preview:SetText(preview and string.format(L["Sends: %s"], preview) or L["Turned off: nothing is sent."])
end

local function buildRow(content, width, message, y)
    local row = { message = message }
    row.check = Widgets.check(content, message.label, function(self)
        Messages.setOn(message.id, self:GetChecked() and true or false)
        paint(row)
    end)
    row.check:SetPoint("TOPLEFT", 4, y)
    row.edit = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    row.edit:SetSize(width - 160, 22)
    row.edit:SetPoint("TOPLEFT", 36, y - 26)
    row.edit:SetAutoFocus(false)
    row.edit:SetMaxLetters(240)
    row.edit:SetScript("OnTextChanged", function(self, userInput)
        if userInput then
            Messages.set(message.id, self:GetText())
            paint(row)
        end
    end)
    row.edit:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    row.edit:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    row.reset = Widgets.button(content, "Reset", 70)
    row.reset:SetPoint("LEFT", row.edit, "RIGHT", 10, 0)
    row.reset:SetScript("OnClick", function()
        Messages.reset(message.id)
        row.edit:ClearFocus()
        paint(row)
    end)
    Widgets.tooltip(row.reset, "Reset", "Back to the original text, and turned on.")
    row.preview = Widgets.text(content, "GameFontDisableSmall")
    row.preview:SetPoint("TOPLEFT", 36, y - 54)
    row.preview:SetWidth(width - 110)
    return row
end

-- Builds the editor in a settings page, below y (the page's other options).
function MessagesWindow.build(page, width, y)
    local header = Widgets.header(page, "Texts")
    header:SetPoint("TOPLEFT", 18, y)
    local intro = Widgets.text(page, "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", 20, y - 24)
    intro:SetWidth(width - 40)
    intro:SetText(L[INTRO])
    local scroll = CreateFrame("ScrollFrame", nil, page, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, y - 80)
    scroll:SetPoint("BOTTOMRIGHT", -34, 4)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(width - 60, #Messages.LIST * ROW)
    scroll:SetScrollChild(content)
    for i, message in ipairs(Messages.LIST) do
        rows[#rows + 1] = buildRow(content, width, message, -(i - 1) * ROW)
    end
end

function MessagesWindow.refresh()
    for _, row in ipairs(rows) do
        paint(row)
    end
end

function MessagesWindow.show()
    ns.Settings.show("messages")
end

function MessagesWindow.toggle()
    ns.Settings.toggle("messages")
end

-- The row of one message, for the tests.
function MessagesWindow.row(id)
    for _, row in ipairs(rows) do
        if row.message.id == id then
            return row
        end
    end
end

ns.MessagesWindow = MessagesWindow
