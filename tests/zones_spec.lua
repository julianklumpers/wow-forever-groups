local Zones = require("core.zones")

describe("Zones", function()
    local graph = {
        Westfall = { Duskwood = true, Elwynn = true },
        Duskwood = { Westfall = true, Elwynn = true, Redridge = true },
        Elwynn = { Westfall = true, Duskwood = true },
        Redridge = { Duskwood = true, Swamp = true },
        Swamp = { Redridge = true },
    }

    it("counts the zones between a zone and the dungeon's own over bordering zones", function()
        local steps, most = Zones.steps(graph, { "Westfall" })
        assert.are.same({ Westfall = 0, Duskwood = 1, Elwynn = 1, Redridge = 2, Swamp = 3 }, steps)
        assert.are.equal(3, most)
        steps = Zones.steps(graph, { "Westfall", "Redridge" })
        assert.are.equal(0, steps.Redridge)
        assert.are.equal(1, steps.Swamp)
    end)

    it("lets the ring around the dungeon go at once and each step further wait 15 s more", function()
        assert.are.equal(0, Zones.wait(0, 3))
        assert.are.equal(0, Zones.wait(1, 3))
        assert.are.equal(15, Zones.wait(2, 3))
        assert.are.equal(30, Zones.wait(3, 3))
        assert.are.equal(45, Zones.wait(nil, 3))
        assert.are.equal(15, Zones.wait(nil, 0))
    end)

    it("counts the wait from when a player showed up, or from the search's start when that came later", function()
        assert.are.equal(15, Zones.waitLeft(2, 3, 1000, 990, 1000))
        assert.are.equal(5, Zones.waitLeft(2, 3, 1000, 990, 1010))
        assert.are.equal(0, Zones.waitLeft(2, 3, 1000, 990, 1015))
        assert.are.equal(10, Zones.waitLeft(2, 3, 400, 1000, 1005))
    end)

    it("ranks another continent or an unknown zone after the furthest ring", function()
        assert.are.equal(2, Zones.rank(2, 3))
        assert.are.equal(4, Zones.rank(nil, 3))
    end)
end)
