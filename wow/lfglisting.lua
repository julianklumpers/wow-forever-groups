local _, ns = ...

local Dungeons = ns.Dungeons
local Fill = ns.Fill
local Input = ns.Input
local Log = ns.Log

-- While Forever Groups fills a group, it also lists that group in WoW's Group
-- Finder, so players browsing there can apply. A questing group waiting for
-- players is listed in its quest's zone instead, when no dungeon group needs
-- the listing (WoW allows one at a time). Applicants with a role the
-- group still needs are invited; the listing is removed when the group is
-- complete or filling stops. The exact CreateListing arguments differ between
-- WoW versions, so a few known shapes are tried.
local Listing = {}

local MAX_FAILURES = 3
local CONFIRM_TIME = 5

local ours = false
-- What our listing is for ("dungeon:799,800" or "quest:9001"), so a changed
-- target replaces it.
local listedKey
local listedAt
local failures = 0
local handled = {}

local function call(name, ...)
    local fn = C_LFGList and C_LFGList[name]
    if type(fn) ~= "function" then
        return false, "missing"
    end
    return pcall(fn, ...)
end

local function isListed()
    local ok, listed = call("HasActiveEntryInfo")
    return ok and listed == true
end

local function activities()
    local ids = {}
    for _, id in ipairs(ns.Filler.dungeonIds()) do
        local dungeon = Dungeons.get(id)
        if dungeon and dungeon.lfg then
            ids[#ids + 1] = dungeon.lfg
        end
    end
    return ids
end

local function wantsDungeonListing()
    if not ns.Filler.isActive() or #activities() == 0 then
        return false
    end
    local view = ns.GroupView.status()
    return ns.Filler.stillNeeded() ~= "" and not (view and view.complete)
end

-- { ids, name } of what to list, or nil.
local function wanted()
    local state = ns.Party.state()
    if not ns.Features.listing() or failures >= MAX_FAILURES or (state ~= "solo" and state ~= "leader") then
        return nil
    end
    if wantsDungeonListing() then
        local id = ns.Filler.dungeon() or ns.Filler.dungeonIds()[1]
        local ids = activities()
        return { ids = ids, name = Dungeons.name(id), key = "dungeon:" .. table.concat(ids, ",") }
    end
    local quest = ns.QuestFinder.listing()
    if quest then
        return { ids = { quest.activity }, name = quest.name, key = "quest:" .. quest.activity }
    end
    return nil
end

local function createListing()
    local target = wanted()
    if not target then
        return
    end
    local ids = target.ids
    local shapes = {
        { "table", function()
            return call("CreateListing", {
                activityIDs = ids, isAutoAccept = false, isPrivateGroup = false,
                generalPlaystyle = ns.Playstyle.listingValue(), isCrossFactionListing = false,
            })
        end },
        { "positional", function()
            return call("CreateListing", ids, 0, 0, false, false)
        end },
        { "activities only", function()
            return call("CreateListing", ids)
        end },
    }
    for _, shape in ipairs(shapes) do
        local ok, err = shape[2]()
        Log.debug("CreateListing (%s): %s", shape[1], ok and "ok" or tostring(err))
        if ok then
            ours, listedAt, listedKey = true, GetTime(), target.key
            Log.info("Your group is listed in WoW's Group Finder for %s.", target.name)
            return
        end
    end
    failures = MAX_FAILURES
    Log.debug("listing the group is not possible in this client")
end

local function removeListing()
    call("RemoveListing")
    ours, listedKey = false, nil
end

function Listing.tick()
    if ours and not isListed() and listedAt and GetTime() - listedAt > CONFIRM_TIME then
        -- The call went through but nothing was listed: WoW blocked it quietly.
        ours = false
        failures = failures + 1
        Log.debug("the Group Finder listing did not appear (%d/%d)", failures, MAX_FAILURES)
    end
    local target = wanted()
    local want = target ~= nil
    if want and ours and target.key ~= listedKey then
        want = false
    end
    if want then
        Input.cancel("unlist")
    end
    if want and not ours and not isListed() then
        Input.queue("list", "list your group", createListing)
    elseif not want then
        Input.cancel("list")
        if ours then
            Input.queue("unlist", "remove your listing", removeListing)
        end
    end
end

-- GetApplicantMemberInfo returns a table in some versions and separate values
-- (name, class, localizedClass, level, itemLevel, honorLevel, tank, healer,
-- damage) in others.
local function applicantMember(id)
    local ok, a, _, _, level, _, _, tank, healer, damage = call("GetApplicantMemberInfo", id, 1)
    if not ok then
        return nil
    end
    if type(a) == "table" then
        return { name = a.name, level = a.level, tank = a.tank, healer = a.healer, damage = a.damage }
    end
    return { name = a, level = level, tank = tank, healer = healer, damage = damage }
end

function Listing.checkApplicants()
    if not ours or not ns.Filler.isActive() or not string.find(listedKey or "", "^dungeon:") then
        return
    end
    local ok, ids = call("GetApplicants")
    if not ok or type(ids) ~= "table" then
        return
    end
    local dungeon = ns.Filler.dungeon()
    local candidates, byName = {}, {}
    for _, id in ipairs(ids) do
        local infoOk, info = call("GetApplicantInfo", id)
        local member = applicantMember(id)
        local readable = infoOk and type(info) == "table" and not ns.isSecret(info.applicationStatus)
            and not ns.isSecret(info.numMembers) and member and not ns.isSecret(member.name)
        if readable and info.applicationStatus == "applied"
            and (info.numMembers or 1) == 1 and not handled[id] and type(member.name) == "string" then
            local roles = (member.tank and "T" or "") .. (member.healer and "H" or "") .. (member.damage and "D" or "")
            if roles ~= "" then
                candidates[#candidates + 1] = {
                    name = member.name, roles = roles, dungeons = { dungeon }, solo = true,
                    level = tonumber(member.level), age = 0,
                }
                byName[member.name] = id
            end
        end
    end
    local entry = Dungeons.get(dungeon)
    local picks = Fill.pick(candidates, {
        missing = ns.Filler.stillNeeded(), dungeon = dungeon, exclude = ns.Filler.excluded(),
        range = entry and entry.min and { min = entry.min, max = entry.max } or nil,
    })
    for _, pick in ipairs(picks) do
        local id = byName[pick.name]
        local roleName = ns.Widgets.ROLE_NAMES[pick.role]
        handled[id] = true
        if ns.db.dryRun then
            Log.info("Dry run: would invite applicant %s as %s.", pick.name, roleName)
        elseif ns.Filler.trackInvite(pick.name, pick.role) then
            Input.queue("applicant:" .. id, "invite applicant " .. pick.name, function()
                C_LFGList.InviteApplicant(id)
                Log.info("Invited %s, who applied to your group, as %s.", pick.name, roleName)
            end)
        end
    end
end

-- For /fg selftest: "listed", "refused" (WoW turned our listings down) or
-- "not tried".
function Listing.status()
    if listedKey or ours then
        return "listed"
    elseif failures > 0 then
        return "refused"
    end
    return "not tried"
end

function Listing.isOurs()
    return ours
end

-- "dungeon" or "quest": what our own listing is for, or nil.
function Listing.listedFor()
    return ours and listedKey and string.match(listedKey, "^(%a+):") or nil
end

function Listing.init()
    ns.on("LFG_LIST_APPLICANT_LIST_UPDATED", Listing.checkApplicants)
    ns.on("LFG_LIST_APPLICANT_UPDATED", Listing.checkApplicants)
    ns.on("LFG_LIST_ACTIVE_ENTRY_UPDATE", function()
        if not isListed() then
            ours = false
        end
    end)
    ns.on("LFG_LIST_ENTRY_CREATION_FAILED", function()
        ours = false
        failures = failures + 1
        Log.debug("WoW refused the Group Finder listing (%d/%d)", failures, MAX_FAILURES)
    end)
end

ns.Listing = Listing
