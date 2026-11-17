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

    it("invites a whisperer once a queue proposal that was open is over", function()
        local world, tank = building()
        tank.ns.engine.held = true
        tank:whisperFrom("Whisper Dps", "dps here, inv?")
        assert.is_false(invited(tank, "Whisper Dps"))
        tank.ns.engine.held = false
        world:advance(2)
        assert.is_true(invited(tank, "Whisper Dps"))
        assert.are.equal("DD", tank.ns.Filler.stillNeeded())

        local invite = tank.env.C_PartyInfo.InviteUnit
        tank.env.C_PartyInfo.InviteUnit = function()
            error("blocked")
        end
        tank:whisperFrom("Other Dps", "dps here, inv?")
        tank.env.C_PartyInfo.InviteUnit = invite
        assert.is_nil(tank.ns.Filler.roleOf("Other Dps"))
        assert.are.equal("DD", tank.ns.Filler.stillNeeded())
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

    it("asks again when an answer names no role, at most three times, and invites on a role", function()
        local world = World.new()
        local dps = world:addClient("Solo Dps", { level = 20 })
        world:list("Listed Heal", "H", 799, 20, 300)
        world:advance(30)
        dps:slash("/dq join dps dm")
        world:advance(2)
        assert.truthy(dps.ns.Filler.stillNeeded():find("T"))
        dps:whisperFrom("Some Tank", "pls invite me")
        dps:whisperFrom("Some Tank", "pls?")
        assert.are.equal(1, #repliesTo(dps, "Some Tank"))
        assert.is_true(dps:logged("Some Tank whispered \"pls invite me\" without a role"))
        world:advance(5)
        dps:whisperFrom("Some Tank", "i can tnak")
        assert.are.equal(2, #repliesTo(dps, "Some Tank"))
        assert.is_true(dps:logged("No role found in Some Tank's whisper \"i can tnak\"; asked again %(2 of 3%)"))
        world:advance(5)
        dps:whisperFrom("Some Tank", "tank")
        assert.is_true(invited(dps, "Some Tank"))
        assert.are.equal("T", dps.ns.Filler.roleOf("Some Tank"))

        dps:whisperFrom("Other Guy", "inv")
        for _ = 1, 4 do
            world:advance(5)
            dps:whisperFrom("Other Guy", "??")
        end
        assert.are.equal(3, #repliesTo(dps, "Other Guy"))
        assert.is_true(dps:logged("asked 3 times, not asking again"))
        assert.is_false(invited(dps, "Other Guy"))

        dps:whisperFrom("Other Guy", "ok tank")
        assert.is_false(invited(dps, "Other Guy"))
        assert.truthy(repliesTo(dps, "Other Guy")[4]:find("we only need"))
    end)

    it("says which roles are needed when the whispered role is taken, and asks nothing after", function()
        local world, tank = building()
        tank:whisperFrom("Other Tank", "tank lf group")
        assert.is_false(invited(tank, "Other Tank"))
        assert.truthy(repliesTo(tank, "Other Tank")[1]:find("Sorry, we only need DPS right now%."))
        for _, text in ipairs({ "got ya", ":)" }) do
            world:advance(5)
            tank:whisperFrom("Other Tank", text)
        end
        assert.are.equal(1, #repliesTo(tank, "Other Tank"))
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

    it("can be turned off", function()
        local _, tank = building()
        tank.ns.db.noWhisperInvite = true
        tank:whisperFrom("Second Dps", "dps")
        assert.is_false(invited(tank, "Second Dps"))
        assert.are.same({}, repliesTo(tank, "Second Dps"))

        tank.ns.db.noWhisperInvite = nil
        tank:whisperFrom("Second Dps", "dps")
        assert.is_true(invited(tank, "Second Dps"))
    end)

    it("ignores whispers of other Forever Groups players, also of the old DungeonQueue", function()
        local _, tank = building()
        tank:whisperFrom("Old Builder", "[DungeonQueue] Hi! Our group for The Deadmines needs a dps. Inviting you now.")
        tank:whisperFrom("New Builder", "[Forever Groups] Hi! Our group needs a dps. Inviting you now.")
        assert.is_false(invited(tank, "Old Builder"))
        assert.is_false(invited(tank, "New Builder"))
        assert.are.same({}, repliesTo(tank, "Old Builder"))
    end)

    it("does not promise a place every open invite holds, and invites the whisperer when one frees up", function()
        local world = World.new()
        local tank = world:addClient("Solo Tank", { level = 20 })
        world:list("Heal A", "H", 799, 20, 900)
        for i = 1, 3 do
            world:list("Dps " .. i, "D", 799, 20, 900 - i)
        end
        world:advance(30)
        tank.ns.charDb.wantsLead = true
        tank:slash("/dq join tank dm")
        world:advance(3)
        tank:joins("Dps 1")
        tank:joins("Dps 2")
        world:advance(30)
        assert.are.equal("HD", tank.ns.Filler.stillNeeded())
        tank:whisperFrom("Whisper Dps", "dps inv?")
        world:advance(2)
        assert.are.same({}, tank.refusedInvites)
        assert.are.same({}, repliesTo(tank, "Whisper Dps"))
        world:advance(40)
        assert.is_true(invited(tank, "Whisper Dps"))
        assert.truthy(repliesTo(tank, "Whisper Dps")[1]:find("Inviting you as dps for The Deadmines"))
    end)

    it("keeps a whisperer waiting until a held place is free, however late it frees", function()
        local world = World.new()
        local tank = world:addClient("Solo Tank", { level = 20 })
        for i = 1, 3 do
            world:list("Dps " .. i, "D", 799, 20, 300 - i)
        end
        world:advance(30)
        tank:slash("/dq join tank dm")
        world:advance(2)
        assert.are.equal("H", tank.ns.Filler.stillNeeded())
        tank.ns.Invites.send("Quest Guy", "quests")
        assert.are.equal(0, tank.ns.Filler.room())
        world:advance(1)
        tank:whisperFrom("Whisper Heal", "heal inv?")
        assert.is_false(invited(tank, "Whisper Heal"))
        world:advance(80)
        assert.is_true(invited(tank, "Whisper Heal"))
    end)

    it("asks a whisperer told no in an earlier group their role again in a later one", function()
        local world = World.new()
        local tank = world:addClient("Solo Tank", { level = 20 })
        world:list("Listed Heal", "H", 799, 20, 300)
        world:advance(30)
        tank:slash("/dq join tank dm")
        world:advance(2)
        assert.are.equal("DDD", tank.ns.Filler.stillNeeded())
        tank:whisperFrom("Some Player", "tank here, inv?")
        assert.are.equal(1, #repliesTo(tank, "Some Player"))
        local dungeons = tank.ns.Filler.dungeonIds()
        tank.ns.Filler.stop()
        world:advance(60)
        tank.ns.Filler.start({ missing = "HDDD", dungeons = dungeons })
        tank:whisperFrom("Some Player", "inv pls")
        assert.are.equal(2, #repliesTo(tank, "Some Player"))
    end)

    local function wantsDruidTank(world)
        local lead = world:addClient("Lead Priest", { level = 20, class = "PRIEST" })
        world:advance(30)
        lead.ns.charDb.wantsLead = true
        lead.ns.charDb.compose = { masks = { 256, 0, 0, 0, 0 } }
        lead.ns.charDb.composeOn = true
        lead:slash("/dq join heal dm")
        world:advance(2)
        assert.is_true(lead.ns.Filler.isActive())
        return lead
    end

    it("reads a whisperer's class to give them a place the class wishes keep for it", function()
        local world = World.new()
        local lead = wantsDruidTank(world)
        lead:whisperFrom("Warrior Tank", "tank inv?", "WARRIOR")
        lead:whisperFrom("Unknown Tank", "tank inv?")
        assert.is_false(invited(lead, "Warrior Tank"))
        assert.is_false(invited(lead, "Unknown Tank"))
        lead:whisperFrom("Paj Verus", "tank inv?", "DRUID")
        assert.is_true(invited(lead, "Paj Verus"))
        assert.are.equal("T", lead.ns.Filler.roleOf("Paj Verus"))
    end)

    it("names only the places a whisperer's class can take, and tells a class no place takes once", function()
        local world = World.new()
        local lead = wantsDruidTank(world)
        lead:whisperFrom("Warrior Guy", "can i join", "WARRIOR")
        local asked = repliesTo(lead, "Warrior Guy")[1]
        assert.truthy(asked:find("Still needed: DPS", 1, true))
        assert.is_falsy(asked:find("Tank", 1, true))

        lead.ns.charDb.compose = { masks = { 256, 0, 256, 256, 256 } }
        lead.ns.Window.refresh()
        lead:whisperFrom("Hunter Guy", "lol nice", "HUNTER")
        assert.are.same({}, repliesTo(lead, "Hunter Guy"))
        lead:whisperFrom("Hunter Guy", "can i join", "HUNTER")
        lead:whisperFrom("Hunter Guy", "dps", "HUNTER")
        assert.are.same({ "[Forever Groups] Sorry, we are not looking for a Hunter right now." },
            repliesTo(lead, "Hunter Guy"))
        assert.is_false(invited(lead, "Hunter Guy"))
        lead:whisperFrom("Paj Verus", "can i join", "DRUID")
        assert.truthy(repliesTo(lead, "Paj Verus")[1]:find("Still needed: Tank, DPS", 1, true))
    end)

    it("answers a whisperer it asked for their role when their class no longer has a place", function()
        local world = World.new()
        local lead = wantsDruidTank(world)
        lead:whisperFrom("Pala Guy", "can i join", "PALADIN")
        assert.truthy(repliesTo(lead, "Pala Guy")[1]:find("Which role do you play", 1, true))
        lead.ns.charDb.compose = { masks = { 256, 0, 256, 256, 256 } }
        lead.ns.Window.refresh()
        lead:whisperFrom("Pala Guy", "hmm what do you need", "PALADIN")
        assert.are.equal("[Forever Groups] Sorry, we are not looking for a Paladin right now.",
            repliesTo(lead, "Pala Guy")[2])
    end)

    it("invites a class that plays one role only without asking its role", function()
        local world = World.new()
        local lead = wantsDruidTank(world)
        lead:whisperFrom("Mage Guy", "can i join", "MAGE")
        assert.is_true(invited(lead, "Mage Guy"))
        assert.are.equal("D", lead.ns.Filler.roleOf("Mage Guy"))
        assert.truthy(repliesTo(lead, "Mage Guy")[1]:find("Inviting you as dps", 1, true))
        lead:whisperFrom("Pala Guy", "can i join", "PALADIN")
        assert.is_false(invited(lead, "Pala Guy"))
        assert.truthy(repliesTo(lead, "Pala Guy")[1]:find("Which role do you play", 1, true))
    end)

    it("takes a whisperer's class from their Group Finder listing", function()
        local world = World.new()
        world:list("Bear Druid", "T", 799, 60, 300)
        world.listings[#world.listings].class = "DRUID"
        local lead = wantsDruidTank(world)
        assert.is_false(invited(lead, "Bear Druid"))
        lead:whisperFrom("Bear Druid", "tank?")
        assert.is_true(invited(lead, "Bear Druid"))
    end)
end)
