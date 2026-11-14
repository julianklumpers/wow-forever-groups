local World = require("tests.helpers.wowmock")

local CONNECT = 30

describe("searching on input", function()
    it("starts once a fight that was going on at login is over", function()
        local world = World.new()
        local solo = world:addClient("Solo Dps", { level = 20, inCombat = true })
        world:advance(CONNECT)
        assert.is_nil(solo.env.ForeverGroupsKeySearchFrame)
        solo.inCombat = false
        solo:fire("PLAYER_REGEN_ENABLED")
        assert.is_not_nil(solo.env.ForeverGroupsKeySearchFrame)
        assert.is_true(solo.ns.KeySearch.isReady())
    end)
end)

describe("the addon's steps every second", function()
    it("go on when one of them fails", function()
        local world = World.new()
        local solo = world:addClient("Solo Dps", { level = 20 })
        world:advance(CONNECT)
        local errors = {}
        solo.env.seterrorhandler(function(err)
            errors[#errors + 1] = err
        end)
        solo.ns.BgFinder.tick = function()
            error("broken")
        end
        local ran = 0
        local apply = solo.ns.Apply.tick
        solo.ns.Apply.tick = function(...)
            ran = ran + 1
            return apply(...)
        end
        world:advance(3)
        assert.is_true(ran >= 2)
        assert.is_true(#errors >= 2)
    end)
end)

describe("a refused zone search", function()
    it("goes again on the next input instead of waiting for the old results to age", function()
        local world = World.new()
        world:list("Zone Tank", "T", 9001, 20, 300)
        local client = world:addClient("Solo Quester", { level = 20, questLog = {
            { "Elwynn Forest", true }, { "Hogger", false, 176, 1 },
        } })
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("Button", "Quests")
        world:advance(25)
        client.throttle = 1
        local searches = client.searches
        client:press("W")
        world:advance(1)
        assert.are.equal(searches + 1, client.searches)
        assert.is_true(client.ns.LfgList.secondsSinceZoneSearch() > 5)
        world:advance(5)
        client:press("W")
        world:advance(1)
        assert.are.equal(searches + 2, client.searches)
        assert.is_true(client.ns.LfgList.secondsSinceZoneSearch() < 5)
    end)
end)

describe("results of a search in another category of WoW's Group Finder", function()
    it("leave the dungeon listings alone", function()
        local world = World.new()
        world:list("Dm Dps", "D", 799)
        world:list("Custom Group", "D", 5555)
        local solo = world:addClient("Solo Dps", { level = 20 })
        world:advance(CONNECT)
        solo:slash("/dq")
        world:advance(1)
        assert.are.equal(1, #solo.ns.LfgList.listings())
        world:advance(6)
        solo.inClick, solo.clickSearched = true, false
        solo.env.C_LFGList.Search(120, 0, 0, nil, false, nil, { 5555 })
        solo.inClick = false
        world:advance(1)
        assert.are.equal(1, #solo.ns.LfgList.listings())
        assert.are.equal("Dm Dps", solo.ns.LfgList.listings()[1].name)
    end)
end)

describe("an asked group that leaves the Group Finder", function()
    it("is over at once, and the next group is asked without waiting for a search", function()
        local world = World.new()
        local first = world:listGroup("Four Of Five", 799, { T = 0, H = 0, D = 1 })
        world:listGroup("Three Of Five", 799, { T = 0, H = 1, D = 1 })
        local solo = world:addClient("Solo Dps", { level = 20 })
        world:advance(CONNECT)
        solo:slash("/dq join dps dm")
        world:advance(1)
        local function asked()
            local names = {}
            for _, w in ipairs(solo.whispers) do
                if w.text:find("could you invite me") then
                    names[#names + 1] = w.target
                end
            end
            return names
        end
        assert.are.same({ "Four Of Five" }, asked())
        local searches = solo.searches
        world.listings[first].isDelisted = true
        solo:fire("LFG_LIST_SEARCH_RESULT_UPDATED", first)
        world:advance(3)
        assert.are.equal(searches, solo.searches)
        assert.are.same({ "Four Of Five", "Three Of Five" }, asked())
    end)
end)
