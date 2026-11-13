local _, ns = ...

local Widgets = ns.Widgets

-- A tab on WoW's own Group Finder (the side tabs on its right) that opens
-- the Forever Groups window. Only a launcher: WoW's Group Finder is secure
-- code, so its panels are never shown, swapped or read from here; a click
-- opens our window and closes theirs (HideUIPanel, out of combat only).
-- The same kind of tab LFGForever adds, built from WoW's own template.
local FinderTab = {}

local FINDER_ADDON = "Blizzard_GroupFinder_VanillaStyle"
local ICON_SIZE = 30

local tab

-- Under the last side tab: WoW's three, or another addon's tab under them
-- (LFGForever's), whichever loaded first.
local function place()
    local parent = LFGParentFrame
    local above = parent and parent.WhoListingTab
    local other = _G.LFGForeverBlizzardTab
    if type(other) == "table" and other ~= tab and other.GetParent and other:GetParent() == parent then
        above = other
    end
    if above then
        tab:ClearAllPoints()
        tab:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -2)
    end
end

local function closeFinder()
    if not InCombatLockdown() and type(HideUIPanel) == "function" then
        pcall(HideUIPanel, LFGParentFrame)
    end
end

local function build()
    local parent = LFGParentFrame
    if tab or type(parent) ~= "table" then
        return
    end
    local ok, frame = pcall(CreateFrame, "Frame", "ForeverGroupsFinderTab", parent, "LargeSideTabButtonTemplate")
    if not ok or not frame then
        ns.Log.debug("no tab on WoW's Group Finder: %s", tostring(frame))
        return
    end
    tab = frame
    if type(tab.Icon) == "table" then
        tab.Icon:SetTexture(Widgets.ICON)
        tab.Icon:SetSize(ICON_SIZE, ICON_SIZE)
    end
    if tab.SetFillToInterior then
        pcall(tab.SetFillToInterior, tab, true)
    end
    if tab.SetChecked then
        tab:SetChecked(false)
    end
    tab.tooltipText = "Forever Groups"
    local function open()
        ns.Window.show()
        closeFinder()
    end
    if tab.SetCustomOnMouseUpHandler then
        tab:SetCustomOnMouseUpHandler(function(_, button, upInside)
            if button == "LeftButton" and upInside then
                open()
            end
        end)
    else
        tab:SetScript("OnMouseUp", function(_, button)
            if button == "LeftButton" then
                open()
            end
        end)
    end
    tab:HookScript("OnShow", place)
    place()
end

function FinderTab.init()
    if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(FINDER_ADDON) then
        build()
        return
    end
    ns.on("ADDON_LOADED", function(name)
        if name == FINDER_ADDON then
            build()
        end
    end)
end

function FinderTab.tab()
    return tab
end

ns.FinderTab = FinderTab
