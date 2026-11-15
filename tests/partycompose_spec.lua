local World = require("tests.helpers.wowmock")

local CONNECT = 30
local LEAD = "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:16:16|t Lead a group"

local function leader(world, class)
    local client = world:addClient("Lead Player", { level = 20, class = class or "WARRIOR" })
    world:advance(CONNECT)
    client:slash("/dq")
    client:click("CheckButton", "Tank")
    return client
end

describe("composing the party", function()
    it("is offered only to a player who builds the group", function()
        local world = World.new()
        local client = leader(world)
        assert.is_nil(client:find("CheckButton", "Choose the classes in my party"))
        client:click("Button", LEAD)
        assert.is_not_nil(client:find("CheckButton", "Choose the classes in my party"))
    end)

    -- Ticks these class names in a place card's dropdown menu.
    local function pick(client, card, names)
        for _, name in ipairs(names) do
            for _, item in ipairs(client:dropdownItems(card)) do
                if item.text == name then
                    item.pick()
                end
            end
        end
    end

    it("shows the places as cards, the player's own fixed, each a dropdown of the classes its role allows", function()
        local world = World.new()
        local client = leader(world)
        client:click("Button", LEAD)
        client:click("CheckButton", "Choose the classes in my party")
        local cards = client.ns.WindowParts.composeCards
        assert.are.equal("You", cards[1].lines[1].text)
        assert.are.equal("Warrior", cards[1].lines[2].text)
        assert.is_false(cards[1].enabled)
        assert.are.equal("Any class", cards[2].text.text)
        local names = {}
        for _, item in ipairs(client:dropdownItems(cards[2])) do
            names[#names + 1] = item.text
        end
        assert.are.same({ "Any class", "Paladin", "Priest", "Shaman", "Druid" }, names)
    end)

    it("falls back to its own class list on a client without WoW's dropdown menu", function()
        local world = World.new()
        local client = world:addClient("Lead Player", { level = 20, class = "WARRIOR", noDropdownButton = true })
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("CheckButton", "Tank")
        client:click("Button", LEAD)
        client:click("CheckButton", "Choose the classes in my party")
        local card = client.ns.WindowParts.composeCards[2]
        client.inClick = true
        card.scripts.OnClick(card)
        client.inClick = false
        assert.is_nil(client:find("Button", "Warrior"))
        client:click("Button", "Priest")
        assert.are.same({ 0, 16, 0, 0, 0 }, client.ns.charDb.compose.masks)
    end)

    it("keeps the wished classes on the cards and sends them with the queue entry", function()
        local world = World.new()
        local client = leader(world)
        client:click("Button", LEAD)
        client:click("CheckButton", "Choose the classes in my party")
        local cards = client.ns.WindowParts.composeCards
        assert.is_true(cards[3].plus.shown)
        assert.is_true(cards[3].dashed)
        pick(client, cards[3], { "Mage", "Rogue", "Warlock" })
        assert.are.same({ "Rogue", "Mage" }, { cards[3].lines[1].text, cards[3].lines[2].text })
        assert.are.equal("+1 more", cards[3].text.text)
        assert.is_false(cards[3].plus.shown)
        assert.is_false(cards[3].dashed)
        pick(client, cards[3], { "Rogue", "Warlock" })
        assert.are.equal("Mage", cards[3].lines[1].text)
        assert.are.equal("", cards[3].text.text)
        assert.are.same({ 0, 0, 64, 0, 0 }, client.ns.charDb.compose.masks)
        client:click("Button", "Find players")
        local entry = client.ns.engine.myEntry
        assert.are.equal("0:0.0.64.0.0", entry.compose)
    end)

    it("shows the wished classes as their icons where the client has them", function()
        local world = World.new()
        local atlases = {}
        for _, class in ipairs({ "WARRIOR", "HUNTER", "ROGUE", "MAGE", "WARLOCK" }) do
            atlases["classicon-" .. string.lower(class)] = true
        end
        local client = world:addClient("Lead Player", { level = 20, class = "WARRIOR", atlases = atlases })
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("CheckButton", "Tank")
        client:click("Button", LEAD)
        client:click("CheckButton", "Choose the classes in my party")
        local cards = client.ns.WindowParts.composeCards
        assert.are.equal("classicon-warrior", cards[1].art.atlas)
        assert.are.equal("You", cards[1].lines[1].text)
        pick(client, cards[3], { "Mage", "Rogue", "Warlock", "Hunter", "Warrior" })
        local shown = {}
        for _, icon in ipairs(cards[3].classIcons) do
            if icon.shown then
                shown[#shown + 1] = icon.atlas
            end
        end
        assert.are.same({ "classicon-warrior", "classicon-hunter", "classicon-rogue", "classicon-mage",
            "classicon-warlock" }, shown)
        assert.are.equal("", cards[3].lines[1].text)
        assert.are.equal("", cards[3].text.text)
    end)

    it("gives the player's and the party's places the party's art", function()
        local world = World.new()
        local client = world:addClient("Lead Player", { level = 20, class = "WARRIOR",
            atlases = { ["classicon-warrior"] = true, ["classicon-mage"] = true } })
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("CheckButton", "Tank")
        client:click("Button", LEAD)
        client:click("CheckButton", "Choose the classes in my party")
        local cards = client.ns.WindowParts.composeCards
        assert.are.equal("classicon-warrior", cards[1].art.atlas)
        assert.is_true(cards[1].art.shown)
        assert.is_false(cards[3].art.shown)
        client.party, client.isLeader = { "Mage Friend" }, true
        client.partyClasses["Mage Friend"] = "MAGE"
        client:fire("GROUP_ROSTER_UPDATE")
        assert.are.equal("classicon-mage", cards[3].art.atlas)
        assert.is_true(cards[3].art.shown)
        assert.is_false(cards[4].art.shown)
        assert.are.equal("Mage Friend", cards[3].lines[1].text)
        assert.is_true(cards[3].nameIcon.shown)
        assert.are.equal("classicon-mage", cards[3].nameIcon.atlas)
        assert.is_nil(cards[3].lines[2].text:find("Mage", 1, true))
        assert.is_true(cards[1].nameIcon.shown)
        assert.are.equal("classicon-warrior", cards[1].nameIcon.atlas)
    end)

    it("keeps the chosen classes while switched off, and uses none then", function()
        local world = World.new()
        local client = leader(world)
        client:click("Button", LEAD)
        client:click("CheckButton", "Choose the classes in my party")
        local cards = client.ns.WindowParts.composeCards
        pick(client, cards[3], { "Mage" })
        client:click("CheckButton", "Choose the classes in my party")
        assert.is_false(cards[3].shown)
        assert.are.same({ 0, 0, 64, 0, 0 }, client.ns.charDb.compose.masks)
        client:click("Button", "Find players")
        assert.is_nil(client.ns.engine.myEntry.compose)
        client:slash("/dq leave")
        client:click("CheckButton", "Choose the classes in my party")
        assert.is_true(cards[3].shown)
        assert.are.equal("Mage", cards[3].lines[1].text)
    end)

    it("shows the wished classes in the open places of the queue card", function()
        local world = World.new()
        local client = world:addClient("Lead Player", { level = 20, class = "WARRIOR", atlases = {
            ["classicon-warrior"] = true, ["classicon-priest"] = true, ["classicon-shaman"] = true,
            ["classicon-mage"] = true,
        } })
        world:advance(CONNECT)
        client:slash("/dq")
        client:click("CheckButton", "Tank")
        client.ns.charDb.wantsLead = true
        client.ns.charDb.compose = { masks = { 0, 48, 64, 0, 0 } }
        client.ns.charDb.composeOn = true
        client:slash("/dq join tank dm")
        client.ns.Window.refresh()
        local slots = client.ns.WindowParts.slots
        local function icons(slot)
            local list = {}
            for _, icon in ipairs(slot.classIcons or {}) do
                if icon.shown then
                    list[#list + 1] = icon.atlas
                end
            end
            return list
        end
        assert.are.equal("Lead Player", slots[1].name.text)
        assert.are.same({ "classicon-priest", "classicon-shaman" }, icons(slots[2]))
        assert.are.same({ "classicon-mage" }, icons(slots[3]))
        assert.are.same({}, icons(slots[4]))
        assert.are.equal("open", slots[2].name.text)
    end)

    it("lets the filler invite only players of a wished class for that place", function()
        local world = World.new()
        world:list("Listed Heal", "H", 799, 20, 300)
        for _, listed in ipairs({ { "Rogue A", "ROGUE", 400 }, { "Rogue B", "ROGUE", 300 }, { "Mage C", "MAGE", 100 },
            { "Rogue D", "ROGUE", 200 } }) do
            world:list(listed[1], "D", 799, 20, listed[3])
            world.listings[#world.listings].class = listed[2]
        end
        local client = leader(world)
        client.ns.charDb.wantsLead = true
        client.ns.charDb.compose = { masks = { 0, 0, 64, 64, 0 } }
        client.ns.charDb.composeOn = true
        client:slash("/dq join tank dm")
        client:slash("/dq fill")
        world:advance(3)
        table.sort(client.invites)
        assert.are.same({ "Listed Heal", "Mage C", "Rogue A" }, client.invites)
    end)

    it("sends the place of an invite still out without a wish, so the queue can count it", function()
        local world = World.new()
        world:list("Mage C", "D", 799, 20, 100)
        world.listings[#world.listings].class = "MAGE"
        local client = leader(world)
        client.ns.charDb.wantsLead = true
        client.ns.charDb.compose = { masks = { 0, 0, 64, 64, 64 } }
        client.ns.charDb.composeOn = true
        client:slash("/dq join tank dm")
        client:slash("/dq fill")
        world:advance(3)
        assert.are.same({ "Mage C" }, client.invites)
        world:advance(5)
        local entry = client.ns.engine.myEntry
        assert.are.equal("D", entry.reserved)
        assert.are.equal("0:0.0.0.64.64", entry.compose)
        local free = {}
        for _, place in ipairs(client.ns.PartyCompose.freePlaces()) do
            free[#free + 1] = place.role .. place.mask
        end
        assert.are.same({ "H0", "D64", "D64" }, free)
    end)

    it("still queues, without the wishes, when they do not fit in the queue message", function()
        local world = World.new()
        local client = leader(world)
        client.ns.charDb.wantsLead = true
        client.ns.charDb.compose = { masks = { 0, 0, 64, 0, 0 } }
        client.ns.charDb.composeOn = true
        local Protocol = client.ns.Protocol
        local encode = Protocol.encode
        Protocol.encode = function(msg, space)
            if msg.kind == "queue" and msg.compose then
                return nil, "message too long"
            end
            return encode(msg, space)
        end
        client:slash("/dq join tank dm")
        Protocol.encode = encode
        local entry = client.ns.engine.myEntry
        assert.is_not_nil(entry)
        assert.is_nil(entry.compose)
        assert.is_true(client:logged("you queue without them"))
    end)

    it("lets the filler invite only a wished class next to a party member, as the queue entry says", function()
        local world = World.new()
        for _, listed in ipairs({ { "Warrior Dps", "WARRIOR", 400 }, { "Mage Dps", "MAGE", 300 },
            { "Rogue Dps", "ROGUE", 200 } }) do
            world:list(listed[1], "D", 799, 20, listed[3])
            world.listings[#world.listings].class = listed[2]
        end
        world:list("Listed Heal", "H", 799, 20, 100)
        local client = leader(world)
        client.party, client.isLeader = { "Mage Friend" }, true
        client.partyClasses["Mage Friend"] = "MAGE"
        client.ns.charDb.compose = { masks = { 0, 0, 0, 64, 8 } }
        client.ns.charDb.composeOn = true
        client:fire("GROUP_ROSTER_UPDATE")
        client:click("Button", "None")
        client:click("CheckButton", "The Deadmines")
        client:click("Button", "Find group")
        assert.are.equal("0:0.0.0.64.8", client.ns.engine.myEntry.compose)
        client:slash("/dq fill")
        world:advance(3)
        table.sort(client.invites)
        assert.are.same({ "Listed Heal", "Mage Dps", "Rogue Dps" }, client.invites)
    end)

    it("takes the wish off the place of a player who joins in the role agreed, whatever WoW shows yet", function()
        local world = World.new()
        local client = leader(world)
        client.ns.charDb.wantsLead = true
        client.ns.charDb.compose = { masks = { 0, 16, 0, 0, 0 } }
        client.ns.charDb.composeOn = true
        client:slash("/dq join tank dm")
        assert.are.equal("0:0.16.0.0.0", client.ns.engine.myEntry.compose)
        client.ns.RoleSync.expect("Druid Heal", "H")
        client.partyClasses["Druid Heal"] = "DRUID"
        client.roles["Druid Heal"] = "TANK"
        client:joins("Druid Heal")
        world:advance(1)
        assert.is_nil(client.ns.engine.myEntry.compose)
    end)

    it("keeps the party in step when the wishes no longer fit in the queue message", function()
        local world = World.new()
        local client = leader(world)
        client.ns.charDb.wantsLead = true
        client.ns.charDb.compose = { masks = { 0, 0, 0, 64, 0 } }
        client.ns.charDb.composeOn = true
        client:slash("/dq join tank dm")
        local Protocol = client.ns.Protocol
        local encode = Protocol.encode
        Protocol.encode = function(msg, space)
            if msg.kind == "queue" and msg.compose and #msg.members > 1 then
                return nil, "message too long"
            end
            return encode(msg, space)
        end
        client.ns.RoleSync.expect("Friend One", "D")
        client:joins("Friend One")
        world:advance(1)
        Protocol.encode = encode
        local entry = client.ns.engine.myEntry
        assert.are.equal(2, #entry.members)
        assert.is_nil(entry.compose)
        assert.is_true(client:logged("you queue without them"))
    end)

    it("keeps the place a player was invited for once they join, so the other wishes stay", function()
        local world = World.new()
        world:list("Listed Heal", "H", 799, 20, 400)
        for _, listed in ipairs({ { "Rogue A", 300 }, { "Rogue B", 200 } }) do
            world:list(listed[1], "D", 799, 20, listed[2])
            world.listings[#world.listings].class = "ROGUE"
        end
        local client = leader(world)
        client.ns.charDb.wantsLead = true
        client.ns.charDb.compose = { masks = { 0, 0, 64, 0, 0 } }
        client.ns.charDb.composeOn = true
        client:slash("/dq join tank dm")
        client:slash("/dq fill")
        world:advance(3)
        client:joins("Rogue A")
        world:advance(2)
        assert.are.equal("0:0.0.64.0.0", client.ns.engine.myEntry.compose)
        local free = {}
        for _, place in ipairs(client.ns.PartyCompose.freePlaces()) do
            free[#free + 1] = place.role .. place.mask
        end
        assert.are.same({ "D64" }, free)
        client:fire("PLAYER_LOGIN")
        assert.are.equal(4, client.ns.charDb.composeSeats["Rogue A"])
    end)

    it("does not send wishes again and again that did not fit in the queue message", function()
        local world = World.new()
        local client = leader(world)
        client.ns.charDb.wantsLead = true
        client.ns.charDb.compose = { masks = { 0, 0, 64, 0, 0 } }
        client.ns.charDb.composeOn = true
        local Protocol = client.ns.Protocol
        local encode = Protocol.encode
        Protocol.encode = function(msg, space)
            if msg.kind == "queue" and msg.compose then
                return nil, "message too long"
            end
            return encode(msg, space)
        end
        client:slash("/dq join tank dm")
        local before = 0
        for _, text in ipairs(client.sent) do
            before = before + (text:find("^v2|Q|") and 1 or 0)
        end
        world:advance(60)
        Protocol.encode = encode
        local after = 0
        for _, text in ipairs(client.sent) do
            after = after + (text:find("^v2|Q|") and 1 or 0)
        end
        assert.is_true(after - before <= 1, (after - before) .. " queue messages sent")
    end)

    it("brings the wished class from the Forever Groups queue", function()
        local world = World.new()
        local lead = world:addClient("Lead Player", { level = 20, class = "WARRIOR" })
        local others = {}
        for i, player in ipairs({ { "Heal Er", "PRIEST", "healer" }, { "Rogue One", "ROGUE", "dps" },
            { "Rogue Two", "ROGUE", "dps" }, { "Rogue Three", "ROGUE", "dps" }, { "Mage Four", "MAGE", "dps" } }) do
            others[i] = { client = world:addClient(player[1], { level = 20, class = player[2] }), role = player[3] }
        end
        world:advance(CONNECT)
        lead.ns.charDb.wantsLead = true
        lead.ns.engine:setLead(true)
        lead.ns.charDb.compose = { masks = { 0, 0, 64, 0, 0 } }
        lead.ns.charDb.composeOn = true
        lead:slash("/dq join tank dm")
        for _, other in ipairs(others) do
            other.client:slash("/dq join " .. other.role .. " dm")
        end
        world:advance(15)
        local proposal = lead.ns.engine.proposals[lead.ns.engine.myProposalKey]
        assert.is_not_nil(proposal)
        local names = {}
        for _, member in ipairs(proposal.members) do
            names[#names + 1] = member.name
        end
        table.sort(names)
        assert.are.same({ "Heal Er", "Lead Player", "Mage Four", "Rogue One", "Rogue Three" }, names)
        assert.are.equal("Lead Player", proposal.leader)
    end)

    it("fades players in Who is looking whose class has no free place", function()
        local world = World.new()
        world:list("Rogue A", "D", 799, 20, 300)
        world.listings[#world.listings].class = "ROGUE"
        world:list("Mage B", "D", 799, 20, 200)
        world.listings[#world.listings].class = "MAGE"
        local client = leader(world)
        client:click("Button", LEAD)
        client.ns.charDb.compose = { masks = { 0, 0, 64, 64, 64 } }
        client.ns.charDb.composeOn = true
        client:press("W")
        world:advance(1)
        assert.is_true(client.ns.QueueWindow.isShown())
        client.ns.QueueWindow.refresh()
        local rogue, mage = client:findText("^Rogue A$"), client:findText("^Mage B$")
        assert.is_not_nil(rogue)
        assert.are.equal(0.4, rogue.parent.alpha)
        assert.are.equal(1, mage.parent.alpha)
    end)

    it("drops everything of leading when the player goes back to joining", function()
        local world = World.new()
        world:listGroup("Group Lead", 799, { T = 1, H = 0, D = 1 })
        local client = leader(world)
        client:click("Button", LEAD)
        client:click("CheckButton", "Choose the classes in my party")
        client.ns.charDb.compose = { masks = { 0, 0, 64, 0, 0 } }
        client:click("CheckButton", "Limit levels")
        assert.is_not_nil(client:find("Button", "Find players"))
        client:click("Button", "Join a group")
        assert.is_nil(client.ns.charDb.wantsLead)
        assert.is_nil(client:find("CheckButton", "Choose the classes in my party"))
        assert.is_nil(client:find("CheckButton", "Limit levels"))
        client:click("Button", "Find group")
        local entry = client.ns.engine.myEntry
        assert.is_nil(entry.lead)
        assert.is_nil(entry.compose)
        assert.is_nil(entry.levels)
        world:advance(2)
        local asked = false
        for _, w in ipairs(client.whispers) do
            asked = asked or w.target == "Group Lead"
        end
        assert.is_true(asked)
        assert.is_true(client.ns.charDb.composeOn)
        assert.is_true(client.ns.charDb.levelsOn)
    end)

    it("fills the content box exactly, the same margin inside the frame's border on both sides", function()
        local world = World.new()
        local client = leader(world)
        local W = client.ns.WindowParts
        assert.are.equal(W.PAD - W.BORDER_LEFT, W.WIDTH - W.BORDER_RIGHT - W.RIGHT)
        for _, count in ipairs({ 3, 5 }) do
            local columns = W.columns(count, W.SPACE.s)
            assert.are.equal(W.PAD, columns[1].x)
            assert.are.equal(W.RIGHT, columns[count].x + columns[count].width)
        end
        client:click("Button", LEAD)
        client:click("CheckButton", "Choose the classes in my party")
        assert.are.equal(W.columns(5, W.SPACE.s)[5].x, W.composeCards[5].point[4])
        local tank = client:find("CheckButton", "Tank")
        assert.are.equal(W.PAD, tank.point[4])
    end)
end)

describe("a queue message too long for the language", function()
    local function tooLongWith(client, test)
        local Protocol = client.ns.Protocol
        local encode = Protocol.encode
        Protocol.encode = function(msg, space)
            if msg.kind == "queue" and msg.language and test(msg) then
                return nil, "message too long"
            end
            return encode(msg, space)
        end
        return function()
            Protocol.encode = encode
        end
    end

    local function queueMessages(client)
        local count = 0
        for _, text in ipairs(client.sent) do
            count = count + (text:find("^v2|Q|") and 1 or 0)
        end
        return count
    end

    it("still queues, without the language, and does not send it again and again", function()
        local world = World.new()
        local client = leader(world)
        local restore = tooLongWith(client, function()
            return true
        end)
        client:slash("/dq join tank dm")
        local entry = client.ns.engine.myEntry
        assert.is_not_nil(entry)
        assert.is_nil(entry.language)
        assert.is_true(client:logged("grouped with players of any language"))
        local before = queueMessages(client)
        world:advance(60)
        restore()
        assert.is_true(queueMessages(client) - before <= 1)
    end)

    it("keeps the party in step without the language when it no longer fits", function()
        local world = World.new()
        local client = leader(world)
        client:slash("/dq join tank dm")
        assert.is_not_nil(client.ns.engine.myEntry.language)
        local restore = tooLongWith(client, function(msg)
            return #msg.members > 1
        end)
        client.ns.RoleSync.expect("Friend One", "D")
        client:joins("Friend One")
        world:advance(1)
        local entry = client.ns.engine.myEntry
        assert.are.equal(2, #entry.members)
        assert.is_nil(entry.language)
        local before = queueMessages(client)
        world:advance(60)
        restore()
        assert.is_true(queueMessages(client) - before <= 1)
    end)

    it("keeps its own language when the update does not fit even without it", function()
        local world = World.new()
        local client = leader(world)
        client:slash("/dq join tank dm")
        local language = client.ns.engine.myEntry.language
        assert.is_not_nil(language)
        local Protocol = client.ns.Protocol
        local encode = Protocol.encode
        Protocol.encode = function(msg, space)
            if msg.kind == "queue" and #msg.members > 1 then
                return nil, "message too long"
            end
            return encode(msg, space)
        end
        client.ns.RoleSync.expect("Friend One", "D")
        client:joins("Friend One")
        world:advance(1)
        Protocol.encode = encode
        assert.are.equal(language, client.ns.engine.myEntry.language)
        assert.are.equal(language, client.ns.engine.language)
    end)
end)
