local _, ns = ...

local W = ns.WindowParts
local Widgets = ns.Widgets
local L = ns.L

-- A short tour of the main window the first time it opens: a gold outline
-- around one part at a time and a bubble that explains it, with Next and
-- Skip. ns.db.tourSeen: false while a new player has not seen it, true once
-- finished or skipped (and for players who used Forever Groups before it
-- came), until the settings or /fg tour bring it back. Steps whose part is not on screen
-- (the tabs before the other queues are offered) are left out.
local Tour = {}

local BUBBLE_WIDTH = 290
local GOLD = { 1, 0.82, 0, 1 }

local function shown(frame)
    return frame ~= nil and frame:IsVisible()
end

-- Each step: the first and last frame of the part to outline, and where the
-- bubble goes ("below" or "above" it).
local STEPS = {
    {
        text = ns.Locale.mark("Tick every role you can play. Forever Groups gives you the one a group needs most."),
        place = "below",
        target = function()
            local first, last = W.roleToggles.T, W.roleToggles.D
            return shown(first) and shown(last) and first, last
        end,
    },
    {
        text = ns.Locale.mark("These numbers count the tanks, healers and DPS looking for the dungeons you ticked, " ..
            "in Forever Groups and in WoW's Group Finder, and how many listed groups have a place for you."),
        place = "below",
        target = function()
            local ui = W.ui
            if shown(ui.headerLooking) then
                local groups = ui.headerLookingGroups
                return ui.headerLooking, shown(groups) and (groups:GetText() or "") ~= "" and groups
                    or ui.headerLooking
            end
            local card = ui.card
            if not card or not shown(card.lookingLabel) then
                return false
            end
            local groups = card.lookingGroups
            local last = shown(groups) and (groups:GetText() or "") ~= "" and groups or card.looking
            return card.lookingLabel, last
        end,
    },
    {
        text = ns.Locale.mark("Who is looking: the tab with the eye opens a list beside this window of everyone " ..
            "looking for your dungeons or group quests right now, from Forever Groups and WoW's Group Finder. " ..
            "Right-click a player to whisper or invite, a group to ask to join."),
        place = "below",
        target = function()
            local tab = ns.QueueWindow.handle()
            return shown(tab) and tab, tab
        end,
    },
    {
        text = ns.Locale.mark("Tick the dungeons you would like to run. Those for your level are ticked already; " ..
            "Other dungeons has the rest."),
        place = "below",
        target = function()
            local header = W.ui.dungeonHeader
            return shown(header) and header, header
        end,
    },
    {
        text = ns.Locale.mark("Each row shows the dungeon's level range, your quests there, the listed groups with " ..
            "room for you, and how many players look per role. Hover a row to see those groups."),
        place = "below",
        target = function()
            for _, cell in ipairs(W.dungeonCells) do
                if shown(cell) then
                    return cell, cell
                end
            end
            return false
        end,
    },
    {
        text = ns.Locale.mark("Questing and battleground groups have their own tabs. You can wait for all of them " ..
            "at once."),
        place = "below",
        target = function()
            local tabs = W.ui.tabs or {}
            local first, last = tabs.dungeons, tabs.battlegrounds or tabs.quests
            return shown(first) and shown(last) and first, last
        end,
    },
    {
        text = ns.Locale.mark("Find group puts you in the queue, and Forever Groups does the rest by itself: it " ..
            "matches you with other players who have the addon and fills open places from WoW's Group Finder. " ..
            "When your group is ready, accept the popup and the invites arrive on their own."),
        place = "above",
        target = function()
            local join = W.ui.join
            return shown(join) and join, join
        end,
    },
    {
        text = ns.Locale.mark("While you wait, just keep playing: your key presses and clicks refresh WoW's Group " ..
            "Finder. /fg or the minimap button opens this window again."),
        place = "above",
        target = function()
            local join = W.ui.join
            return shown(join) and join, join
        end,
    },
}

local ui = {}
local current

-- Above the window and its border: the tour's frames live on UIParent in a
-- higher strata, scaled like the window, and follow it when it hides.
local STRATA = "FULLSCREEN_DIALOG"
local DIM = { 0, 0, 0, 0.6 }

local function layer(kind, level)
    local frame = Widgets.backdropFrame(kind, UIParent)
    frame:SetFrameStrata(STRATA)
    frame:SetFrameLevel(level)
    frame:Hide()
    return frame
end

-- The window darkened around the highlighted part: four bands, above,
-- below, left and right of it, placed from both frames' edges (the window
-- may change height, so they are placed again a few times a second).
local function placeDim()
    local window, spot = W.frame, ui.highlight
    local wl, wr, wt, wb = window:GetLeft(), window:GetRight(), window:GetTop(), window:GetBottom()
    local sl, sr, st, sb = spot:GetLeft(), spot:GetRight(), spot:GetTop(), spot:GetBottom()
    if not (wl and wr and wt and wb and sl and sr and st and sb) then
        ui.dim:SetAlpha(0)
        return
    end
    ui.dim:SetAlpha(1)
    local top, bottom, left, right = unpack(ui.dim.bands)
    for _, band in ipairs(ui.dim.bands) do
        band:ClearAllPoints()
    end
    top:SetPoint("TOPLEFT", window, "TOPLEFT")
    top:SetPoint("BOTTOMRIGHT", window, "TOPRIGHT", 0, math.min(0, st - wt))
    bottom:SetPoint("TOPLEFT", window, "BOTTOMLEFT", 0, math.max(0, sb - wb))
    bottom:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT")
    left:SetPoint("TOPLEFT", window, "TOPLEFT", 0, st - wt)
    left:SetPoint("BOTTOMRIGHT", window, "TOPLEFT", math.max(0, sl - wl), sb - wt)
    right:SetPoint("TOPLEFT", window, "TOPLEFT", math.min(wr - wl, sr - wl), st - wt)
    right:SetPoint("BOTTOMRIGHT", window, "TOPRIGHT", 0, sb - wt)
end

local function buildDim()
    local dim = layer("Frame", 1)
    dim.bands = {}
    for i = 1, 4 do
        local band = dim:CreateTexture(nil, "BACKGROUND")
        band:SetColorTexture(DIM[1], DIM[2], DIM[3], DIM[4])
        dim.bands[i] = band
    end
    local elapsed = 0
    dim:SetScript("OnUpdate", function(_, delta)
        elapsed = elapsed + (delta or 0)
        if elapsed >= 0.25 and current then
            elapsed = 0
            placeDim()
            ui.placeBubble(current.steps[current.index].place)
        end
    end)
    return dim
end

local function setShown(visible)
    for _, frame in ipairs({ ui.dim, ui.highlight, ui.bubble }) do
        frame:SetShown(visible)
    end
end

local function build()
    ui.dim = buildDim()
    local highlight = layer("Frame", 2)
    Widgets.addOutline(highlight)
    Widgets.paintOutline(highlight, { 1, 0.82, 0, 0.05 }, GOLD)
    highlight:SetScript("OnUpdate", function(self)
        self:SetAlpha(0.55 + 0.45 * math.abs(math.sin(GetTime() * 3)))
    end)
    ui.highlight = highlight

    local bubble = layer("Frame", 3)
    Widgets.addOutline(bubble)
    Widgets.paintOutline(bubble, { 0.05, 0.05, 0.05, 0.97 }, { 1, 0.82, 0, 0.8 })
    bubble:SetWidth(BUBBLE_WIDTH)
    bubble:EnableMouse(true)
    bubble:SetClampedToScreen(true)
    bubble.text = Widgets.text(bubble, "GameFontHighlight")
    bubble.text:SetPoint("TOPLEFT", 12, -12)
    bubble.text:SetWidth(BUBBLE_WIDTH - 24)
    bubble.text:SetJustifyH("LEFT")
    bubble.count = Widgets.text(bubble, "GameFontDisableSmall")
    bubble.count:SetPoint("BOTTOMLEFT", 12, 13)
    bubble.next = Widgets.button(bubble, "Next", 80)
    bubble.next:SetPoint("BOTTOMRIGHT", -10, 9)
    bubble.next:SetScript("OnClick", function()
        Tour.next()
    end)
    bubble.skip = Widgets.link(bubble, "Skip", function()
        Tour.finish()
    end)
    bubble.skip:SetPoint("RIGHT", bubble.next, "LEFT", -12, 0)
    ui.bubble = bubble

    -- The window steps aside for a group proposal, or the player closes it:
    -- the tour goes with it and comes back with it.
    W.frame:HookScript("OnHide", function()
        if current then
            setShown(false)
        end
    end)
    W.frame:HookScript("OnShow", function()
        if current then
            setShown(true)
        end
    end)
end

local function visibleSteps()
    local list = {}
    for _, step in ipairs(STEPS) do
        if step.target() then
            list[#list + 1] = step
        end
    end
    return list
end

-- The bubble under (or above) the part, left-aligned with it, or
-- right-aligned when it would stick out past the window's right edge.
local function placeBubble(place)
    local bubble, spot = ui.bubble, ui.highlight
    local vertical, other = "TOP", "BOTTOM"
    local gap = -8
    if place == "above" then
        vertical, other, gap = "BOTTOM", "TOP", 8
    end
    bubble:ClearAllPoints()
    bubble:SetPoint(vertical .. "LEFT", spot, other .. "LEFT", 0, gap)
    local right, windowRight = bubble:GetRight(), W.frame:GetRight()
    if type(right) == "number" and type(windowRight) == "number" and right > windowRight then
        bubble:ClearAllPoints()
        bubble:SetPoint(vertical .. "RIGHT", spot, other .. "RIGHT", 0, gap)
    end
end

ui.placeBubble = placeBubble

local function show(index)
    local step = current.steps[index]
    local first, last = step.target()
    if not first then
        Tour.next()
        return
    end
    local scale = W.frame:GetScale() or 1
    for _, frame in ipairs({ ui.dim, ui.highlight, ui.bubble }) do
        frame:SetScale(scale)
    end
    ui.highlight:ClearAllPoints()
    ui.highlight:SetPoint("TOPLEFT", first, "TOPLEFT", -5, 5)
    ui.highlight:SetPoint("BOTTOMRIGHT", last, "BOTTOMRIGHT", 5, -5)
    local bubble = ui.bubble
    bubble.text:SetText(L[step.text])
    bubble.count:SetText(string.format("%d/%d", index, #current.steps))
    bubble.next:SetText(L[index == #current.steps and "Done" or "Next"])
    bubble.skip:SetShown(index < #current.steps)
    bubble:SetHeight(math.ceil(bubble.text:GetStringHeight() or 30) + 56)
    setShown(true)
    placeDim()
    placeBubble(step.place)
end

function Tour.isActive()
    return current ~= nil
end

-- Starts the tour on the window as it is now; false while the window shows
-- no setup (in a group, queued): a tour of a part or two would be the only
-- one the player gets, so it waits for a later opening.
function Tour.start()
    if not W.frame or not W.frame:IsShown() or not STEPS[1].target() then
        return false
    end
    local steps = visibleSteps()
    if not ui.bubble then
        build()
    end
    current = { steps = steps, index = 1 }
    show(1)
    return true
end

function Tour.next()
    if not current then
        return
    end
    current.index = current.index + 1
    if current.index > #current.steps then
        Tour.finish()
        return
    end
    show(current.index)
end

function Tour.finish()
    current = nil
    ns.db.tourSeen = true
    if ui.bubble then
        setShown(false)
    end
end

-- After the main window opened: the tour for a new player, once the window
-- has its layout.
function Tour.maybeStart()
    if ns.db.tourSeen ~= false or current then
        return
    end
    C_Timer.After(0.3, function()
        if ns.db.tourSeen == false and not current then
            Tour.start()
        end
    end)
end

local WELCOME_DELAY = 5

local function openForWelcome()
    if InCombatLockdown() then
        ns.on("PLAYER_REGEN_ENABLED", function()
            if not ns.db.welcomed then
                openForWelcome()
            end
        end)
        return
    end
    ns.db.welcomed = true
    ns.Window.show()
end

-- At login: on a new player's first login the window opens by itself a few
-- seconds in (after a fight, if one is going on), with the tour in it.
function Tour.welcome()
    if ns.db.tourSeen ~= false or ns.db.welcomed then
        return
    end
    C_Timer.After(WELCOME_DELAY, function()
        if not ns.db.welcomed then
            openForWelcome()
        end
    end)
end

-- From the settings or /fg tour: the tour again, on the Dungeons tab.
function Tour.restart()
    if current then
        Tour.finish()
    end
    ns.db.tourSeen = false
    ns.charDb.tab = "dungeons"
    ns.Window.show()
    ns.Window.refresh()
    if not Tour.start() then
        ns.Log.info("The tour shows the setup of the window; it starts the next time you open it outside a group.")
    end
end

ns.Tour = Tour
