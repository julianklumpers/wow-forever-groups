local Fill = require("core.fill")

local function listing(name, roles, dungeons, age, level, solo)
    return { name = name, roles = roles, dungeons = dungeons or { "5" }, age = age or 0, level = level or 20,
        solo = solo ~= false }
end

describe("Fill", function()
    it("takes a player when everyone picked still fits the wished places, without deciding places early", function()
        local Compose = require("core.compose")
        local rogue, mage = listing("Rogue A", "D", nil, 300), listing("Mage B", "D", nil, 100)
        rogue.classToken, mage.classToken = "ROGUE", "MAGE"
        local places = {
            { role = "D", mask = Compose.maskOf({ "MAGE", "ROGUE" }) },
            { role = "D", mask = Compose.maskOf({ "ROGUE" }) },
        }
        local picks, open = Fill.pick({ rogue, mage }, { missing = "DD", dungeon = "5", places = places })
        assert.are.equal(2, #picks)
        assert.are.equal("", open)
    end)

    it("takes no second of a class in one role and no third of a class while varying classes", function()
        local function as(name, roles, class, age)
            local l = listing(name, roles, nil, age)
            l.classToken = class
            return l
        end
        local listings = {
            as("Pala Heal", "H", "PALADIN", 900), as("Pala Dps", "D", "PALADIN", 800),
            as("War Dps", "D", "WARRIOR", 700),
            as("Mage A", "D", "MAGE", 500), as("Mage B", "D", "MAGE", 400), as("Who", "D", nil, 100),
        }
        local avoid = { PALADIN = { count = 1, roles = { T = true } }, WARRIOR = { count = 1, roles = { D = true } } }
        local picks, open = Fill.pick(listings, { missing = "HDDD", dungeon = "5", avoid = avoid })
        local names = {}
        for _, pick in ipairs(picks) do
            names[#names + 1] = pick.name
        end
        assert.are.same({ "Pala Heal", "Mage A", "Who" }, names)
        assert.are.equal("D", open)
        local why = Fill.skipped(listings, { dungeons = { "5" }, avoid = avoid }, "D")
        assert.are.equal(1, why.variety)
        assert.is_false(Fill.avoided({ PALADIN = { count = 1, roles = { H = true } } }, {}, "PALADIN", "D"))
        assert.is_true(Fill.avoided({ PALADIN = { count = 2, roles = { T = true, H = true } } }, {}, "PALADIN", "D"))
    end)

    it("prefers another class, and takes one the group has when nobody else is listed", function()
        local war, mage = listing("War", "D", nil, 900), listing("Mage", "D", nil, 10)
        war.classToken, mage.classToken = "WARRIOR", "MAGE"
        local prefer = { WARRIOR = { count = 1, roles = { D = true } } }
        local picks = Fill.pick({ war, mage }, { missing = "D", dungeon = "5", prefer = prefer })
        assert.are.equal("Mage", picks[1].name)
        picks = Fill.pick({ war }, { missing = "D", dungeon = "5", prefer = prefer })
        assert.are.equal("War", picks[1].name)
        picks = Fill.pick({ war, mage }, { missing = "DD", dungeon = "5", prefer = prefer })
        assert.are.equal(2, #picks)
    end)

    it("takes the player closest to the group's level before the one listed longest", function()
        local far, close = listing("Far", "D", nil, 900, 16), listing("Close", "D", nil, 10, 21)
        local picks = Fill.pick({ far, close }, { missing = "D", dungeon = "5", near = 20 })
        assert.are.equal("Close", picks[1].name)
        picks = Fill.pick({ far, close }, { missing = "D", dungeon = "5" })
        assert.are.equal("Far", picks[1].name)
        local plan = Fill.plan({ far, close }, { missing = "D", dungeons = { "5" }, near = 20 })
        assert.are.equal("Close", plan.picks[1].name)
    end)

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

    describe("choosing between dungeons", function()
        it("takes the dungeon whose tank and healer places can be filled before one with more players", function()
            local listings = {
                listing("Tank", "T", { "6" }), listing("Heal", "H", { "6" }),
                listing("Dps A", "D", { "5" }), listing("Dps B", "D", { "5" }), listing("Dps C", "D", { "5" }),
            }
            local plan = Fill.plan(listings, { missing = "THDD", dungeons = { "5", "6" } })
            assert.are.equal("6", plan.dungeon)
            assert.are.same({ scarce = 0, open = 2, steps = math.huge, apart = 0, places = 4 }, plan.score)
            listings[#listings + 1] = listing("Tank 5", "T", { "5" })
            listings[#listings + 1] = listing("Heal 5", "H", { "5" })
            assert.are.equal("5", Fill.plan(listings, { missing = "THDD", dungeons = { "5", "6" } }).dungeon)
        end)

        it("takes the dungeon that fills more places before a shorter walk", function()
            local listings = {
                listing("Dps 5", "D", { "5" }), listing("Dps 6", "D", { "6" }), listing("Dps 6b", "D", { "6" }),
            }
            local plan = Fill.plan(listings, { missing = "DD", dungeons = { "5", "6" }, groupSteps = function(dungeon)
                return dungeon == "5" and 0 or 4
            end })
            assert.are.equal("6", plan.dungeon)
        end)

        it("takes the shorter walk of the group's furthest player, the group itself too", function()
            local listings = { listing("Dps 5", "D", { "5" }), listing("Dps 6", "D", { "6" }) }
            local steps = { ["Dps 5"] = 3, ["Dps 6"] = 1 }
            local opts = { missing = "D", dungeons = { "5", "6" }, steps = function(l)
                return steps[l.name]
            end }
            assert.are.equal("6", Fill.plan(listings, opts).dungeon)
            opts.groupSteps = function(dungeon)
                return dungeon == "6" and 5 or 0
            end
            assert.are.equal("5", Fill.plan(listings, opts).dungeon)
        end)

        it("takes the dungeon whose level range suits the group's levels, on an equal walk", function()
            local listings = { listing("Dps 5", "D", { "5" }, 0, 20), listing("Dps 6", "D", { "6" }, 0, 20) }
            local ranges = { ["5"] = { min = 15, max = 21 }, ["6"] = { min = 20, max = 26 } }
            local plan = Fill.plan(listings, { missing = "D", dungeons = { "5", "6" }, ranges = ranges,
                groupLevels = { 23 } })
            assert.are.equal("6", plan.dungeon)
            assert.are.equal(1.5, plan.score.apart)
            plan = Fill.plan(listings, {
                missing = "D", dungeons = { "5", "6" }, ranges = ranges, groupLevels = { 17 },
            })
            assert.are.equal("5", plan.dungeon)
        end)

        it("keeps the first dungeon on a full tie", function()
            local listings = { listing("Dps 5", "D", { "5" }), listing("Dps 6", "D", { "6" }) }
            assert.are.equal("5", Fill.plan(listings, { missing = "D", dungeons = { "5", "6" } }).dungeon)
            assert.are.equal("6", Fill.plan(listings, { missing = "D", dungeons = { "6", "5" } }).dungeon)
        end)
    end)

    it("under class wishes takes another class of the players as close, never one further away", function()
        local lock, mage = listing("Lock", "D", nil, 900), listing("Mage", "D", nil, 10)
        lock.classToken, mage.classToken = "WARLOCK", "MAGE"
        local steps = { Lock = 1, Mage = 1 }
        local opts = { missing = "D", dungeon = "5", spread = { WARLOCK = { count = 1, roles = { D = true } } },
            steps = function(l)
                return steps[l.name]
            end }
        assert.are.equal("Mage", Fill.pick({ lock, mage }, opts)[1].name)
        steps.Mage = 3
        assert.are.equal("Lock", Fill.pick({ lock, mage }, opts)[1].name)
        assert.are.equal("Lock", Fill.pick({ lock }, opts)[1].name)
        local other = listing("Lock 2", "D", nil, 500)
        other.classToken = "WARLOCK"
        steps.Mage, steps["Lock 2"] = 1, 1
        opts.missing, opts.spread = "DD", {}
        local names = {}
        for _, pick in ipairs(Fill.pick({ lock, other, mage }, opts)) do
            names[#names + 1] = pick.name
        end
        assert.are.same({ "Lock", "Mage" }, names)
    end)

    it("takes the player closest to the dungeon first and passes over one still waiting", function()
        local far, near, unknown = listing("Far Dps", "D", nil, 900), listing("Near Dps", "D", nil, 10),
            listing("Who Dps", "D", nil, 950)
        local steps = { ["Far Dps"] = 3, ["Near Dps"] = 0 }
        local opts = { missing = "D", dungeon = "5", steps = function(l)
            return steps[l.name]
        end }
        local picks = Fill.pick({ far, near, unknown }, opts)
        assert.are.equal("Near Dps", picks[1].name)
        picks = Fill.pick({ far, unknown }, opts)
        assert.are.equal("Far Dps", picks[1].name)
        opts.held = function(l)
            return l.name == "Far Dps"
        end
        picks = Fill.pick({ far, unknown }, opts)
        assert.are.equal("Who Dps", picks[1].name)
        local why = Fill.skipped({ far }, { dungeons = { "5" }, held = opts.held }, "D")
        assert.are.equal(1, why.held)
    end)
end)
