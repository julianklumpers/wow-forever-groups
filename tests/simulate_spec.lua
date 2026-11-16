local Sim = require("tools.simulate")

describe("The queue simulation", function()
    it("runs every variant on the same arrivals and forms groups", function()
        local text, results = Sim.report("normal", 15, 1, 1)
        assert.truthy(text:find("current", 1, true))
        for _, variant in ipairs(Sim.VARIANTS) do
            assert.is_true(results[variant.name].groups > 0)
        end
        assert.are.equal(0, results["no-partial"].partial)
    end)
end)
