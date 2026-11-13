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

    it("follows the chosen role in that whisper when the spec plays another role", function()
        local world = World.new()
        local client = shaman(world, "Roos Bief", ENHANCEMENT)
        world:advance(30)
        world:listGroup("Group Lead", 799, { T = 0, H = 1, D = 0 })
        client:slash("/dq join healer dm")
        world:advance(2)
        assert.is_truthy(client.whispers[1].text:find(
            "Hi! Level 20 Restoration Shaman (Healer) here, could you invite me for The Deadmines?", 1, true),
            client.whispers[1].text)
        assert.are.equal("Restoration Shaman", client.ns.Spec.myLabel("H"))
        assert.are.equal("Enhancement Shaman", client.ns.Spec.myLabel("HD"))
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
        tank.partyClasses = { ["Heally Mcheal"] = "SHAMAN", ["Dps One"] = "SHAMAN" }
        tank:slash("/dq")
        assert.is_not_nil(tank:findText("^Enhancement$"))
        assert.is_not_nil(tank:findText("^Protection$"))
    end)
end)

describe("the role tiles' look", function()
    it("picks the tree a class plays a role with and its art", function()
        local tank = Specs.forRole("DRUID", "T")
        assert.are.equal("spec-thumbnail-druid-guardian", tank.atlas)
        assert.are.equal("Feral", tank.name)
        local dps = Specs.forRole("DRUID", "D")
        assert.are.equal("spec-thumbnail-druid-balance", dps.atlas)
        assert.is_nil(dps.name)
        local feral = Specs.forRole("DRUID", "D", 2)
        assert.are.equal("spec-thumbnail-druid-feral", feral.atlas)
        assert.are.equal("Feral", feral.name)
        assert.are.equal("spec-thumbnail-druid-balance", Specs.forRole("DRUID", "D", 3).atlas)
        assert.are.equal("spec-thumbnail-rogue-outlaw", Specs.forRole("ROGUE", "D", 2).atlas)
        assert.is_nil(Specs.forRole("MAGE", "H"))
    end)

    it("shows the class's spec art on the tiles it can play, the plain tile elsewhere", function()
        local world = World.new()
        local atlases = {}
        for _, name in ipairs({ "elemental", "enhancement", "restoration" }) do
            atlases["spec-thumbnail-shaman-" .. name] = true
        end
        local client = world:addClient("Roos Bief", { level = 20, class = "SHAMAN", talents = ENHANCEMENT,
            atlases = atlases })
        world:advance(12)
        client:slash("/dq")
        local dps = client:find("CheckButton", "DPS")
        local healer = client:find("CheckButton", "Healer")
        local tank = client:find("CheckButton", "Tank")
        assert.are.equal("spec-thumbnail-shaman-enhancement", dps.art.atlas)
        assert.is_true(dps.art.shown)
        assert.are.equal("Enhancement", dps.spec.text)
        assert.is_true(dps.icon.shown)
        assert.are.equal("spec-thumbnail-shaman-restoration", healer.art.atlas)
        assert.is_true(healer.art.desaturated)
        assert.is_false(dps.art.desaturated)
        assert.is_false(tank.art.shown == true)
        assert.is_true(tank.icon.shown)
    end)
end)

describe("the group card's members", function()
    it("show their spec art when known, else their class's emblem, with class and spec on one line", function()
        local world = World.new()
        local atlases = { ["spec-thumbnail-shaman-enhancement"] = true, ["classicon-warrior"] = true }
        local client = world:addClient("Roos Bief", { level = 20, class = "SHAMAN", talents = ENHANCEMENT,
            atlases = atlases })
        world:advance(12)
        client.party, client.isLeader = { "Some Tank" }, true
        client.partyClasses["Some Tank"] = "WARRIOR"
        client.roles = { ["Roos Bief"] = "DAMAGER", ["Some Tank"] = "TANK" }
        client.ns.GroupView.track("5")
        client:fire("GROUP_ROSTER_UPDATE")
        client:slash("/dq")
        client.ns.Window.refresh()
        local slots = client.ns.WindowParts.slots
        local tank, me = slots[1], slots[2]
        assert.are.equal("Some Tank", tank.name.text)
        assert.is_true(tank.art.shown)
        assert.is_true(tank.emblem)
        assert.are.equal("classicon-warrior", tank.art.atlas)
        assert.is_true(tank.art.alpha < 1)
        assert.are.equal("Warrior", tank.className.text)
        assert.are.equal("Roos Bief", me.name.text)
        assert.is_true(me.art.shown)
        assert.is_false(me.emblem)
        assert.are.equal("spec-thumbnail-shaman-enhancement", me.art.atlas)
        assert.are.equal("Shaman", me.className.text)
        assert.are.equal("Enhancement", me.specName.text)
    end)
end)

describe("the group card's places", function()
    it("show the spec that plays the place's role when the member's own spec does not", function()
        local world = World.new()
        local atlases = { ["spec-thumbnail-druid-restoration"] = true, ["spec-thumbnail-druid-feral"] = true }
        local client = world:addClient("Roos Bief", { level = 20, class = "DRUID", talents = { { 5000, 8 } },
            atlases = atlases })
        world:advance(12)
        client.party, client.isLeader = { "Cat Druid" }, true
        client.partyClasses["Cat Druid"] = "DRUID"
        client.roles = { ["Roos Bief"] = "HEALER", ["Cat Druid"] = "DAMAGER" }
        client.ns.charDb.lastRoles = "H"
        client.ns.Spec.remember({ members = { { name = "Cat Druid", spec = "DRUID2" } } })
        client.ns.GroupView.track("5")
        client:fire("GROUP_ROSTER_UPDATE")
        client:slash("/dq")
        client.ns.Window.refresh()
        local healer, dps = client.ns.WindowParts.slots[1], client.ns.WindowParts.slots[2]
        assert.are.equal("Roos Bief", healer.name.text)
        assert.are.equal("spec-thumbnail-druid-restoration", healer.art.atlas)
        assert.are.equal("Restoration", healer.specName.text)
        assert.are.equal("Cat Druid", dps.name.text)
        assert.are.equal("spec-thumbnail-druid-feral", dps.art.atlas)
        assert.are.equal("Feral", dps.specName.text)
        assert.are.equal("Restoration Druid", client.ns.Spec.labelInRole("DRUID2", "H"))
        assert.are.equal("Feral Druid", client.ns.Spec.labelInRole("DRUID2", "T"))
        assert.are.equal("Druid", client.ns.Spec.labelInRole("DRUID3", "D"))
        assert.are.equal("Holy Priest", client.ns.Spec.labelInRole("PRIEST2", "H"))
        assert.are.equal("Priest", client.ns.Spec.labelInRole("PRIEST3", "H"))
    end)
end)

describe("/fg preview", function()
    it("shows the group card with a sample group, and hides it again", function()
        local world = World.new()
        local client = world:addClient("Roos Bief", { level = 20, class = "SHAMAN", talents = ENHANCEMENT })
        world:advance(12)
        client:slash("/fg preview")
        local slots = client.ns.WindowParts.slots
        assert.is_true(slots[1].shown)
        assert.are.equal("Sample Tank", slots[1].name.text)
        assert.are.equal("Holy", slots[2].specName.text)
        assert.are.equal("Sample Rogue", slots[4].name.text)
        assert.are.equal("invited", slots[4].className.text)
        assert.are.equal("frees in", slots[5].className.text)
        assert.is_not_nil(client:findText("^Preview: The Deadmines$"))
        client:slash("/fg preview")
        assert.is_nil(client:findText("^Preview: The Deadmines$"))
        assert.is_false(slots[1].shown)
    end)
end)

describe("a group proposal", function()
    it("has the main window step aside while it asks, and brings it back after", function()
        local world = World.new()
        local clients = {}
        for i, p in ipairs({ { "Tanky Mctank", "tank" }, { "Heally Mcheal", "healer" }, { "Dps One", "dps" },
            { "Dps Two", "dps" }, { "Dps Three", "dps" } }) do
            clients[i] = world:addClient(p[1], { level = 20 })
            clients[i].role = p[2]
        end
        world:advance(8)
        local tank = clients[1]
        tank:slash("/dq")
        assert.is_true(tank.ns.Window.isShown())
        for _, client in ipairs(clients) do
            client:slash("/dq join " .. client.role .. " dm")
        end
        world:advance(20)
        assert.is_true(tank:proposalShown())
        assert.is_false(tank.ns.Window.isShown())
        assert.is_false(clients[2].ns.Window.isShown())
        tank:declinePopup()
        world:advance(1)
        assert.is_true(tank.ns.Window.isShown())
        assert.is_false(clients[2].ns.Window.isShown())
    end)
end)
