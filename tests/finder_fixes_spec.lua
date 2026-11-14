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
