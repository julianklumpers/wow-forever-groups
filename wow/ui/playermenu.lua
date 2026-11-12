local _, ns = ...

local Widgets = ns.Widgets
local Log = ns.Log

-- The right-click menu on a player in a list: whisper them or invite them.
-- WoW's own context menu when the client has it, else a small menu of ours.
local PlayerMenu = {}

local MENU_WIDTH = 170
local ITEM_HEIGHT = 20

local fallback

local function canInvite()
    return not IsInGroup() or UnitIsGroupLeader("player") == true
end

-- Opens the chat line with "/w Name " so the player types the message.
function PlayerMenu.whisper(name)
    if type(ChatFrameUtil) == "table" and type(ChatFrameUtil.SendTell) == "function" then
        ChatFrameUtil.SendTell(name)
    elseif type(ChatFrame_SendTell) == "function" then
        ChatFrame_SendTell(name)
    elseif type(ChatFrame_OpenChat) == "function" then
        ChatFrame_OpenChat("/w " .. name .. " ")
    end
end

function PlayerMenu.invite(name)
    local ok, err = pcall(C_PartyInfo.InviteUnit, name)
    if ok then
        Log.info("Invited %s.", name)
    else
        Log.warn("Inviting %s failed: %s", name, tostring(err))
    end
end

local function actions(name)
    local list = { { label = "Whisper", run = function()
        PlayerMenu.whisper(name)
    end } }
    if canInvite() then
        list[#list + 1] = { label = "Invite to group", run = function()
            PlayerMenu.invite(name)
        end }
    end
    return list
end

local function buildFallback()
    fallback = CreateFrame("Frame", "ForeverGroupsPlayerMenu", UIParent)
    fallback:SetFrameStrata("DIALOG")
    fallback:SetClampedToScreen(true)
    fallback:EnableMouse(true)
    local background = fallback:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(0.05, 0.05, 0.06, 0.95)
    local border = fallback:CreateTexture(nil, "BORDER")
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetColorTexture(1, 0.82, 0, 0.35)
    fallback.title = Widgets.text(fallback, "GameFontNormalSmall")
    fallback.title:SetPoint("TOPLEFT", 10, -8)
    fallback.title:SetWidth(MENU_WIDTH - 20)
    fallback.title:SetWordWrap(false)
    fallback.items = {}
    table.insert(UISpecialFrames, "ForeverGroupsPlayerMenu")
    fallback:Hide()
end

local function fallbackItem(i)
    local item = fallback.items[i]
    if not item then
        item = CreateFrame("Button", nil, fallback)
        item:SetSize(MENU_WIDTH - 12, ITEM_HEIGHT)
        item:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        item.label = Widgets.text(item, "GameFontHighlightSmall")
        item.label:SetPoint("LEFT", 8, 0)
        fallback.items[i] = item
    end
    return item
end

local function showFallback(name, list)
    if not fallback then
        buildFallback()
    end
    fallback.title:SetText(name)
    for i, action in ipairs(list) do
        local item = fallbackItem(i)
        item:SetPoint("TOPLEFT", 6, -26 - (i - 1) * ITEM_HEIGHT)
        item.label:SetText(action.label)
        item:SetScript("OnClick", function()
            fallback:Hide()
            action.run()
        end)
        item:Show()
    end
    for i = #list + 1, #fallback.items do
        fallback.items[i]:Hide()
    end
    fallback:SetSize(MENU_WIDTH, 32 + #list * ITEM_HEIGHT)
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale() or 1
    fallback:ClearAllPoints()
    fallback:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale, y / scale)
    fallback:Show()
end

-- Opens the menu for a player; owner is the row that was clicked.
function PlayerMenu.open(owner, name)
    local list = actions(name)
    if type(MenuUtil) == "table" and type(MenuUtil.CreateContextMenu) == "function" then
        local ok = pcall(MenuUtil.CreateContextMenu, owner, function(_, root)
            root:CreateTitle(name)
            for _, action in ipairs(list) do
                root:CreateButton(action.label, action.run)
            end
        end)
        if ok then
            return
        end
    end
    showFallback(name, list)
end

function PlayerMenu.hide()
    if fallback then
        fallback:Hide()
    end
end

ns.PlayerMenu = PlayerMenu
