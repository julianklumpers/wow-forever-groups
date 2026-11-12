local Fill = require("core.fill")

local function listing(name, roles, dungeons, age, level, solo)
    return { name = name, roles = roles, dungeons = dungeons or { "5" }, age = age or 0, level = level or 20,
        solo = solo ~= false }
end

describe("Fill", function()
    it("picks a player for each open role, longest listed first", function()
        local listings = {
            listing("NewHeal", "H", nil, 10), listing("OldHeal", "H", nil, 300), listing("Dps", "D", nil, 50),
        }
        local picks, open = Fill.pick(listings, { missing = "HD", dungeon = "5" })
        assert.are.same({ { name = "OldHeal", role = "H" }, { name = "Dps", role = "D" } }, picks)
        assert.are.equal("", open)
    end)

    it("keeps flexible players for the scarce roles", function()
        local listings = { listing("Flex", "TD", nil, 500), listing("Tank", "T", nil, 10), listing("Dps", "D", nil, 5) }
        local picks = Fill.pick(listings, { missing = "TD", dungeon = "5" })
        assert.are.same({ { name = "Tank", role = "T" }, { name = "Dps", role = "D" } }, picks)
    end)

    it("uses a flexible player for a role nobody else can fill", function()
        local picks, open = Fill.pick({ listing("Flex", "TD") }, { missing = "TD", dungeon = "5" })
        assert.are.same({ { name = "Flex", role = "T" } }, picks)
        assert.are.equal("D", open)
    end)

    it("skips groups, other dungeons, wrong levels and excluded names", function()
        local listings = {
            listing("Group", "H", nil, 0, 20, false), listing("Elsewhere", "H", { "6" }),
            listing("TooLow", "H", nil, 0, 10), listing("Declined", "H"), listing("Good", "H"),
        }
        local picks = Fill.pick(listings, {
            missing = "H", dungeon = "5", exclude = { Declined = true }, range = { min = 17, max = 26 },
        })
        assert.are.same({ { name = "Good", role = "H" } }, picks)
    end)

    it("plans for the dungeon that fills the most roles", function()
        local listings = { listing("Heal", "H", { "6" }), listing("Dps", "D", { "6" }), listing("Dps5", "D", { "5" }) }
        local plan = Fill.plan(listings, { missing = "HD", dungeons = { "5", "6" } })
        assert.are.equal("6", plan.dungeon)
        assert.are.equal(2, #plan.picks)
    end)
end)
