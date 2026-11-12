local World = require("tests.helpers.wowmock")
local Specs = require("core.specs")
local Protocol = require("core.protocol")

local ENHANCEMENT = { { 5000, 5 }, { 5200, 3 }, { 6000, 3 }, { 1500, 1 } }
local RESTORATION = { { 9500, 10 }, { 5000, 2 } }

describe("specs from talent points", function()
    it("tell the tree by the talent's column and take the tree with the most points", function()
        assert.are.equal(1, Specs.treeForX(1200))
        assert.are.equal(2, Specs.treeForX(6800))
        assert.are.equal(3, Specs.treeForX(10900))
        assert.are.equal(2, Specs.dominant({ 1, 11, 0 }))
        assert.is_nil(Specs.dominant({ 5, 5, 0 }))
        assert.is_nil(Specs.dominant({ 0, 0, 0 }))
        assert.are.same({ name = "Feral", roles = "TD" }, Specs.tree("DRUID", 2))
    end)

    it("travel in the queue entry, and an unknown one is left out", function()
        local entry = {
            kind = "queue", joinedAt = 1, dungeons = { "5" }, since = 0, spec = "SHAMAN2",
            members = { { name = "Roos Bief", roles = "D", level = 20 } },
        }
        local text = assert(Protocol.encode(entry))
        assert.are.equal("v2|Q|1|5|Roos Bief:D:20||0||SHAMAN2", text)
        assert.are.equal("SHAMAN2", Protocol.decode(text).spec)
        local odd = Protocol.decode("v2|Q|1|5|Roos Bief:D:20||0||DEATHKNIGHT9")
        assert.is_not_nil(odd)
        assert.is_nil(odd.spec)
    end)
end)

describe("the player's spec in the game", function()
    local function shaman(world, name, talents)
        return world:addClient(name, { level = 20, class = "SHAMAN", talents = talents })
    end

    it("ticks the spec's roles when the spec changes, and keeps the player's own ticks after that", function()
        local world = World.new()
        local client = shaman(world, "Roos Bief", ENHANCEMENT)
        world:advance(12)
        assert.are.equal("D", client.ns.charDb.lastRoles)
        client.ns.charDb.lastRoles = "HD"
        client:fire("TRAIT_CONFIG_UPDATED")
        assert.are.equal("HD", client.ns.charDb.lastRoles)
        client:slash("/dq join dps dm")
        assert.are.equal("SHAMAN2", client.ns.engine.myEntry.spec)
        client.talents = RESTORATION
        client:fire("TRAIT_CONFIG_UPDATED")
        assert.are.equal("H", client.ns.charDb.lastRoles)
        assert.are.equal("SHAMAN3", client.ns.engine.myEntry.spec)
    end)

    it("is named in the whisper that asks a listed group to invite you", function()
        local world = World.new()
        local client = shaman(world, "Roos Bief", ENHANCEMENT)
        world:advance(30)
        world:listGroup("Group Lead", 799, { T = 0, H = 0, D = 2 })
        client:slash("/dq join dps dm")
        world:advance(2)
        assert.is_truthy(client.whispers[1].text:find(
            "Hi! Level 20 Enhancement Shaman (DPS) here, could you invite me for The Deadmines?", 1, true))
    end)

    it("ends an invite whisper", function()
        local world = World.new()
        world:list("Listed Heal", "H", 799, 20, 300)
        local client = shaman(world, "Roos Bief", ENHANCEMENT)
        world:advance(30)
        client:slash("/dq join tank dm")
        world:advance(2)
        local found = false
        for _, w in ipairs(client.whispers) do
            found = found or w.text:find("Inviting you now. I'm the Enhancement Shaman.", 1, true) ~= nil
        end
        assert.is_true(found)
    end)

    it("warns when the queued roles fit none of the spec, without stopping it", function()
        local world = World.new()
        local client = shaman(world, "Roos Bief", ENHANCEMENT)
        world:advance(12)
        client:slash("/dq join healer dm")
        assert.is_true(client:said("You queue as Healer, but most of your talents are in Enhancement"))
        assert.is_not_nil(client.ns.engine.myEntry)
    end)

    it("shows the other players' specs in the popup and on the group card", function()
        local world = World.new()
        local players = {
            { "Tanky Mctank", "tank", "WARRIOR", { { 9500, 5 } } },
            { "Heally Mcheal", "healer", "SHAMAN", RESTORATION },
            { "Dps One", "dps", "SHAMAN", ENHANCEMENT }, { "Dps Two", "dps" }, { "Dps Three", "dps" },
        }
        local clients = {}
        for i, p in ipairs(players) do
            clients[i] = world:addClient(p[1], { level = 20, class = p[3], talents = p[4] })
        end
        world:advance(8)
        for i, p in ipairs(players) do
            clients[i]:slash("/dq join " .. p[2] .. " dm")
        end
        world:advance(20)
        local dps = clients[5]
        assert.is_true(dps:proposalShown())
        assert.are.equal("Restoration Shaman", dps:find("FontString", "Heally Mcheal").parent.detail.text)
        assert.are.equal("Protection Warrior", dps:find("FontString", "Tanky Mctank").parent.detail.text)
        assert.is_not_nil(dps:findText("^Dps Two$"))
        for _, client in ipairs(clients) do
            client:acceptPopup()
        end
        world:advance(5)
        local tank = clients[1]
        tank.party = { "Heally Mcheal", "Dps One", "Dps Two", "Dps Three" }
        tank:slash("/dq")
        assert.is_not_nil(tank:findText("^Enhancement$"))
        assert.is_not_nil(tank:findText("^Protection$"))
    end)
end)
