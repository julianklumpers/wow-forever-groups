local World = require("tests.helpers.wowmock")

local LANGUAGES = { false, false, "enUS", "deDE", "ruRU" }
local OUTSIDE_LANGUAGES = { "none", "own", "enUS", "enUS,deDE", "enUS,ruRU", "empty" }
local ACTIVITIES = { 799, 796 }

local function rng(seed)
    local state = seed
    return function(n)
        state = (state * 1103515245 + 12345) % 2147483648
        return math.floor(state / 65536) % n + 1
    end
end

local function input(client, fn)
    client.inClick, client.clickSearched = true, false
    client.inputs = (client.inputs or 0) + 1
    local a, b = fn()
    client.inClick = false
    return a, b
end

local function languageSet(text)
    if text == "none" then
        return nil
    elseif text == "own" then
        return { enUS = true }
    elseif text == "empty" then
        return {}
    end
    local set = {}
    for code in string.gmatch(text, "[^,]+") do
        set[code] = true
    end
    return set
end

local function run(seed, steps)
    local roll = rng(seed)
    local world = World.new()
    local solo = world:addClient("Solo Dps", { level = 20 })
    world:advance(30)
    local LfgList = solo.ns.LfgList
    local german = false
    local count = 0
    local function addListing()
        count = count + 1
        local roles = ({ "T", "H", "D" })[roll(3)]
        world:list(string.format("Leader %03d", count), roles, ACTIVITIES[roll(2)], 20, roll(600))
        world.listings[#world.listings].language = LANGUAGES[roll(#LANGUAGES)] or nil
    end
    for _ = 1, 8 do
        addListing()
    end
    local byName = {}
    local function index()
        for _, listing in ipairs(world.listings) do
            byName[listing.leaderName] = listing
        end
    end
    local function allowed(listing)
        return listing.language == nil or listing.language == "enUS" or (german and listing.language == "deDE")
    end

    local function check(where)
        index()
        local seen = {}
        for _, kind in ipairs({ "listings", "zoneListings", "battlegroundListings" }) do
            local list = kind == "listings" and LfgList.listings() or (LfgList[kind] and LfgList[kind]()) or {}
            for _, listing in ipairs(list) do
                assert(not seen[listing.name], where .. listing.name .. " is in two lists or twice")
                seen[listing.name] = true
                local truth = byName[listing.name]
                assert(truth == nil or allowed(truth), where .. listing.name .. " speaks "
                    .. tostring(truth and truth.language) .. ", which the player does not group with")
            end
        end
        assert(solo.blockedSearches == 0, where .. "a search of ours was blocked by WoW")
        assert(not solo:logged("throttled %(ours%)"), where .. "the server refused a search of ours")
    end

    for step = 1, steps do
        local where = "seed " .. seed .. ", step " .. step .. ": "
        local event = roll(12)
        if event <= 3 then
            input(solo, function()
                return LfgList.search()
            end)
        elseif event <= 5 then
            local languages = languageSet(OUTSIDE_LANGUAGES[roll(#OUTSIDE_LANGUAGES)])
            local activities = roll(3) == 1 and nil or { ACTIVITIES[roll(2)] }
            input(solo, function()
                solo.env.C_LFGList.Search(2, 0, 0, languages, false, nil, activities)
            end)
        elseif event == 6 then
            input(solo, function()
                solo.env.C_LFGList.ClearSearchResults()
            end)
        elseif event == 7 and roll(3) == 1 then
            german = not german
            solo.ns.MatchLanguages.set("deDE", german)
        elseif event == 8 then
            addListing()
        elseif event == 10 and roll(3) == 1 then
            addListing()
            local listing = world.listings[#world.listings]
            listing.stray, listing.activityIDs = true, { 811 }
        elseif event == 9 then
            input(solo, function()
                solo.env.C_LFGList.Search(2, 0, 0, nil, false, nil, { 799 })
                return LfgList.search()
            end)
        end
        world:advance(roll(30) / 10)
        check(where)
    end

    for _ = 1, 12 do
        input(solo, function()
            return LfgList.searchIfStale(0)
        end)
        world:advance(3)
    end
    check("seed " .. seed .. ", at the end: ")
    index()
    local listed = {}
    for _, listing in ipairs((LfgList.listings())) do
        listed[listing.name] = true
    end
    for name, truth in pairs(byName) do
        if allowed(truth) and not truth.stray then
            assert(listed[name], "seed " .. seed .. ": " .. name .. " is listed but never came in")
        end
    end
end

describe("searches of ours and other addons in any order", function()
    it("never bring in other languages, never get ours refused or blocked, and catch up", function()
        local seeds = tonumber(os.getenv("FUZZ_SEEDS")) or 20
        local steps = tonumber(os.getenv("FUZZ_STEPS")) or 150
        for seed = 1, seeds do
            run(20261117 + seed, steps)
        end
    end)
end)
