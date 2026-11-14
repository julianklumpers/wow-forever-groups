local World = require("tests.helpers.wowmock")

local CONNECT = 30

local STEPS = { "^Tick every role", "^Looking now counts", "^Who is looking: the tab", "^Tick the dungeons",
    "^Each row shows",
    "^Questing and battleground", "^Find group puts you", "^While you wait" }

local function step(client)
    for i, pattern in ipairs(STEPS) do
        if client:findText(pattern) then
            return i
        end
    end
    return nil
end

describe("the tour of the main window", function()
    it("shows a new player each part once, and stays away after", function()
        local world = World.new()
        local client = world:addClient("New Player", { level = 20, fresh = true })
        world:advance(CONNECT)
        assert.is_true(client.ns.Window.isShown())
        assert.are.equal(1, step(client))
        assert.is_not_nil(client:findText("^1/8$"))
        for expected = 2, 8 do
            client:click("Button", "Next")
            assert.are.equal(expected, step(client))
        end
        client:click("Button", "Done")
        assert.is_nil(step(client))
        assert.is_true(client.ns.db.tourSeen)
        client:slash("/fg")
        client:slash("/fg")
        world:advance(1)
        assert.is_nil(step(client))
    end)

    it("can be skipped, and comes back from /fg tour", function()
        local world = World.new()
        local client = world:addClient("New Player", { level = 20, fresh = true })
        world:advance(CONNECT)
        assert.is_true(client.ns.Window.isShown())
        client:click("Button", "Skip")
        assert.is_nil(step(client))
        assert.is_true(client.ns.db.tourSeen)
        client:slash("/fg tour")
        assert.are.equal(1, step(client))
    end)

    it("opens the window by itself at a new player's first login, after a fight", function()
        local world = World.new()
        local client = world:addClient("New Player", { level = 20, fresh = true, inCombat = true })
        world:advance(10)
        assert.is_false(client.ns.Window.isShown())
        client.inCombat = false
        client:fire("PLAYER_REGEN_ENABLED")
        world:advance(1)
        assert.is_true(client.ns.Window.isShown())
        assert.are.equal(1, step(client))
        client:click("Button", "Skip")
        local saved = client:logout()
        local again = world:addClient("New Player", { level = 20, saved = saved })
        world:advance(10)
        assert.is_false(again.ns.Window.isShown())
    end)

    it("is not shown to a player who used Forever Groups before", function()
        local world = World.new()
        local client = world:addClient("Old Hand", { level = 20 })
        world:advance(CONNECT)
        assert.is_false(client.ns.Window.isShown())
        client:slash("/fg")
        world:advance(1)
        assert.is_nil(step(client))
        assert.is_true(client.ns.db.tourSeen)
    end)

    it("waits while the window shows no setup, as in a group", function()
        local world = World.new()
        local client = world:addClient("Party Member", { level = 20, fresh = true })
        client.party, client.isLeader = { "Some Leader" }, false
        client:fire("GROUP_ROSTER_UPDATE")
        world:advance(CONNECT)
        assert.is_true(client.ns.Window.isShown())
        assert.is_nil(step(client))
        assert.is_false(client.ns.db.tourSeen)
    end)
end)
