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

    describe("the first minutes of a group", function()
        local function as(id, joinedAt, roles, class)
            local e = entry(id, joinedAt, roles)
            e.spec = class
            return e
        end

        it("takes no second of a class in one role while the longest waiting has waited under 5 minutes", function()
            local entries = {
                as("Tank", 1, "T", "PALADIN"), as("Heal", 2, "H", "PRIEST"), as("War1", 3, "D", "WARRIOR"),
                as("War2", 4, "D", "WARRIOR"), as("Mage", 5, "D", "MAGE"), as("Rogue", 6, "D", "ROGUE"),
            }
            local groups = Matchmaker.findGroups(entries, nil, 60)
            assert.are.same({ "Heal", "Mage", "Rogue", "Tank", "War1" }, ids(groups[1]))
            assert.are.same({ "Heal", "Mage", "Tank", "War1", "War2" }, ids(Matchmaker.findGroups(entries)[1]))
        end)

        it("still prefers another class after 5 minutes, but forms the group when there is none", function()
            local entries = {
                as("Tank", 1, "T", "PALADIN"), as("Heal", 2, "H", "PRIEST"), as("War1", 3, "D", "WARRIOR"),
                as("War2", 4, "D", "WARRIOR"), as("Mage", 5, "D", "MAGE"), as("Rogue", 6, "D", "ROGUE"),
            }
            local later = 1 + 300
            local group = Matchmaker.findGroups(entries, nil, later)[1]
            assert.are.same({ "Heal", "Mage", "Rogue", "Tank", "War1" }, ids(group))
            local warriors = {
                as("Tank", 1, "T", "PALADIN"), as("Heal", 2, "H", "PRIEST"), as("War1", 3, "D", "WARRIOR"),
                as("War2", 4, "D", "WARRIOR"), as("War3", 5, "D", "WARRIOR"),
            }
            assert.are.equal(0, #Matchmaker.findGroups(warriors, nil, 60))
            group = Matchmaker.findGroups(warriors, nil, later)[1]
            assert.are.same({ "Heal", "Tank", "War1", "War2", "War3" }, ids(group))
        end)

        it("takes a class in another role, but no third of it", function()
            local entries = {
                as("Tank", 1, "T", "PALADIN"), as("Heal", 2, "H", "PALADIN"), as("Pala", 3, "D", "PALADIN"),
                as("War", 4, "D", "WARRIOR"), as("Mage", 5, "D", "MAGE"), as("Rogue", 6, "D", "ROGUE"),
            }
            assert.are.same({ "Heal", "Mage", "Rogue", "Tank", "War" }, ids(Matchmaker.findGroups(entries, nil, 60)[1]))
        end)

        it("gives a flexible player the role that keeps the classes varied", function()
            local entries = {
                as("Heal", 1, "H", "PRIEST"), as("War1", 2, "TD", "WARRIOR"), as("War2", 3, "D", "WARRIOR"),
                as("Mage", 4, "D", "MAGE"), as("Rogue", 5, "D", "ROGUE"),
            }
            local group = Matchmaker.findGroups(entries, nil, 60)[1]
            assert.are.same({ "Heal", "Mage", "Rogue", "War1", "War2" }, ids(group))
            local roleOf = {}
            for _, member in ipairs(group.members) do
                roleOf[member.name] = member.role
            end
            assert.are.equal("T", roleOf.War1)
        end)

        it("forms every group of clashing classes after 5 minutes in one round", function()
            local entries = {}
            for i = 1, 300 do
                local role = (i % 5 == 1) and "T" or (i % 5 == 2) and "H" or "D"
                local id = string.format("P%04d", i)
                entries[i] = as(id, i, role, role == "H" and "PRIEST" or "WARRIOR")
                entries[i].dungeons = { "5" }
            end
            assert.are.equal(60, #Matchmaker.findGroups(entries, nil, 300 + 300))
        end)

        it("knows the classes of a party's players", function()
            local party = as("Lead", 1, "T", "WARRIOR")
            party.members[2] = { name = "Friend", roles = "D", level = 60, class = "MAGE" }
            local entries = {
                party, as("Heal", 2, "H", "PRIEST"), as("Mage", 3, "D", "MAGE"), as("Rogue", 4, "D", "ROGUE"),
                as("Lock", 5, "D", "WARLOCK"),
            }
            assert.are.same({ "Heal", "Lead", "Lock", "Rogue" }, ids(Matchmaker.findGroups(entries, nil, 60)[1]))
        end)

        it("leaves a second of a class in one role out of a partial group too", function()
            local entries = {
                as("War1", 1, "D", "WARRIOR"), as("War2", 2, "D", "WARRIOR"), as("Mage", 3, "D", "MAGE"),
            }
            local group = Matchmaker.findPartialGroup(entries, nil, 60, 0, 2)
            assert.are.same({ "Mage", "War1" }, ids(group))
        end)
    end)

    describe("levels", function()
        local function at(id, joinedAt, roles, level)
            local e = entry(id, joinedAt, roles)
            e.members[1].level = level
            return e
        end

        it("takes the players closest to the anchor's level first", function()
            local entries = {
                at("Tank", 1, "T", 20), at("Heal", 2, "H", 20), at("D15", 3, "D", 15), at("D16", 4, "D", 16),
                at("D20", 5, "D", 20), at("D21", 6, "D", 21), at("D19", 7, "D", 19),
            }
            assert.are.same({ "D19", "D20", "D21", "Heal", "Tank" }, ids(Matchmaker.findGroups(entries, nil, 60)[1]))
            assert.are.same({ "D15", "D16", "D20", "Heal", "Tank" }, ids(Matchmaker.findGroups(entries)[1]))
        end)

        it("counts a player who waited 5 minutes as close, whatever their level", function()
            local entries = {
                at("Tank", 1, "T", 20), at("D15", 2, "D", 15), at("Heal", 3, "H", 20), at("D16", 4, "D", 16),
                at("D20", 5, "D", 20), at("D21", 6, "D", 21), at("D19", 7, "D", 19),
            }
            local group = Matchmaker.findGroups(entries, nil, 2 + 300)[1]
            assert.are.same({ "D15", "D20", "D21", "Heal", "Tank" }, ids(group))
        end)
    end)

    describe("by zone", function()
        local steps = { Westfall = 0, Duskwood = 1, Redridge = 2, Swamp = 3 }
        local function zoned(id, joinedAt, role, zone)
            local e = entry(id, joinedAt, role)
            e.zone = zone
            return e
        end

        before_each(function()
            Matchmaker.zoneDistance = function(_, zone)
                return steps[zone], 3
            end
        end)

        after_each(function()
            Matchmaker.zoneDistance = nil
        end)

        it("takes the players closest to the dungeon first", function()
            local entries = {
                zoned("Tank", 1, "T", "Westfall"), zoned("Heal", 2, "H", "Westfall"),
                zoned("FarDps", 3, "D", "Redridge"), zoned("NearA", 4, "D", "Duskwood"),
                zoned("NearB", 5, "D", "Westfall"), zoned("NearC", 6, "D", "Duskwood"),
            }
            local groups = Matchmaker.findGroups(entries, nil, 1000)
            assert.are.same({ "Heal", "NearA", "NearB", "NearC", "Tank" }, ids(groups[1]))
        end)

        it("sends the same players to the dungeon with the shorter walk, then the better levels", function()
            local function everywhere(id, joinedAt, role, zone, level)
                local e = zoned(id, joinedAt, role, zone)
                e.dungeons = { "DM", "SFK" }
                e.members[1].level = level or 24
                return e
            end
            local entries = {
                everywhere("Tank", 1, "T", "Westfall"), everywhere("Heal", 2, "H", "Westfall"),
                everywhere("DpsA", 3, "D", "Westfall"), everywhere("DpsB", 4, "D", "Westfall"),
                everywhere("DpsC", 5, "D", "Swamp", 26),
            }
            Matchmaker.zoneDistance = function(dungeon, zone)
                local near = dungeon == "SFK" and { Westfall = 1, Swamp = 1 } or steps
                return near[zone], 3
            end
            assert.are.equal("SFK", Matchmaker.findGroups(entries, nil, 1000)[1].dungeon)
            Matchmaker.zoneDistance = function(_, zone)
                return steps[zone] and 0, 3
            end
            assert.are.equal("DM", Matchmaker.findGroups(entries, nil, 1000)[1].dungeon)
            Matchmaker.levelRange = function(dungeon)
                return dungeon == "SFK" and { min = 20, max = 30 } or { min = 15, max = 21 }
            end
            assert.are.equal("SFK", Matchmaker.findGroups(entries, nil, 1000)[1].dungeon)
            Matchmaker.levelRange = nil
        end)

        it("compares the same players for two dungeons by who waited longest, whatever the order zones give", function()
            local function both(id, joinedAt, role)
                local e = zoned(id, joinedAt, role, id)
                e.dungeons = { "DM", "SFK" }
                return e
            end
            local away = { DM = { DpsA = 2 }, SFK = { DpsB = 3 } }
            Matchmaker.zoneDistance = function(dungeon, zone)
                return away[dungeon][zone] or 0, 3
            end
            local entries = {
                both("Tank", 1, "T"), both("Heal", 2, "H"), both("DpsA", 3, "D"), both("DpsB", 4, "D"),
                both("DpsC", 5, "D"),
            }
            assert.are.equal("DM", Matchmaker.findGroups(entries, nil, 1000)[1].dungeon)
            away = { DM = { DpsB = 3 }, SFK = { DpsA = 2 } }
            assert.are.equal("SFK", Matchmaker.findGroups(entries, nil, 1000)[1].dungeon)
        end)

        it("lets one further away wait 15 s a step from joining the queue, then takes them", function()
            local entries = {
                zoned("Tank", 1, "T", "Westfall"), zoned("Heal", 2, "H", "Westfall"),
                zoned("NearA", 3, "D", "Duskwood"), zoned("NearB", 4, "D", "Westfall"),
                zoned("FarDps", 100, "D", "Swamp"),
            }
            assert.are.equal(0, #Matchmaker.findGroups(entries, nil, 120))
            local groups = Matchmaker.findGroups(entries, nil, 130)
            assert.are.same({ "FarDps", "Heal", "NearA", "NearB", "Tank" }, ids(groups[1]))
            entries[#entries + 1] = zoned("Unknown", 101, "D", nil)
            local early = Matchmaker.findGroups(entries, nil, 101)
            assert.are.same({ "Heal", "NearA", "NearB", "Tank", "Unknown" }, ids(early[1]))
        end)
    end)
end)
