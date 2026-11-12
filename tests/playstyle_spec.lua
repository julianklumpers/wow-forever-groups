local World = require("tests.helpers.wowmock")
local Matchmaker = require("core.matchmaker")
local Playstyles = require("core.playstyles")

local LEARNING, RELAXED, SERIOUS, EXPERT = 1, 2, 3, 4

local function entry(id, joinedAt, role, playstyle)
    return { id = id, joinedAt = joinedAt, dungeons = { "DM" }, members = { { name = id, roles = role, level = 20 } },
        playstyle = playstyle }
end

local function ids(group)
    local list = {}
    for _, e in ipairs(group.entries) do
        list[#list + 1] = e.id
    end
    table.sort(list)
    return list
end

describe("playstyles", function()
    it("go together within a camp: Learning with Relaxed, Serious with Expert", function()
        assert.is_true(Playstyles.compatible(LEARNING, RELAXED))
        assert.is_true(Playstyles.compatible(SERIOUS, EXPERT))
        assert.is_false(Playstyles.compatible(RELAXED, SERIOUS))
        assert.is_false(Playstyles.compatible(LEARNING, EXPERT))
        assert.is_true(Playstyles.compatible(Playstyles.ANY, EXPERT))
    end)

    it("never puts the two camps in one group", function()
        local entries = {
            entry("Tank", 1, "T", RELAXED), entry("FastHeal", 2, "H", EXPERT), entry("CalmHeal", 3, "H", LEARNING),
            entry("Dps1", 4, "D"), entry("Dps2", 5, "D"), entry("Dps3", 6, "D", SERIOUS), entry("Dps4", 7, "D"),
        }
        local groups = Matchmaker.findGroups(entries)
        assert.are.equal(1, #groups)
        assert.are.same({ "CalmHeal", "Dps1", "Dps2", "Dps4", "Tank" }, ids(groups[1]))
        assert.are.same({ RELAXED, LEARNING }, groups[1].playstyles)
    end)

    it("keeps the camps apart when the longest waiting player has no preference", function()
        local entries = {
            entry("Tank", 1, "T"), entry("FastHeal", 2, "H", EXPERT), entry("CalmDps", 3, "D", RELAXED),
            entry("Dps4", 4, "D"), entry("Dps5", 5, "D"), entry("Dps6", 6, "D"),
        }
        local groups = Matchmaker.findGroups(entries)
        assert.are.same({ "Dps4", "Dps5", "Dps6", "FastHeal", "Tank" }, ids(groups[1]))
        local partial = Matchmaker.findPartialGroup({ entry("Tank", 1, "T"), entry("FastHeal", 2, "H", EXPERT),
            entry("CalmDps", 3, "D", RELAXED) }, { T = 1, H = 1, D = 3 }, 1000, 120, 2)
        assert.are.same({ "FastHeal", "Tank" }, ids(partial))
    end)

    it("names a group by the playstyle most players picked", function()
        assert.are.same({ LEARNING, RELAXED }, Playstyles.mix({
            { playstyle = RELAXED, players = 1 }, { playstyle = LEARNING, players = 2 },
        }))
        assert.are.same({ EXPERT, SERIOUS }, Playstyles.mix({
            { playstyle = EXPERT, players = 3 }, { playstyle = SERIOUS, players = 1 }, { players = 1 },
        }))
        assert.are.same({ SERIOUS, EXPERT }, Playstyles.mix({
            { playstyle = EXPERT, players = 1 }, { playstyle = SERIOUS, players = 1 },
        }))
        assert.are.same({}, Playstyles.mix({ { players = 5 } }))
    end)

    it("keeps the camps apart in a group that leaves roles for the Group Finder too", function()
        local entries = { entry("Tank", 1, "T", EXPERT), entry("Heal", 2, "H", RELAXED), entry("Dps", 3, "D") }
        local group = Matchmaker.findPartialGroup(entries, { T = 1, H = 1, D = 3 }, 1000, 120, 2)
        assert.are.same({ "Dps", "Tank" }, ids(group))
        assert.are.same({ EXPERT }, group.playstyles)
    end)
end)

describe("playstyles in the game", function()
    local function queue(world, name, role, style)
        local client = world:addClient(name, { level = 20 })
        world:advance(8)
        if style then
            client:slash("/dq style " .. style)
        end
        client:slash("/dq join " .. role .. " dm")
        world:advance(1)
        return client
    end

    it("forms a group from one camp and shows its playstyles", function()
        local world = World.new()
        local players = { { "Tanky Mctank", "tank", "relaxed" }, { "Fast Heal", "healer", "expert" },
            { "Calm Heal", "healer", "learning" }, { "Dps 1", "dps" }, { "Dps 2", "dps" }, { "Dps 3", "dps" } }
        local clients = {}
        for i, p in ipairs(players) do
            clients[i] = world:addClient(p[1], { level = 20 })
        end
        world:advance(8)
        for i, p in ipairs(players) do
            clients[i]:slash("/dq style " .. (p[3] or "any"))
            clients[i]:slash("/dq join " .. p[2] .. " dm")
        end
        world:advance(20)
        local tank, fast = clients[1], clients[2]
        assert.is_true(tank:proposalShown())
        assert.is_not_nil(tank:findText("^The Deadmines$"))
        assert.is_not_nil(tank:findText("^Relaxed · Learning$"))
        assert.is_not_nil(tank:findText("^you play Tank$"))
        assert.is_false(fast:proposalShown())
        assert.is_not_nil(fast.ns.engine.myEntry)
    end)

    local function proposeTo(client, seq, partner, playstyles)
        local before = #client.sent
        client.ns.engine:addProposal("Tanky Mctank", {
            seq = seq, dungeon = "5", entries = { { { name = partner, role = "T" } },
                { { name = client.name, role = "H" } } }, missing = "DDD", playstyles = playstyles,
        })
        for i = before + 1, #client.sent do
            local answer = client.sent[i]:match("^v2|A|Tanky Mctank|" .. seq .. "|(%a)$")
            if answer then
                return answer
            end
        end
    end

    it("turns down a proposal that mixes the camps", function()
        local world = World.new()
        local expert = queue(world, "Fast Heal", "healer", "expert")
        queue(world, "Tanky Mctank", "tank", "relaxed")
        world:advance(2)
        assert.are.equal("C", proposeTo(expert, 1, "Tanky Mctank", {}))
        assert.are.equal("C", proposeTo(expert, 2, "Unknown Tank", { RELAXED }))
        assert.is_false(expert:proposalShown())
        assert.are.equal("R", proposeTo(expert, 3, "Unknown Tank", { SERIOUS }))
    end)

    it("only invites Group Finder players whose playstyle fits", function()
        local world = World.new()
        world:list("Expert Heal", "H", 799, 20, 400, "Expert")
        world:list("Calm Heal", "H", 799, 20, 300, "Learning")
        local tank = world:addClient("Solo Tank", { level = 20 })
        world:advance(30)
        tank:slash("/dq style relaxed")
        tank:slash("/dq join tank dm")
        world:advance(2)
        assert.are.same({ "Calm Heal" }, tank.invites)
        tank:press("W")
        assert.are.equal(World.PLAYSTYLE.FunRelaxed, tank.listingArgs[1].generalPlaystyle)
    end)

    it("only asks Group Finder groups whose playstyle fits", function()
        local world = World.new()
        world:listGroup("Fast Group", 799, { T = 0, H = 0, D = 2 }, 400, "Expert")
        world:listGroup("Calm Group", 799, { T = 0, H = 0, D = 2 }, 300, "FunRelaxed")
        local solo = world:addClient("Solo Dps", { level = 20 })
        world:advance(30)
        solo:slash("/dq style learning")
        solo:slash("/dq join dps dm")
        world:advance(2)
        local asked = {}
        for _, w in ipairs(solo.whispers) do
            if w.text:find("could you invite me") then
                asked[#asked + 1] = w.target
            end
        end
        assert.are.same({ "Calm Group" }, asked)
    end)

    it("lets the player choose in the window", function()
        local world = World.new()
        world:list("Listed Heal", "H", 799, 20, 300)
        local client = world:addClient("Solo Tank", { level = 20 })
        world:advance(30)
        client:slash("/dq")
        assert.is_not_nil(client:findText("^Grouped with Relaxed and Learning players%.$"))
        assert.is_true(client:find("CheckButton", "Relaxed"):GetChecked())
        assert.is_nil(client:find("CheckButton", "No preference"))
        client:slash("/dq style any")
        assert.are.equal(RELAXED, client.ns.Playstyle.mine())
        client.ns.charDb.playstyle = 0
        assert.are.equal(RELAXED, client.ns.Playstyle.mine())
        client:click("CheckButton", "Expert")
        assert.are.equal(EXPERT, client.ns.charDb.playstyle)
        client:slash("/dq style serious")
        assert.is_true(client:find("CheckButton", "Serious"):GetChecked())
        assert.is_false(client:find("CheckButton", "Expert"):GetChecked())
        client:click("CheckButton", "Expert")
        assert.is_not_nil(client:findText("^Grouped with Expert and Serious players%.$"))
        client:click("CheckButton", "Tank")
        client:slash("/dq join tank dm")
        client.ns.Filler.stop()
        world:advance(1)
        assert.are.equal(EXPERT, client.ns.engine.myEntry.playstyle)
        assert.is_not_nil(client:findText("^Searching 1 dungeon  ·  Expert or Serious$"))
    end)
end)
