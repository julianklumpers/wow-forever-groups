local _, ns = ...

local Log = ns.Log

-- Keeps the Group Finder results fresh while the player plays. A search is
-- only allowed straight after player input, so this listens to the player's
-- own key presses (the frame lets every key through to the game) and mouse
-- clicks on the 3D world (verified in-game 2026-11-12) and, while the group
-- still needs players, refreshes the search at most every 10 s.
local KeySearch = {}

local INTERVAL = 10
-- While queued or filling, results are kept at most this old, so a decliner
-- is replaced at once and new listings are seen.
local FRESH = 30

local frame
local ready = false
local worldHooked = false

local function onInput()
    if not ns.db or InCombatLockdown() or ns.Input.run() or not ns.Features.refresh() then
        return
    end
    if ns.LfgList.secondsSinceAnySearch() < INTERVAL then
        return
    end
    if ns.QuestFinder.searchIfUseful(INTERVAL) or ns.Filler.searchIfUseful(INTERVAL) then
        return
    end
    -- The dungeon queue comes first: an open Who is looking on the Quests
    -- tab must not keep the dungeon results from being refreshed.
    if ns.Apply.isSeeker() and ns.LfgList.searchIfStale(INTERVAL) then
        return
    end
    if (ns.Filler.isActive() or (ns.engine and ns.engine.myEntry)) and ns.LfgList.searchIfStale(FRESH) then
        return
    end
    if ns.QueueWindow.isShown() then
        ns.QueueWindow.searchIfStale(INTERVAL)
    elseif ns.Window.isShown() then
        ns.QueueWindow.searchIfStale(FRESH, ns.WindowParts.currentTab())
    end
end

-- Sets the frame up out of combat. If the game would not pass keys through,
-- the frame stays off so it can never swallow the player's keys.
function KeySearch.init()
    if frame or InCombatLockdown() then
        return
    end
    frame = CreateFrame("Frame", "ForeverGroupsKeySearchFrame", UIParent)
    if not worldHooked and WorldFrame and WorldFrame.HookScript then
        worldHooked = pcall(WorldFrame.HookScript, WorldFrame, "OnMouseDown", onInput)
    end
    local ok = pcall(frame.SetPropagateKeyboardInput, frame, true)
    local passes = ok and (not frame.GetPropagateKeyboardInput or frame:GetPropagateKeyboardInput())
    if not passes then
        Log.debug("key search unavailable: keys would not pass through")
        return
    end
    frame:SetScript("OnKeyDown", onInput)
    ready = pcall(frame.EnableKeyboard, frame, true)
    Log.debug("key search %s", ready and "ready" or "unavailable")
end

function KeySearch.isReady()
    return ready and ns.Features.refresh()
end

function KeySearch.toggle()
    ns.db.autoSearchOff = not ns.db.autoSearchOff
    return not ns.db.autoSearchOff
end

ns.KeySearch = KeySearch
