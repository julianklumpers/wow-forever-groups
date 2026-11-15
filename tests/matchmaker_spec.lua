local Matchmaker = require("core.matchmaker")

local function entry(id, joinedAt, role, dungeons, premade)
    local members = { { name = id, roles = role, level = 60 } }
    for _, m in ipairs(premade or {}) do
        members[#members + 1] = { name = m[1], roles = m[2], level = 60 }
    end
    return { id = id, joinedAt = joinedAt, dungeons = dungeons or { "DM" }, members = members }
end

local function ids(group)
    local list = {}
    for _, e in ipairs(group.entries) do
        list[#list + 1] = e.id
    end
    table.sort(list)
    return list
end

describe("Matchmaker", function()
    it("2 tanks, 1 healer, 6 DPS: the longest-waiting tank and DPS get in", function()
        local entries = {
            entry("Dps6", 9, "D"), entry("Tank2", 2, "T"), entry("Dps1", 3, "D"), entry("Dps4", 6, "D"),
            entry("Heal", 8, "H"), entry("Dps2", 4, "D"), entry("Tank1", 1, "T"), entry("Dps5", 7, "D"),
            entry("Dps3", 5, "D"),
        }
        local groups = Matchmaker.findGroups(entries)
        assert.are.equal(1, #groups)
        assert.are.same({ "Dps1", "Dps2", "Dps3", "Heal", "Tank1" }, ids(groups[1]))
        assert.are.equal("Tank1", groups[1].leader)
        assert.are.equal("DM", groups[1].dungeon)
    end)

    it("breaks a joinedAt tie by name", function()
        local entries = {
            entry("TankB", 1, "T"), entry("TankA", 1, "T"), entry("Heal", 1, "H"),
            entry("Dps1", 1, "D"), entry("Dps2", 1, "D"), entry("Dps3", 1, "D"),
        }
        assert.are.equal("TankA", Matchmaker.findGroups(entries)[1].leader)
    end)

    it("forms no group without a healer", function()
        local entries = { entry("Tank", 1, "T"), entry("Dps1", 2, "D"), entry("Dps2", 3, "D"), entry("Dps3", 4, "D") }
        assert.are.same({}, Matchmaker.findGroups(entries))
    end)

    it("forms several groups at once", function()
        local entries = {}
        for i, role in ipairs({ "T", "T", "H", "H", "D", "D", "D", "D", "D", "D", "D" }) do
            entries[#entries + 1] = entry("P" .. string.format("%02d", i), i, role)
        end
        local groups = Matchmaker.findGroups(entries)
        assert.are.equal(2, #groups)
        assert.are.same({ "P01", "P03", "P05", "P06", "P07" }, ids(groups[1]))
        assert.are.same({ "P02", "P04", "P08", "P09", "P10" }, ids(groups[2]))
    end)

    it("only groups players who share a dungeon", function()
        local entries = {
            entry("Tank", 1, "T", { "DM", "WC" }), entry("Heal", 2, "H", { "WC" }),
            entry("Dps1", 3, "D", { "DM" }), entry("Dps2", 4, "D", { "WC" }),
            entry("Dps3", 5, "D", { "WC", "SFK" }), entry("Dps4", 6, "D", { "WC" }),
        }
        local groups = Matchmaker.findGroups(entries)
        assert.are.equal(1, #groups)
        assert.are.equal("WC", groups[1].dungeon)
        assert.are.same({ "Dps2", "Dps3", "Dps4", "Heal", "Tank" }, ids(groups[1]))
    end)

    it("picks the dungeon that serves the longest-waiting players", function()
        local entries = {
            entry("Tank", 1, "T", { "AAA", "ZZZ" }),
            entry("Heal1", 2, "H", { "ZZZ" }), entry("Heal2", 9, "H", { "AAA" }),
            entry("Dps1", 3, "D", { "AAA", "ZZZ" }), entry("Dps2", 4, "D", { "AAA", "ZZZ" }),
            entry("Dps3", 5, "D", { "AAA", "ZZZ" }),
        }
        local group = Matchmaker.findGroups(entries)[1]
        assert.are.equal("ZZZ", group.dungeon)
        assert.are.same({ "Dps1", "Dps2", "Dps3", "Heal1", "Tank" }, ids(group))
    end)

    describe("premades", function()
        it("places a premade of 2 as one block", function()
            local entries = {
                entry("Heal", 1, "H"), entry("Duo", 2, "T", nil, { { "DuoFriend", "D" } }),
                entry("Dps1", 3, "D"), entry("Dps2", 4, "D"), entry("Dps3", 5, "D"),
            }
            local group = Matchmaker.findGroups(entries)[1]
            assert.are.same({ "Dps1", "Dps2", "Duo", "Heal" }, ids(group))
            assert.are.equal(5, #group.members)
        end)

        it("skips a premade that does not fit the remaining slots and keeps it waiting", function()
            local entries = {
                entry("Heal", 1, "H"), entry("Tank", 2, "T"), entry("Dps1", 3, "D"), entry("Dps2", 4, "D"),
                entry("Duo", 5, "D", nil, { { "DuoFriend", "D" } }), entry("Dps3", 6, "D"),
            }
            local groups = Matchmaker.findGroups(entries)
            assert.are.equal(1, #groups)
            assert.are.same({ "Dps1", "Dps2", "Dps3", "Heal", "Tank" }, ids(groups[1]))
        end)

        it("prefers an older premade over newer solo players", function()
            local entries = {
                entry("Heal", 1, "H"), entry("Tank", 2, "T"), entry("Duo", 3, "D", nil, { { "DuoFriend", "D" } }),
                entry("Dps1", 4, "D"), entry("Dps2", 5, "D"),
            }
            assert.are.same({ "Dps1", "Duo", "Heal", "Tank" }, ids(Matchmaker.findGroups(entries)[1]))
        end)

        it("drops an older solo player when only that lets a premade complete the group", function()
            local entries = {
                entry("Heal", 1, "H"), entry("Dps1", 2, "D"), entry("Dps2", 3, "D"),
                entry("Trio", 4, "T", nil, { { "TrioA", "D" }, { "TrioB", "D" } }),
            }
            local group = Matchmaker.findGroups(entries)[1]
            assert.are.same({ "Dps1", "Heal", "Trio" }, ids(group))
        end)

        it("never puts two premades in one group", function()
            local entries = {
                entry("DuoA", 1, "T", nil, { { "DuoAFriend", "D" } }),
                entry("DuoB", 2, "H", nil, { { "DuoBFriend", "D" } }),
                entry("Dps1", 3, "D"), entry("Dps2", 4, "D"), entry("Heal", 5, "H"),
            }
            local groups = Matchmaker.findGroups(entries)
            assert.are.equal(1, #groups)
            assert.are.same({ "Dps1", "Dps2", "DuoA", "Heal" }, ids(groups[1]))
        end)

        it("makes the premade owner leader so the premade does not have to disband", function()
            local entries = {
                entry("Tank", 1, "T"), entry("Heal", 2, "H"),
                entry("Duo", 3, "D", nil, { { "DuoFriend", "D" } }), entry("Dps1", 4, "D"),
            }
            local group = Matchmaker.findGroups(entries)[1]
            assert.are.equal("Duo", group.leader)
            assert.are.equal("Duo", group.entries[1].id)
        end)
    end)

    it("makes a solo player who would like to lead the leader, before the tank but after a party", function()
        local solo = {
            entry("Heal", 1, "H"), entry("Dps1", 2, "D"), entry("Dps2", 3, "D"),
            entry("Dps3", 4, "D"), entry("Tank", 5, "T"),
        }
        solo[3].lead = true
        assert.are.equal("Dps2", Matchmaker.findGroups(solo)[1].leader)
        local withParty = {
            entry("Tank", 1, "T"), entry("Heal", 2, "H"),
            entry("Duo", 3, "D", nil, { { "DuoFriend", "D" } }), entry("Dps1", 4, "D"),
        }
        withParty[4].lead = true
        assert.are.equal("Duo", Matchmaker.findGroups(withParty)[1].leader)
    end)

    it("prefers the tank as leader when everyone is solo", function()
        local entries = {
            entry("Heal", 1, "H"), entry("Dps1", 2, "D"), entry("Dps2", 3, "D"),
            entry("Dps3", 4, "D"), entry("Tank", 5, "T"),
        }
        local group = Matchmaker.findGroups(entries)[1]
        assert.are.equal("Tank", group.leader)
        assert.are.equal("Tank", group.entries[1].id)
    end)

    it("still forms a group further down the queue when the players before it can form none", function()
        local dungeons = { "d1", "d2", "d3" }
        local function styled(id, joinedAt, role, list, playstyle, language)
            local e = entry(id, joinedAt, role, list)
            e.playstyle, e.language = playstyle, language
            return e
        end
        local entries = { styled("Anchor", 1, "D", dungeons, 0, "enUS:1") }
        for i = 1, 20 do
            entries[#entries + 1] = styled("Dps" .. i, 1 + i, "D", dungeons, 0, "enUS:1")
        end
        entries[#entries + 1] = styled("Tank", 30, "T", dungeons, 1, "enUS:1")
        entries[#entries + 1] = styled("Heal1", 31, "H", dungeons, 3, "enUS:1")
        entries[#entries + 1] = styled("Heal2", 32, "H", dungeons, 3, "enUS:1")
        entries[#entries + 1] = styled("GTank", 40, "T", { "d1" }, 0, "deDE:2")
        entries[#entries + 1] = styled("GHeal", 41, "H", { "d1" }, 0, "deDE:2")
        for i = 1, 3 do
            entries[#entries + 1] = styled("GDps" .. i, 41 + i, "D", { "d1" }, 0, "deDE:2")
        end
        local groups = Matchmaker.findGroups(entries, nil, 1000)
        assert.are.equal(1, #groups)
        assert.are.same({ "GDps1", "GDps2", "GDps3", "GHeal", "GTank" }, ids(groups[1]))
    end)

    it("tries a player's other dungeons when the first one can never fill", function()
        local function lang(id, joinedAt, role, list, language)
            local e = entry(id, joinedAt, role, list)
            e.language = language
            return e
        end
        local entries = {
            lang("Anchor", 1, "D", { "a", "b" }, "deDE:3"),
            lang("ATank", 2, "T", { "a" }, "deDE:2"), lang("AHeal", 40, "H", { "a" }, "enUS:3"),
        }
        for i = 1, 30 do
            entries[#entries + 1] = lang("ADps" .. i, 3 + i, "D", { "a" }, "deDE:3")
        end
        entries[#entries + 1] = lang("BTank", 50, "T", { "b" }, "deDE:2")
        entries[#entries + 1] = lang("BHeal", 51, "H", { "b" }, "deDE:2")
        entries[#entries + 1] = lang("BDps1", 52, "D", { "b" }, "deDE:2")
        entries[#entries + 1] = lang("BDps2", 53, "D", { "b" }, "deDE:2")
        local groups = Matchmaker.findGroups(entries, nil, 1000)
        assert.is_true(#groups >= 1)
        assert.are.equal("b", groups[1].dungeon)
        assert.are.same({ "Anchor", "BDps1", "BDps2", "BHeal", "BTank" }, ids(groups[1]))
    end)

    it("stays fast when a role is missing from a large queue", function()
        local entries = {}
        for i = 1, 300 do
            entries[i] = entry("P" .. i, i, i % 2 == 0 and "T" or "D")
        end
        local started = os.clock()
        assert.are.same({}, Matchmaker.findGroups(entries))
        assert.is_true(os.clock() - started < 1)
    end)
end)
