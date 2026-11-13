local World = require("tests.helpers.wowmock")
local Config = require("core.config")

local function asked(client)
    local names = {}
    for _, w in ipairs(client.whispers) do
        if w.text:find("could you invite me") then
            names[#names + 1] = w.target
        end
    end
    return names
end

local function invitedCount(client, name)
    local count = 0
    for _, n in ipairs(client.invites) do
        if n == name then
            count = count + 1
        end
    end
    return count
end

describe("Group Finder flows after review", function()
    it("does not invite a whisperer while a queue proposal is open", function()
        local world = World.new()
        local tank = world:addClient("Tanky Mctank", { level = 20 })
        local heal = world:addClient("Heally Mcheal", { level = 20 })
        world:list("Listed Dps", "D", 799, 20, 300)
        world:advance(30)
        tank:slash("/dq join tank dm")
        world:advance(3)
        assert.is_true(tank.ns.Filler.isActive())
        heal:slash("/dq join healer dm")
        world:advance(Config.MATCH_INTERVAL + 2)
        assert.is_true(tank:proposalShown())
        tank:whisperFrom("Whisper Heal", "healer here, inv?")
        assert.are.equal(0, invitedCount(tank, "Whisper Heal"))
    end)

    it("stops inviting and listing after joining someone else's group", function()
        local world = World.new()
        local solo = world:addClient("Solo Dps", { level = 20 })
        world:list("Listed Heal", "H", 799, 20, 300)
        world:advance(30)
        solo:slash("/dq join dps dm")
        world:advance(3)
        assert.is_true(solo.ns.Filler.isActive())
        solo:joinGroupOf("Random Leader")
        world:advance(70)
        assert.is_false(solo.ns.Filler.isActive())
        solo:press("W")
        solo:press("W")
        assert.is_falsy(solo.listed)
    end)

    it("asks groups first even when an older search is cached", function()
        for _, offset in ipairs({ 0, 0.2, 0.5, 0.7, 0.9 }) do
            local world = World.new()
            local solo = world:addClient("Solo Dps", { level = 20 })
            world:advance(30)
            solo.inClick = true
            solo.ns.LfgList.search()
            solo.inClick = false
            world:advance(2)
            world:listGroup("Group Lead", 799, { T = 0, H = 1, D = 1 })
            world:list("Listed Heal", "H", 799, 20, 300)
            world:advance(20 + offset)
            solo:slash("/dq join dps dm")
            world:advance(3)
            assert.are.same({ "Group Lead" }, asked(solo), "offset " .. offset)
            assert.is_false(solo.ns.Filler.isActive(), "offset " .. offset)
        end
    end)

    it("counts a player who accepts after the timeout and does not overfill", function()
        local world = World.new()
        local tank = world:addClient("Solo Tank", { level = 20 })
        world:list("Heal A", "H", 799, 20, 300)
        world:list("Dps A", "D", 799, 20, 300)
        world:list("Dps B", "D", 799, 20, 100)
        world:list("Dps C", "D", 799, 20, 100)
        world:advance(30)
        tank:slash("/dq join tank dm")
        world:advance(3)
        tank:joins("Dps A")
        tank:joins("Dps B")
        tank:joins("Dps C")
        world:advance(62)
        tank:joins("Heal A")
        world:advance(3)
        assert.is_false(tank.ns.Filler.isActive())
        assert.is_true(tank:logged("Heal A joined after all, as Healer"))
    end)

    it("lists the group even when nobody fitting is listed yet", function()
        local world = World.new()
        local tank = world:addClient("Solo Tank", { level = 20 })
        world:advance(30)
        tank:slash("/dq join tank dm")
        world:advance(3)
        assert.is_true(tank.ns.Filler.isActive())
        tank:press("W")
        assert.is_true(tank.listed)
        tank:whisperFrom("Whisper Heal", "heal")
        assert.truthy(tank.whispers[#tank.whispers].text:find("for The Deadmines"))
    end)

    it("does not treat Forever Groups's own whispers as role offers", function()
        local world = World.new()
        local tank = world:addClient("Solo Tank", { level = 20 })
        world:advance(30)
        tank:slash("/dq join tank dm")
        world:advance(3)
        tank:whisperFrom("Other Builder",
            "[Forever Groups] Hi! Our group for The Deadmines needs a dps. Inviting you now.")
        assert.are.equal(0, invitedCount(tank, "Other Builder"))
        tank:whisperFrom("Seeker Dps", "Hi! Level 20 DPS here, could you invite me for The Deadmines? (Forever Groups)")
        assert.are.equal(1, invitedCount(tank, "Seeker Dps"))
    end)
end)
