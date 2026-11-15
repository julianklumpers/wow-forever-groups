local _, ns = ...

local L = ns.L

-- The minimap button, made with LibDBIcon-1.0 (bundled in libs/) as most
-- addons do, so minimap tools such as Leatrix Plus handle it like any other.
-- It always shows the Forever Groups logo, also while searching; what
-- Forever Groups is doing is in its tooltip. Left-click opens the window,
-- right-click the settings, drag moves it. It pulses while a group proposal
-- waits for an answer.
local MinimapButton = {}

local NAME = "ForeverGroups"
local DEFAULT_ANGLE = 200
-- The logo cut to its gold ring, so the ring follows the button's round
-- edge: the ring runs from 66 to 333 of the logo's 400 pixels around (200,
-- 195), and LibDBIcon trims another 5% off each side.
local RING_COORDS = { 0.125, 0.875, 0.1125, 0.8625 }

local registered = false
local pulsing = false
local pulser

local function library()
    return LibStub and LibStub("LibDBIcon-1.0", true), LibStub and LibStub("LibDataBroker-1.1", true)
end

-- Where LibDBIcon keeps the button (ns.db.minimapIcon); the angle saved
-- before it carries over.
local function settings()
    local saved = ns.db.minimapIcon
    if type(saved) ~= "table" then
        saved = { minimapPos = ns.db.minimapAngle or DEFAULT_ANGLE }
        ns.db.minimapIcon = saved
    end
    saved.hide = ns.db.minimapHidden == true
    return saved
end

-- A line of what a click does, as minimap buttons usually show it.
local function hint(tooltip, action, result)
    tooltip:AddLine("|cffffffff" .. L[action] .. "|r |cffffd100" .. L[result] .. "|r")
end

local function fillTooltip(tooltip)
    tooltip:AddLine("Forever Groups")
    local status = ns.Status.current()
    if status then
        tooltip:AddLine(L[status.text], 1, 1, 1, true)
        if status.detail then
            tooltip:AddLine(L[status.detail], 0.8, 0.8, 0.8, true)
        end
    else
        tooltip:AddLine(L["Not in the queue."], 1, 1, 1)
    end
    local connection = ns.Comm.connection()
    tooltip:AddLine(string.format(L["Channel: %s"], L[connection.text]), 0.6, 0.8, 1)
    hint(tooltip, "left click:", "open the window")
    hint(tooltip, "right click:", "settings")
    hint(tooltip, "drag:", "move the button")
end

local function onClick(_, mouseButton)
    if not ns.Input.run() then
        ns.Filler.searchIfUseful(30)
    end
    if mouseButton == "RightButton" then
        ns.Settings.toggle()
    else
        ns.Window.toggle()
    end
end

local function register()
    local icon, broker = library()
    if not icon or not broker then
        return false
    end
    local object = broker:NewDataObject(NAME, {
        type = "launcher", label = "Forever Groups", icon = ns.Widgets.ICON, iconCoords = RING_COORDS,
        OnClick = onClick, OnTooltipShow = fillTooltip,
    })
    icon:Register(NAME, object, settings())
    -- The pulse while a proposal waits: the logo fades in and out.
    pulser = CreateFrame("Frame")
    pulser:SetScript("OnUpdate", function()
        local button = icon:GetMinimapButton(NAME)
        if pulsing and button and button.icon then
            button.icon:SetAlpha(0.55 + 0.45 * math.abs(math.sin(GetTime() * 3)))
        end
    end)
    return true
end

function MinimapButton.refresh()
    if not Minimap or not ns.db then
        return
    end
    if not registered then
        registered = register()
        if not registered then
            return
        end
    end
    local icon = library()
    settings()
    if ns.db.minimapHidden then
        icon:Hide(NAME)
        return
    end
    icon:Show(NAME)
    local status = ns.Status.current()
    local wasPulsing = pulsing
    pulsing = status ~= nil and status.alert == true
    local button = icon:GetMinimapButton(NAME)
    if wasPulsing and not pulsing and button and button.icon then
        button.icon:SetAlpha(1)
    end
end

function MinimapButton.toggle()
    ns.db.minimapHidden = not ns.db.minimapHidden
    MinimapButton.refresh()
    return not ns.db.minimapHidden
end

ns.MinimapButton = MinimapButton
