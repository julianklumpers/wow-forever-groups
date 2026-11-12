local _, ns = ...

-- Which parts of WoW's Group Finder Forever Groups may use: one main switch
-- (the "Use WoW's Group Finder" setting) and, under it, a switch per part.
-- With the main switch off Forever Groups only works with other Forever Groups
-- players.
local Features = {}

local function setting(key)
    return ns.db ~= nil and ns.db[key] == true
end

function Features.groupFinder()
    return not setting("noGroupFinder")
end

local function part(key)
    return Features.groupFinder() and not setting(key)
end

-- Searching the Group Finder again on key presses while a group needs players.
function Features.refresh()
    return part("autoSearchOff")
end

-- Asking leaders of listed groups to invite the player.
function Features.apply()
    return part("noApply")
end

-- Inviting listed players to fill the player's group.
function Features.fill()
    return part("noFill")
end

-- Listing the player's group.
function Features.listing()
    return part("noListing")
end

-- Inviting players who whisper a needed role.
function Features.whisperInvite()
    return part("noWhisperInvite")
end

-- Whether the "looking now" counts are complete: they are once the Group
-- Finder was searched, or when it is not used at all (then only Forever Groups
-- players count).
function Features.countsKnown()
    return not Features.groupFinder() or ns.LfgList.hasSearched()
end

ns.Features = Features
