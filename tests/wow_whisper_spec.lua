local World = require("tests.helpers.wowmock")

local function building()
    local world = World.new()
    local tank = world:addClient("Solo Tank", { level = 20 })
    world:list("Listed Heal", "H", 799, 20, 300)
    world:advance(30)
    tank:slash("/dq join tank dm")
    world:advance(2)
    assert.is_true(tank.ns.Filler.isActive())
    assert.are.equal("DDD", tank.ns.Filler.stillNeeded())
    return world, tank
end

local function repliesTo(client, name)
    local texts = {}
    for _, w in ipairs(client.whispers) do
        if w.target == name then
            texts[#texts + 1] = w.text
        end
    end
    return texts
end

local function invited(client, name)
    for _, n in ipairs(client.invites) do
        if n == name then
            return true
        end
    end
    return false
end

describe("whisper invites while building a group", function()
    it("reads roles and join requests from a whisper", function()
        local _, tank = building()
        local W = tank.ns.WhisperInvite
        assert.are.equal("HD", W.rolesIn("Heal or DPS? can I join"))
        assert.are.equal("T", W.rolesIn("prot warrior lf group"))
        assert.are.equal("", W.rolesIn("inv pls"))
        assert.is_true(W.asksToJoin("inv pls"))
        assert.is_false(W.asksToJoin("hello there"))
    end)

    it("invites a whisperer who names a role the group still needs", function()
        local _, tank = building()
        tank:whisperFrom("Whisper Dps", "dps here, inv?")
        assert.is_true(invited(tank, "Whisper Dps"))
        assert.are.equal("D", tank.ns.Filler.roleOf("Whisper Dps"))
        assert.are.equal("DD", tank.ns.Filler.stillNeeded())
        assert.truthy(repliesTo(tank, "Whisper Dps")[1]:find("Inviting you as dps for The Deadmines"))
    end)

    it("asks for the role once when someone only asks to join, and invites on the answer", function()
        local _, tank = building()
        tank:whisperFrom("Some Player", "inv pls")
        tank:whisperFrom("Some Player", "inv?")
        local replies = repliesTo(tank, "Some Player")
        assert.are.equal(1, #replies)
        assert.truthy(replies[1]:find("Which role do you play%? Reply tank, heal or dps%. Still needed: DPS%."))
        assert.is_false(invited(tank, "Some Player"))

        tank:whisperFrom("Some Player", "dps")
        assert.is_true(invited(tank, "Some Player"))
    end)

    it("says which roles are needed when the whispered role is taken", function()
        local _, tank = building()
        tank:whisperFrom("Other Tank", "tank lf group")
        assert.is_false(invited(tank, "Other Tank"))
        assert.truthy(repliesTo(tank, "Other Tank")[1]:find("Sorry, we only need DPS right now%."))
    end)

    it("ignores whispers when not building a group, and other chat", function()
        local world = World.new()
        local solo = world:addClient("Solo Player", { level = 20 })
        world:advance(30)
        solo:whisperFrom("Random Person", "dps inv")
        assert.are.same({}, solo.invites)
        assert.are.same({}, solo.whispers)

        local _, tank = building()
        tank:whisperFrom("Friend", "hello there")
        assert.are.same({}, repliesTo(tank, "Friend"))
    end)

    it("only reports in a dry run and can be turned off", function()
        local _, tank = building()
        tank.ns.db.dryRun = true
        tank:whisperFrom("Whisper Dps", "dps")
        assert.is_false(invited(tank, "Whisper Dps"))
        assert.is_true(tank:said("Would invite Whisper Dps, who whispered you, as DPS"))

        tank.ns.db.dryRun = nil
        tank.ns.db.noWhisperInvite = true
        tank:whisperFrom("Second Dps", "dps")
        assert.is_false(invited(tank, "Second Dps"))
    end)

    it("ignores whispers of other Forever Groups players, also of the old DungeonQueue", function()
        local _, tank = building()
        tank:whisperFrom("Old Builder", "[DungeonQueue] Hi! Our group for The Deadmines needs a dps. Inviting you now.")
        tank:whisperFrom("New Builder", "[Forever Groups] Hi! Our group needs a dps. Inviting you now.")
        assert.is_false(invited(tank, "Old Builder"))
        assert.is_false(invited(tank, "New Builder"))
        assert.are.same({}, repliesTo(tank, "Old Builder"))
    end)
end)
