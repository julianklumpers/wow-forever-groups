local World = require("tests.helpers.wowmock")

local function fillingTank(listings)
    local world = World.new()
    local tank = world:addClient("Tanky Mctank", { level = 20 })
    for _, listing in ipairs(listings) do
        world:list(listing[1], listing[2], 799, 20, 300)
    end
    world:advance(30)
    tank:slash("/dq join tank dm")
    world:advance(2)
    assert.is_true(tank.ns.Filler.isActive())
    return world, tank
end

describe("party changes while filling", function()
    it("keeps the queue place when a Group Finder invitee joins", function()
        local world, tank = fillingTank({ { "Listed Heal", "H" }, { "Dps One", "D" }, { "Dps Two", "D" } })
        assert.are.equal("HDD", tank.ns.engine.myEntry.reserved)
        tank:joins("Listed Heal")
        world:advance(1)
        local entry = tank.ns.engine.myEntry
        assert.is_not_nil(entry)
        assert.are.equal(2, #entry.members)
        assert.are.equal("DD", entry.reserved)
    end)

    it("goes back into the queue at the old place when the last spots open up again", function()
        local world, tank = fillingTank({ { "Listed Heal", "H" }, { "Dps One", "D" }, { "Dps Two", "D" },
            { "Dps Three", "D" } })
        world:advance(5)
        assert.is_nil(tank.ns.engine.myEntry)
        tank:system(string.format(tank.env.ERR_DECLINE_GROUP_S, "Dps Three"))
        world:advance(6)
        local entry = tank.ns.engine.myEntry
        assert.is_not_nil(entry)
        assert.is_true(tank:said("back in the queue at your old place"))
    end)

    it("leaves the queue when the player is no longer the party leader", function()
        local world = World.new()
        local leader = world:addClient("Tanky Mctank", { level = 20 })
        world:advance(30)
        leader.party, leader.isLeader = { "Friend Person" }, true
        leader.roles["Friend Person"] = "DAMAGER"
        leader:slash("/dq")
        leader:click("CheckButton", "Tank")
        leader:click("Button", "Find group")
        assert.is_not_nil(leader.ns.engine.myEntry)
        leader.isLeader = false
        leader:fire("GROUP_ROSTER_UPDATE")
        world:advance(1)
        assert.is_nil(leader.ns.engine.myEntry)
        assert.is_true(leader:said("no longer the party leader"))
        assert.is_false(leader:said("You left the queue%."))
    end)

    it("keeps Group Finder invitees after a /reload", function()
        local world, tank = fillingTank({ { "Listed Heal", "H" } })
        local saved = tank:logout()
        local again = world:addClient("Tanky Mctank", { level = 20, saved = saved })
        world:advance(8)
        assert.is_not_nil(again.ns.engine.myEntry)
        again:joins("Listed Heal")
        world:advance(6)
        assert.is_not_nil(again.ns.engine.myEntry)
        assert.are.equal(2, #again.ns.engine.myEntry.members)
    end)
end)
