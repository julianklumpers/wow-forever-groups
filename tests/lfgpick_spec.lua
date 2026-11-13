local LfgPick = require("core.lfgpick")

local function group(id, dungeon, t, h, d, age)
    return { id = id, leader = "Leader " .. id, dungeons = { dungeon }, remaining = { T = t, H = h, D = d },
        age = age or 0 }
end

describe("Choosing groups to apply to", function()
    local wanted = { ["4"] = true }

    it("picks groups that need one of my roles, nearest to full first", function()
        local groups = {
            group(1, "4", 1, 1, 2), group(2, "4", 0, 0, 1), group(3, "4", 0, 1, 0), group(4, "4", 0, 0, 2),
        }
        local picks = LfgPick.groupsToApply(groups, { roles = "D", dungeons = wanted, max = 5 })
        local ids = {}
        for i, pick in ipairs(picks) do
            ids[i] = pick.id
        end
        assert.are.same({ 2, 4, 1 }, ids)
        assert.is_true(picks[1].dps)
        assert.is_false(picks[1].tank)
    end)

    it("skips other dungeons, excluded groups and respects the maximum", function()
        local groups = { group(1, "5", 0, 0, 1), group(2, "4", 0, 0, 1), group(3, "4", 0, 0, 1, 50),
            group(4, "4", 0, 0, 1, 10) }
        local picks = LfgPick.groupsToApply(groups, { roles = "D", dungeons = wanted, exclude = { [2] = true },
            max = 1 })
        assert.are.equal(1, #picks)
        assert.are.equal(4, picks[1].id)
    end)

    it("asks listings up for half an hour or more last, and the most recent first", function()
        local groups = { group(1, "4", 0, 0, 1, 2400), group(2, "4", 0, 1, 1, 600), group(3, "4", 0, 1, 1, 60) }
        local ids = {}
        for _, pick in ipairs(LfgPick.groupsToApply(groups, { roles = "D", dungeons = wanted })) do
            ids[#ids + 1] = pick.id
        end
        assert.are.same({ 3, 2, 1 }, ids)
    end)

    it("joins as DPS while the group has a DPS place, else as tank, else as healer", function()
        assert.are.equal("D", LfgPick.joinRole("TD", { T = 1, H = 1, D = 1 }))
        assert.are.equal("T", LfgPick.joinRole("TD", { T = 1, H = 0, D = 0 }))
        assert.are.equal("H", LfgPick.joinRole("TH", { T = 0, H = 1, D = 2 }))
        assert.are.equal("T", LfgPick.joinRole("TH", nil))
        assert.are.equal("D", LfgPick.joinRole("TD", { T = 0, H = 1, D = 0 }))
        assert.is_nil(LfgPick.joinRole("", { D = 1 }))
    end)

    it("offers one role: the scarcest the group still needs", function()
        local picks = LfgPick.groupsToApply({ group(1, "4", 1, 0, 1), group(2, "4", 0, 1, 1), group(3, "4", 0, 0, 2) },
            { roles = "THD", dungeons = wanted })
        local byId = {}
        for _, pick in ipairs(picks) do
            byId[pick.id] = pick
        end
        assert.are.equal("T", byId[1].role)
        assert.is_true(byId[1].tank)
        assert.is_false(byId[1].dps)
        assert.are.equal("H", byId[2].role)
        assert.is_false(byId[2].dps)
        assert.are.equal("D", byId[3].role)
    end)

    it("asks as healer when the open places are unknown and the player heals", function()
        assert.are.equal("H", LfgPick.askRole("HD", nil))
        assert.are.equal("D", LfgPick.askRole("TD", nil))
        assert.are.equal("T", LfgPick.askRole("T", nil))
        assert.are.equal("D", LfgPick.askRole("HD", { T = 0, H = 0, D = 1 }))
        assert.are.equal("H", LfgPick.askRole("HD", { T = 1, H = 0, D = 0 }))
        assert.is_nil(LfgPick.askRole("", nil))
    end)
end)

describe("the dungeon reported for a group", function()
    it("is one the player wants, not just the group's first", function()
        local picks = LfgPick.groupsToApply({
            { id = 1, leader = "L", dungeons = { "3", "5" }, remaining = { T = 0, H = 0, D = 1 }, age = 10 },
        }, { roles = "D", dungeons = { ["5"] = true } })
        assert.are.equal("5", picks[1].dungeon)
    end)
end)
