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

    local function reload(world, client)
        local held, party = client.heldInvites, client.party
        local saved = client:logout()
        return world:addClient(client.name, { level = 20, saved = saved, beforeLogin = function(again)
            again.heldInvites, again.party, again.isLeader = held, party, #party > 0
        end })
    end

    it("keeps filling the last spots after a /reload, replacing a player who declines", function()
        local world = World.new()
        local tank = world:addClient("Solo Tank", { level = 20 })
        world:list("Heal A", "H", 799, 20, 900)
        world:list("Heal B", "H", 799, 20, 800)
        for i = 1, 6 do
            world:list("Dps " .. i, "D", 799, 20, 900 - i)
        end
        world:advance(30)
        tank.ns.charDb.wantsLead = true
        tank:slash("/dq join tank dm")
        world:advance(3)
        tank:joins("Heal A")
        world:advance(10)
        assert.is_nil(tank.ns.engine.myEntry)
        local again = reload(world, tank)
        world:advance(12)
        assert.is_true(again.ns.Filler.isActive())
        assert.are.equal(3, again.ns.Invites.held())
        again:system("Dps 1 declines your group invitation.")
        for _ = 1, 60 do
            world:advance(1)
            again:press("W")
        end
        assert.is_true(#again.invites > 0)
    end)

    it("does not invite the players whose invites are still open again after a /reload", function()
        local world = World.new()
        local tank = world:addClient("Solo Tank", { level = 20 })
        world:list("Heal A", "H", 799, 20, 900)
        world:list("Dps 1", "D", 799, 20, 800)
        world:advance(30)
        tank.ns.charDb.wantsLead = true
        tank:slash("/dq join tank dm")
        world:advance(5)
        assert.are.equal(2, #tank.invites)
        local again = reload(world, tank)
        for second = 1, 30 do
            world:advance(1)
            again:press("W")
            if second == 10 then
                assert.are.equal("HD", again.ns.engine.myEntry.reserved)
                assert.are.equal(2, again.ns.Invites.held())
            end
        end
        assert.are.same({}, again.invites)
        assert.are.same({}, again.whispers)
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
