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

    it("stays out of an invite whisper unless the player's own text asks for it", function()
        local world = World.new()
        world:list("Listed Heal", "H", 799, 20, 300)
        world:list("Listed Dps", "D", 799, 20, 300)
        local client = shaman(world, "Roos Bief", ENHANCEMENT)
        world:advance(30)
        client:slash("/dq join dps dm")
        world:advance(2)
        local invite
        for _, w in ipairs(client.whispers) do
            invite = invite or (w.text:find("Inviting you now.", 1, true) and w.text)
        end
        assert.are.equal("[Forever Groups] Hi! Our group for The Deadmines needs a healer. Inviting you now.", invite)
        local Messages = client.ns.Messages
        Messages.set("fillInvite", "Need a {role}. I'm the {spec}.")
        assert.are.equal("[Forever Groups] Need a Healer. I'm the Enhancement Shaman.",
            Messages.text("fillInvite", { role = "Healer", spec = "Enhancement Shaman" }))
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
        assert.is_not_nil(tank:findText("|cffe6c273Enhancement|r$"))
        assert.is_not_nil(tank:findText("|cffe6c273Protection|r$"))
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
    it("show their spec art when known, else their class's emblem, and their class icon before the name", function()
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
        local tank, me = slots[1], slots[3]
        assert.are.equal("Any class", slots[2].text.text)
        assert.is_true(slots[2].arrow.shown)
        assert.is_true(slots[2].enabled)
        assert.is_false(tank.enabled)
        assert.are.equal("Some Tank", tank.name.text)
        assert.is_true(tank.art.shown)
        assert.is_true(tank.emblem)
        assert.are.equal("classicon-warrior", tank.art.atlas)
        assert.is_true(tank.art.alpha < 1)
        assert.are.equal("Protection", tank.lines[2].text)
        assert.is_true(tank.nameIcon.shown)
        assert.are.equal("classicon-warrior", tank.nameIcon.atlas)
        assert.are.equal("Roos Bief", me.name.text)
        assert.is_true(me.art.shown)
        assert.is_false(me.emblem)
        assert.are.equal("spec-thumbnail-shaman-enhancement", me.art.atlas)
        assert.is_false(me.nameIcon ~= nil and me.nameIcon.shown)
        assert.are.equal("Shaman |cffe6c273Enhancement|r", me.lines[2].text)
    end)
end)

describe("a hybrid spec", function()
    it("names the main tree and any other with a third of the points, most points first", function()
        local world = World.new()
        local client = world:addClient("Lead Player", { level = 20, class = "WARRIOR",
            atlases = { ["classicon-priest"] = true } })
        world:advance(12)
        local Spec = client.ns.Spec
        Spec.learn("Hybrid Priest", "PRIEST", { 0, 20, 31 })
        Spec.learn("Holy Priest", "PRIEST", { 0, 51, 0 })
        Spec.learn("Disc Priest", "PRIEST", { 41, 10, 0 })
        Spec.learn("Low Priest", "PRIEST", { 0, 3, 8 })
        Spec.learn("Low Hybrid", "PRIEST", { 0, 5, 6 })
        Spec.learn("No Points", "PRIEST", { 0, 0, 0 })
        assert.are.same({ "Shadow", "Holy" }, Spec.treesOf("Hybrid Priest"))
        assert.are.same({ "Holy" }, Spec.treesOf("Holy Priest"))
        assert.are.same({ "Discipline" }, Spec.treesOf("Disc Priest"))
        assert.are.same({ "Shadow" }, Spec.treesOf("Low Priest"))
        assert.are.same({ "Shadow", "Holy" }, Spec.treesOf("Low Hybrid"))
        assert.is_nil(Spec.treesOf("No Points"))
        assert.is_nil(Spec.treesOf("Nobody Known"))

        local W = client.ns.WindowParts
        client:slash("/dq")
        local card = W.slots[1]
        W.paintPlace(card, { role = "H", name = "Hybrid Priest", classToken = "PRIEST", specIndex = 3 },
            { width = 100, layout = {} })
        assert.are.equal("Shadow/Holy", card.lines[2].text)
        W.paintPlace(card, { role = "H", name = "Low Priest", classToken = "PRIEST", specIndex = 3 },
            { width = 100, layout = {} })
        assert.are.equal("Shadow", card.lines[2].text)
        W.paintPlace(card, { role = "H", name = "Nobody Known", classToken = "PRIEST" }, { width = 100, layout = {} })
        assert.are.equal("Healer", card.lines[2].text)
    end)
end)

describe("the group card's places", function()
    it("show their own trees when their points are known, else the tree that plays the place's role", function()
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
        local healer, dps = client.ns.WindowParts.slots[2], client.ns.WindowParts.slots[3]
        assert.are.equal("Roos Bief", healer.name.text)
        assert.are.equal("spec-thumbnail-druid-restoration", healer.art.atlas)
        assert.is_truthy(healer.lines[2].text:find("Feral", 1, true))
        assert.are.equal("Cat Druid", dps.name.text)
        assert.are.equal("spec-thumbnail-druid-feral", dps.art.atlas)
        assert.is_truthy(dps.lines[2].text:find("Feral", 1, true))
        assert.are.equal("Restoration Druid", client.ns.Spec.labelInRole("DRUID2", "H"))
        assert.are.equal("Feral Druid", client.ns.Spec.labelInRole("DRUID2", "T"))
        assert.are.equal("Druid", client.ns.Spec.labelInRole("DRUID3", "D"))
        assert.are.equal("Holy Priest", client.ns.Spec.labelInRole("PRIEST2", "H"))
        assert.are.equal("Priest", client.ns.Spec.labelInRole("PRIEST3", "H"))
    end)
end)

describe("trees told over the party channel", function()
    it("show a party member's own trees, and the player's own when WoW gives no points for a moment", function()
        local world = World.new()
        local lay = world:addClient("Lay Ohands", { level = 22, class = "PALADIN",
            talents = { { 1000, 5 }, { 9000, 8 } } })
        local swole = world:addClient("Swole Mcg", { level = 22, class = "WARRIOR",
            talents = { { 1000, 6 }, { 5000, 2 } } })
        world:advance(12)
        lay.party, lay.isLeader = { "Swole Mcg" }, true
        swole.party = { "Lay Ohands" }
        lay.partyClasses["Swole Mcg"], swole.partyClasses["Lay Ohands"] = "WARRIOR", "PALADIN"
        lay:fire("GROUP_ROSTER_UPDATE")
        swole:fire("GROUP_ROSTER_UPDATE")
        world:advance(3)
        assert.are.same({ "Arms" }, lay.ns.Spec.treesOf("Swole Mcg"))
        assert.are.same({ "Retribution", "Holy" }, swole.ns.Spec.treesOf("Lay Ohands"))
        lay.talents = nil
        assert.are.same({ "Retribution", "Holy" }, lay.ns.Spec.treesOf("Lay Ohands"))
    end)

    it("sends its points again for a newcomer only, not at every roster update", function()
        local world = World.new()
        local lay = world:addClient("Lay Ohands", { level = 22, class = "PALADIN",
            talents = { { 1000, 5 }, { 9000, 8 } } })
        world:advance(12)
        lay.party, lay.isLeader = { "Swole Mcg" }, true
        lay:fire("GROUP_ROSTER_UPDATE")
        world:advance(3)
        local function sent()
            local count = 0
            for _, text in ipairs(lay.sent) do
                count = count + (text:find("^v1|SP|") and 1 or 0)
            end
            return count
        end
        assert.are.equal(1, sent())
        for _ = 1, 3 do
            lay:fire("GROUP_ROSTER_UPDATE")
            world:advance(3)
        end
        assert.are.equal(1, sent())
        local fullName = lay.env.UnitFullName
        lay.env.UnitFullName = function(unit)
            if unit == "party1" then
                return nil
            end
            return fullName(unit)
        end
        lay:fire("GROUP_ROSTER_UPDATE")
        world:advance(3)
        lay.env.UnitFullName = fullName
        lay:fire("GROUP_ROSTER_UPDATE")
        world:advance(3)
        assert.are.equal(1, sent())
        lay.party = { "Swole Mcg", "New Friend" }
        lay:fire("GROUP_ROSTER_UPDATE")
        world:advance(3)
        assert.are.equal(2, sent())
    end)

    local function trio()
        local world = World.new()
        local lay = world:addClient("Lay Ohands", { level = 22, class = "PALADIN",
            talents = { { 1000, 5 }, { 9000, 8 } } })
        local swole = world:addClient("Swole Mcg", { level = 22, class = "WARRIOR",
            talents = { { 1000, 6 }, { 5000, 2 } } })
        local heally = world:addClient("Heally Mcheal", { level = 22, class = "PRIEST",
            talents = { { 5000, 9 } } })
        world:advance(12)
        lay.party, lay.isLeader = { "Swole Mcg" }, true
        swole.party = { "Lay Ohands" }
        lay.partyClasses["Swole Mcg"], swole.partyClasses["Lay Ohands"] = "WARRIOR", "PALADIN"
        lay:fire("GROUP_ROSTER_UPDATE")
        swole:fire("GROUP_ROSTER_UPDATE")
        world:advance(3)
        local function join()
            lay.party = { "Swole Mcg", "Heally Mcheal" }
            swole.party = { "Lay Ohands", "Heally Mcheal" }
            heally.party = { "Lay Ohands", "Swole Mcg" }
            lay.partyClasses["Heally Mcheal"], swole.partyClasses["Heally Mcheal"] = "PRIEST", "PRIEST"
            heally.partyClasses["Lay Ohands"], heally.partyClasses["Swole Mcg"] = "PALADIN", "WARRIOR"
            lay:fire("GROUP_ROSTER_UPDATE")
            swole:fire("GROUP_ROSTER_UPDATE")
            heally:fire("GROUP_ROSTER_UPDATE")
        end
        return world, lay, heally, join
    end

    it("sends its points to a newcomer who joins during a boss fight once the fight is over", function()
        local world, lay, heally, join = trio()
        lay.lockdown = true
        join()
        world:advance(3)
        lay.lockdown = false
        world:advance(5)
        assert.are.same({ "Arms" }, heally.ns.Spec.treesOf("Swole Mcg"))
        assert.are.same({ "Retribution", "Holy" }, heally.ns.Spec.treesOf("Lay Ohands"))
    end)

    it("sends its points again when WoW refused the first send", function()
        local world, lay, heally, join = trio()
        lay.sendResults = { 3 }
        join()
        world:advance(8)
        assert.are.same({ "Retribution", "Holy" }, heally.ns.Spec.treesOf("Lay Ohands"))
    end)

    it("shows a member's tied trees, like the player's own", function()
        local world = World.new()
        local client = world:addClient("Lay Ohands", { level = 22, class = "PALADIN" })
        world:advance(12)
        client.ns.Spec.onMessage("Winzi Winz", "v1|SP|PRIEST|6/6/0")
        assert.are.same({ "Discipline", "Holy" }, client.ns.Spec.treesOf("Winzi Winz"))
        client.ns.Spec.learn("Winzi Winz", "PRIEST", { 0, 0, 0 })
        assert.are.same({ "Discipline", "Holy" }, client.ns.Spec.treesOf("Winzi Winz"))
    end)

    it("keeps the specs it learned over a /reload, for four hours", function()
        local world = World.new()
        local client = world:addClient("Lay Ohands", { level = 22, class = "PALADIN" })
        world:advance(12)
        client.ns.Spec.learn("Winzi Winz", "PRIEST", { 0, 10, 6 })
        client.ns.Spec.remember({ members = { { name = "Thalvex Grave", spec = "MAGE2" } } })
        local saved = client:logout()
        local again = world:addClient("Lay Ohands", { level = 22, class = "PALADIN", saved = saved })
        world:advance(12)
        assert.are.same({ "Holy", "Shadow" }, again.ns.Spec.treesOf("Winzi Winz"))
        assert.are.equal("Fire", again.ns.Spec.treeOf("Thalvex Grave"))
        local later = again:logout()
        world:advance(4 * 3600 + 1)
        local next = world:addClient("Lay Ohands", { level = 22, class = "PALADIN", saved = later })
        world:advance(12)
        assert.is_nil(next.ns.Spec.treesOf("Winzi Winz"))
        assert.is_nil(next.ns.Spec.treeOf("Thalvex Grave"))
    end)
end)

describe("the demo's group card", function()
    it("shows the spec of every member, and the player's own spec again after the demo", function()
        local world = World.new()
        local client = world:addClient("Roos Bief", { level = 20, class = "SHAMAN", talents = ENHANCEMENT })
        world:advance(12)
        client:slash("/fg demo")
        client.ns.Demo.show(5)
        local slots = client.ns.WindowParts.slots
        assert.are.equal("Aldric Dawnmere", slots[1].name.text)
        assert.is_truthy(slots[1].lines[2].text:find("Protection", 1, true))
        assert.are.equal("Brynna Coldbrook", slots[2].name.text)
        assert.is_truthy(slots[2].lines[2].text:find("Holy", 1, true))
        client:slash("/fg demo")
        assert.is_nil(client:findText("Aldric Dawnmere"))
        assert.are.equal("Enhancement", client.ns.Spec.current().name)
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
