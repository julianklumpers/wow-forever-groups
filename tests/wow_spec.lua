local World = require("tests.helpers.wowmock")

local CONNECT = 8
local MATCH = 20

local PLAYERS = {
    { "Tanky Mctank", "tank" }, { "Heally Mcheal", "healer" }, { "Dps One", "dps" }, { "Dps Two", "dps" },
    { "Dps Three", "dps" },
}

local function fullWorld()
    local world = World.new()
    local clients = {}
    for i, p in ipairs(PLAYERS) do
        clients[i] = world:addClient(p[1])
    end
    world:advance(CONNECT)
    for i, p in ipairs(PLAYERS) do
        clients[i]:slash("/dq join " .. p[2] .. " auto")
    end
    world:advance(MATCH)
    return world, clients
end

describe("WoW layer", function()
    it("joins the hidden channel and learns its own name from the echo", function()
        local world = World.new()
        local client = world:addClient("Roos Bieff")
        world:advance(CONNECT)
        assert.are.equal("Roos Bieff", client.ns.selfName)
        assert.is_not_nil(client.ns.engine)
        assert.are.equal(6, client.channels.ForeverGroupsNet)
    end)

    it("leaves the channel of the old DungeonQueue name", function()
        local world = World.new()
        local client = world:addClient("Roos Bieff", { beforeLogin = function(c)
            c.channels.DungeonQueueNet = 5
        end })
        world:advance(CONNECT)
        assert.is_nil(client.channels.DungeonQueueNet)
        assert.is_not_nil(client.channels.ForeverGroupsNet)
    end)

    it("forms a group of five end to end: popups, accept, invites by the tank", function()
        local world, clients = fullWorld()
        for _, client in ipairs(clients) do
            assert.is_true(client:proposalShown(), client.name)
            local tankRow = client:findText("^Tanky Mctank").parent
            assert.is_not_nil(client:find("Texture", "Leader", tankRow), client.name)
        end
        for _, client in ipairs(clients) do
            client:acceptPopup()
        end
        world:advance(1)

        local tank = clients[1]
        table.sort(tank.invites)
        assert.are.same({ "Dps One", "Dps Three", "Dps Two", "Heally Mcheal" }, tank.invites)
        assert.are.equal(4, #tank.whispers)
        for i = 2, 5 do
            tank:joins(clients[i].name)
        end
        assert.are.equal("TANK", tank.roles["Tanky Mctank"])
        assert.are.equal("HEALER", tank.roles["Heally Mcheal"])
        assert.are.equal("WHISPER", tank.whispers[1].chatType)
        for i = 2, 5 do
            assert.are.same({}, clients[i].invites)
            assert.are.equal("Tanky Mctank", clients[i].acceptedFrom, clients[i].name)
            assert.is_true(clients[i].hiddenPopups.PARTY_INVITE)
            assert.is_true(clients[i]:said("Joined Tanky Mctank's group"), clients[i].name)
            assert.is_false(clients[i].ns.engine:snapshot().queued)
        end
        world:advance(4)
        assert.are.equal("HEALER", clients[2].roles["Heally Mcheal"])
        assert.are.equal("DAMAGER", clients[3].roles["Dps One"])
    end)

    it("regroups the others at once when one player declines, the rest from the Group Finder", function()
        local world, clients = fullWorld()
        clients[3]:declinePopup()
        world:advance(1)
        assert.is_false(clients[3].ns.engine:snapshot().queued)
        assert.is_true(clients[1].ns.engine:snapshot().queued)
        assert.is_true(clients[1]:said("You keep your place in the queue"))
        assert.is_true(clients[3]:said("You declined and left the queue"))
        world:advance(6)
        assert.is_true(clients[1]:proposalShown())
        assert.are.equal("D", clients[1]:openPlaces())
        assert.is_not_nil(clients[1]:findText("^from the Group Finder$"))
    end)

    it("says so when the player let the proposal run out", function()
        local world, clients = fullWorld()
        for i = 1, 4 do
            clients[i]:acceptPopup()
        end
        world:advance(60)
        assert.is_false(clients[5].ns.engine:snapshot().queued)
        assert.is_true(clients[5]:said("You did not accept in time and left the queue"))
        assert.is_false(clients[5]:said("You declined"))
    end)

    it("takes over the settings of the old DungeonQueue addon and turns it off", function()
        local world = World.new()
        local client = world:addClient("Roos Bieff", { oldAddon = {
            db = { minimapAngle = 123, debug = true }, charDb = { lastRoles = "D" } } })
        world:advance(CONNECT)
        assert.are.equal(123, client.ns.db.minimapAngle)
        assert.are.equal("D", client.ns.charDb.lastRoles)
        assert.are.same({ "DungeonQueue" }, client.disabledAddOns)
        assert.is_true(client:said("DungeonQueue is now called Forever Groups"))
    end)

    it("refuses to queue while in a group or with an unknown dungeon", function()
        local world = World.new()
        local client = world:addClient("Solo Player")
        world:advance(CONNECT)
        client:slash("/dq join dps Nowhere")
        assert.is_true(client:said("Unknown dungeon"))
        client.inGroup = true
        client:slash("/dq join dps auto")
        assert.is_true(client:said("To queue as a party"))
        assert.is_false(client.ns.engine:snapshot().queued)
    end)

    it("queues for named dungeons", function()
        local world = World.new()
        local client = world:addClient("Solo Player")
        world:advance(CONNECT)
        client:slash("/dq join heal Deadmines, wc, 6")
        assert.are.same({ "5", "4", "6" }, client.ns.engine.myEntry.dungeons)
    end)

    it("lets one player test the full flow with /dq slots", function()
        local world = World.new()
        local client = world:addClient("Solo Player")
        world:advance(CONNECT)
        client:slash("/dq slots 0 0 1")
        client:slash("/dq join dps auto")
        world:advance(MATCH)
        client:acceptPopup()
        world:advance(1)
        assert.is_true(client:said("You are the leader; inviting 0 players"))
        client:slash("/dq slots reset")
        assert.are.equal(3, client.ns.engine.config.SLOTS.D)
    end)

    it("keeps the queue position across a /reload", function()
        local world = World.new()
        local client = world:addClient("Solo Player")
        world:advance(CONNECT)
        client:slash("/dq join dps auto")
        local joinedAt = client.ns.engine.myEntry.joinedAt
        world:advance(30)
        local saved = client:logout()

        local reloaded = world:addClient("Solo Player", { saved = saved })
        world:advance(CONNECT)
        assert.is_true(reloaded:said("your place was kept"))
        assert.are.equal(joinedAt, reloaded.ns.engine.myEntry.joinedAt)
    end)

    it("retries after the server throttles a message", function()
        local world = World.new()
        local client = world:addClient("Solo Player")
        world:advance(CONNECT)
        client.sendResults = { 3, 3 }
        client:slash("/dq join dps auto")
        world:advance(1)
        assert.are.equal(1, client.ns.Comm.outbox:size())
        world:advance(10)
        assert.are.same({}, client.ns.Comm.outbox.queue)
        local queued = false
        for _, text in ipairs(client.sent) do
            queued = queued or text:find("^v2|Q|") ~= nil
        end
        assert.is_true(queued)
    end)

    it("tells the leader to click when WoW blocks the automatic invite", function()
        local world, clients = fullWorld()
        for _, client in ipairs(clients) do
            client:acceptPopup()
        end
        world:advance(5)
        local tank = clients[1]
        tank:fire("ADDON_ACTION_BLOCKED", "ForeverGroups", "C_PartyInfo.InviteUnit()")
        assert.is_true(tank:said("Type /fg invite"))
        tank.invites = {}
        tank:slash("/dq invite")
        assert.are.equal(4, #tank.invites)
    end)

    it("explains when no dungeon fits a low level and still lets you name one", function()
        local world = World.new()
        local client = world:addClient("Low Level", { level = 6 })
        world:advance(CONNECT)
        client:slash("/dq dungeons")
        assert.is_true(client:said("No dungeons fit level 6"))
        client:slash("/dq dungeons all")
        assert.is_true(client:said("Stratholme: Undead"))
        client:slash("/dq join dps auto")
        assert.is_true(client:said("No dungeons for your level"))
        client:slash("/dq join dps rfc")
        assert.is_true(client.ns.engine:snapshot().queued)
    end)

    it("shows status and help without errors", function()
        local world, clients = fullWorld()
        clients[1]:slash("/dq status")
        clients[1]:slash("/dq dungeons")
        clients[1]:slash("/dq debug")
        clients[1]:slash("/dq log 5")
        clients[1]:slash("/dq")
        world:advance(1)
        assert.is_true(clients[1]:said("Matchmaker: Dps One"))
        assert.is_true(clients[1]:said("Ragefire Chasm"))
    end)
end)

describe("WoW UI", function()
    local function connected(name, opts)
        local world = World.new()
        local client = world:addClient(name, opts)
        world:advance(CONNECT)
        return world, client
    end

    it("opens with /dq and queues through the window", function()
        local _, client = connected("Solo Player")
        client:slash("/dq")
        assert.is_true(client:frame("ForeverGroupsFrame").shown)
        assert.is_not_nil(client:find("CheckButton", "Wailing Caverns"))
        assert.is_true(client:find("CheckButton", "Wailing Caverns").checked)

        assert.is_false(client:find("Button", "Find group").enabled)
        assert.is_not_nil(client:findText("^Choose a role and at least one dungeon%.$"))
        assert.is_not_nil(client:findText("·  5 selected$"))

        client:click("CheckButton", "DPS")
        client:click("CheckButton", "Wailing Caverns")
        client:click("Button", "Find group")
        local entry = client.ns.engine.myEntry
        assert.is_not_nil(entry)
        assert.are.equal("D", entry.members[1].roles)
        assert.are.same({ "1", "2", "3", "5" }, entry.dungeons)
        assert.is_nil(client:find("CheckButton", "Tank"))
        assert.is_not_nil(client:findText("^Searching 4 dungeons  ·  Relaxed or Learning$"))
        assert.is_not_nil(client:findText("^" .. client.ns.Dungeons.get("5").name .. "$"))
        local open = 0
        for _, widget in ipairs(client.widgets) do
            if widget.kind == "FontString" and widget.text == "open" and widget.parent.shown and widget.shown then
                open = open + 1
            end
        end
        assert.are.equal(4, open)
        assert.is_not_nil(client:findText("^Solo Player$"))

        client:click("Button", "Stop")
        assert.is_false(client.ns.engine:snapshot().queued)
        assert.is_not_nil(client:find("Button", "Find group"))
    end)

    it("queues with several roles and tells the player which one they got", function()
        local world = World.new()
        local flex = world:addClient("Flex Player")
        local others = {}
        for i, p in ipairs({ { "Heally Mcheal", "healer" }, { "Dps One", "dps" }, { "Dps Two", "dps" },
            { "Dps Three", "dps" } }) do
            others[i] = world:addClient(p[1])
            others[i].role = p[2]
        end
        world:advance(CONNECT)
        flex:slash("/dq")
        flex:click("CheckButton", "Tank")
        flex:click("CheckButton", "DPS")
        flex:click("Button", "Find group")
        assert.are.equal("TD", flex.ns.engine.myEntry.members[1].roles)
        for _, client in ipairs(others) do
            client:slash("/dq join " .. client.role .. " auto")
        end
        world:advance(MATCH)
        assert.is_not_nil(flex:findText("you play Tank$"))
        assert.is_not_nil(others[2]:findText("you play DPS$"))
    end)

    it("accepts several roles on the command line", function()
        local _, client = connected("Solo Player")
        client:slash("/dq join tank,dps auto")
        assert.are.equal("TD", client.ns.engine.myEntry.members[1].roles)
        client:slash("/dq leave")
        client:slash("/dq join hd auto")
        assert.are.equal("HD", client.ns.engine.myEntry.members[1].roles)
        client:slash("/dq leave")
        client:slash("/dq join wizard auto")
        assert.is_true(client:said("Usage: /fg join"))
    end)

    it("greys out roles the class cannot play", function()
        local _, mage = connected("Mage Player", { class = "MAGE" })
        mage:slash("/dq")
        assert.is_false(mage:find("CheckButton", "Tank").enabled)
        assert.is_false(mage:find("CheckButton", "Healer").enabled)
        assert.is_true(mage:find("CheckButton", "DPS").enabled)
        assert.are.equal("Your class cannot play this role.", mage:find("CheckButton", "Tank").reason)

        local _, shaman = connected("Shaman Player", { class = "SHAMAN" })
        shaman:slash("/dq")
        assert.is_true(shaman:find("CheckButton", "Tank").enabled)
    end)

    it("refuses a role the class cannot play on the command line", function()
        local _, priest = connected("Priest Player", { class = "PRIEST" })
        priest:slash("/dq join tank auto")
        assert.is_true(priest:said("Your class can only play: Healer/DPS"))
        assert.is_false(priest.ns.engine:snapshot().queued)
        priest:slash("/dq join heal,dps auto")
        assert.are.equal("HD", priest.ns.engine.myEntry.members[1].roles)
    end)

    it("drops remembered roles the class cannot play", function()
        local _, mage = connected("Mage Player", { class = "MAGE" })
        mage.env.ForeverGroupsCharDB.lastRoles = "TD"
        mage:slash("/dq")
        assert.are.equal("D", mage.env.ForeverGroupsCharDB.lastRoles)
        assert.is_true(mage:find("CheckButton", "DPS").checked)
    end)

    it("limits party member roles by their class", function()
        local _, leader = connected("Tanky Mctank", { class = "WARRIOR" })
        leader.party, leader.isLeader = { "Sneaky Rogue" }, true
        leader.partyClasses["Sneaky Rogue"] = "ROGUE"
        leader:slash("/dq")
        assert.is_not_nil(leader:findText("^DPS  %(any role of the class%)$"))
        assert.is_false(leader:find("CheckButton", "Healer").enabled)
    end)

    it("remembers role and dungeons across sessions", function()
        local world, client = connected("Solo Player")
        client:slash("/dq")
        client:click("CheckButton", "Healer")
        client:click("CheckButton", "Ragefire Chasm")
        local saved = client:logout()
        local again = world:addClient("Solo Player", { saved = saved })
        world:advance(CONNECT)
        again:slash("/dq")
        assert.is_true(again:find("CheckButton", "Healer").checked)
        assert.is_false(again:find("CheckButton", "Ragefire Chasm").checked)
    end)

    it("sizes the window to its content", function()
        local _, client = connected("Solo Player", { level = 20 })
        client:slash("/dq")
        local window = client:frame("ForeverGroupsFrame")
        local solo = window.height
        client:click("Button", "Other dungeons")
        assert.is_true(window.height > solo)
        client:click("Button", "Other dungeons")
        assert.are.equal(solo, window.height)
        client.party, client.isLeader = { "Friend Person" }, true
        client:fire("GROUP_ROSTER_UPDATE")
        assert.is_true(window.height > solo)
        client:click("CheckButton", "DPS")
        client.roles["Friend Person"] = "TANK"
        client:click("Button", "Find group")
        assert.is_true(window.height < solo)
    end)

    it("makes the whole dungeon row the click area", function()
        local _, client = connected("Solo Player", { level = 20 })
        client:slash("/dq")
        local cell = client:find("CheckButton", "Wailing Caverns")
        assert.are.equal(-(580 - 2 * 26 + 3 - 22), cell.hitInsets[2])
    end)

    it("shows the other dungeons below their own heading on request", function()
        local _, client = connected("Low Level", { level = 6 })
        client:slash("/dq")
        assert.is_nil(client:find("CheckButton", "Ragefire Chasm"))
        local toggle = client:find("Button", "Other dungeons")
        assert.is_false(toggle.open)
        local closedAt = toggle.point[5]
        client:click("Button", "Other dungeons")
        assert.is_true(toggle.open)
        assert.are.equal(closedAt, toggle.point[5])
        assert.is_not_nil(client:find("CheckButton", "Stratholme: Undead"))
        assert.is_not_nil(client:findText("^%(%d+%)$"))
    end)

    it("queues a party with each member's role taken from WoW, flexible when unknown", function()
        local world = World.new()
        local leader = world:addClient("Tanky Mctank")
        leader.party, leader.isLeader = { "Friend Person" }, true
        local others = {
            world:addClient("Heally Mcheal"), world:addClient("Dps One"), world:addClient("Dps Two"),
        }
        world:advance(CONNECT)

        leader:slash("/dq")
        assert.is_not_nil(leader:findText("^Tank/Healer/DPS  %(any role of the class%)$"))
        leader:click("CheckButton", "Tank")
        leader:click("Button", "Find group")
        assert.are.equal("THD", leader.ns.engine.myEntry.members[2].roles)

        others[1]:slash("/dq join healer auto")
        others[2]:slash("/dq join dps auto")
        others[3]:slash("/dq join dps auto")
        world:advance(MATCH)
        assert.is_true(leader:proposalShown())
        assert.is_not_nil(leader:find("FontString", "Friend Person"))
        leader:acceptPopup()
        for _, client in ipairs(others) do
            client:acceptPopup()
        end
        world:advance(5)
        table.sort(leader.invites)
        assert.are.same({ "Dps One", "Dps Two", "Heally Mcheal" }, leader.invites)
        assert.are.equal("DAMAGER", leader.roles["Friend Person"])
    end)

    it("follows a party member who switches roles while queued", function()
        local world = World.new()
        local leader = world:addClient("Tanky Mctank")
        leader.party, leader.isLeader = { "Friend Person" }, true
        leader.roles["Friend Person"] = "DAMAGER"
        world:advance(CONNECT)
        leader:slash("/dq")
        leader:click("CheckButton", "Healer")
        leader:click("Button", "Find group")
        assert.are.equal("D", leader.ns.engine.myEntry.members[2].roles)
        leader.roles["Friend Person"] = "TANK"
        leader:fire("ROLE_CHANGED_INFORM")
        world:advance(1)
        assert.are.equal("T", leader.ns.engine.myEntry.members[2].roles)
    end)

    it("refuses roles that do not fit one group", function()
        local _, leader = connected("Tanky Mctank")
        leader.party, leader.isLeader = { "Other Tank" }, true
        leader:slash("/dq")
        leader:click("CheckButton", "Tank")
        leader.roles["Other Tank"] = "TANK"
        leader:click("Button", "Find group")
        assert.is_not_nil(leader:findText("cannot make one group"))
    end)

    it("keeps the place in the queue when a party member leaves, but leaves when a stranger joins", function()
        local world, leader = connected("Tanky Mctank")
        leader.party, leader.isLeader = { "Friend Person" }, true
        leader:slash("/dq")
        leader:click("CheckButton", "Tank")
        leader.roles["Friend Person"] = "DAMAGER"
        leader:click("Button", "Find group")
        assert.is_true(leader.ns.engine:snapshot().queued)
        local joinedAt = leader.ns.engine.myEntry.joinedAt
        leader.party = {}
        leader:fire("GROUP_ROSTER_UPDATE")
        world:advance(1)
        assert.is_true(leader.ns.engine:snapshot().queued)
        assert.are.equal(1, #leader.ns.engine.myEntry.members)
        assert.are.equal(joinedAt, leader.ns.engine.myEntry.joinedAt)
        assert.is_true(leader:said("Your group changed; you stay in the queue as a group of 1"))
        leader.party = { "Random Stranger" }
        leader:fire("GROUP_ROSTER_UPDATE")
        assert.is_false(leader.ns.engine:snapshot().queued)
        assert.is_true(leader:said("Your group changed"))
    end)

    it("does not let a party member queue", function()
        local _, member = connected("Party Member")
        member.party = { "The Leader" }
        member:slash("/dq")
        assert.is_not_nil(member:findText("^Your party leader queues for the group%.$"))
        assert.is_nil(member:find("Button", "Find group"))
        assert.is_nil(member:find("CheckButton", "Tank"))
    end)

    it("leaves the invite to the player when joining by itself is off", function()
        local world = World.new()
        local clients = {}
        for i, p in ipairs(PLAYERS) do
            clients[i] = world:addClient(p[1])
            clients[i].ns.db.noAutoAccept = i == 2 or nil
        end
        world:advance(CONNECT)
        for i, p in ipairs(PLAYERS) do
            clients[i]:slash("/dq join " .. p[2] .. " auto")
        end
        world:advance(MATCH)
        for _, client in ipairs(clients) do
            client:acceptPopup()
        end
        world:advance(5)
        assert.is_nil(clients[2].acceptedFrom)
        assert.is_true(clients[2]:said("This is your Forever Groups invite from Tanky Mctank"))
        assert.are.equal("Tanky Mctank", clients[3].acceptedFrom)
    end)

    it("marks WoW's invite popup accepted before hiding it, so hiding does not decline", function()
        local world, clients = fullWorld()
        for _, client in ipairs(clients) do
            client:acceptPopup()
        end
        world:advance(1)
        assert.are.equal(1, clients[2].env.StaticPopup1.inviteAccepted)
    end)

    it("accepts the leader's invite that arrives before the last answer", function()
        local world, clients = fullWorld()
        for i = 2, 5 do
            clients[i]:acceptPopup()
        end
        clients[2]:invitedBy("Tanky Mctank")
        assert.are.equal("Tanky Mctank", clients[2].acceptedFrom)
        world:advance(1)
        assert.is_false(clients[2]:said("You are still in a group"))
    end)

    it("does not accept the leader's invite before the player accepted", function()
        local _, clients = fullWorld()
        clients[2]:invitedBy("Tanky Mctank")
        assert.is_nil(clients[2].acceptedFrom)
    end)

    it("stops expecting a leader whose invite never came", function()
        local world, clients = fullWorld()
        local inviteUnit = clients[1].env.C_PartyInfo.InviteUnit
        clients[1].env.C_PartyInfo.InviteUnit = function() end
        for _, client in ipairs(clients) do
            client:acceptPopup()
        end
        world:advance(1)
        assert.is_nil(clients[2].acceptedFrom)
        world:advance(180)
        clients[1].env.C_PartyInfo.InviteUnit = inviteUnit
        clients[2]:invitedBy("Tanky Mctank")
        assert.is_nil(clients[2].acceptedFrom)
    end)

    it("never accepts an invite from someone else", function()
        local world, clients = fullWorld()
        for _, client in ipairs(clients) do
            client:acceptPopup()
        end
        clients[2]:invitedBy("Random Stranger")
        assert.is_nil(clients[2].acceptedFrom)
        world:advance(5)
        assert.are.equal("Tanky Mctank", clients[2].acceptedFrom)
    end)

    it("shows live answers in the proposal popup", function()
        local world, clients = fullWorld()
        clients[1]:acceptPopup()
        world:advance(1)
        local heal = clients[2]
        local tankRow = heal:find("FontString", "Tanky Mctank").parent
        local healRow = heal:find("FontString", "Heally Mcheal (you)").parent
        assert.are.equal("Interface\\RaidFrame\\ReadyCheck-Ready", tankRow.status.texture)
        assert.are.equal("Interface\\RaidFrame\\ReadyCheck-Waiting", healRow.status.texture)
        assert.is_nil(clients[1]:find("Button", "Accept"))
        assert.is_not_nil(clients[1]:find("FontString", "Accepted. Waiting for the others..."))
    end)
end)

describe("WoW test tools", function()
    local function queuedWithFakes(fakeArgs)
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(CONNECT)
        client:slash("/dq join dps auto")
        client:slash("/dq fake " .. fakeArgs)
        return world, client
    end

    it("fills a group with fake players and shows them in the popup", function()
        local world, client = queuedWithFakes("4 tank")
        assert.is_true(client:said("Added 4 fake players"))
        client:slash("/dq fake clear")
        client:slash("/dq fake 4")
        world:advance(MATCH)
        assert.is_true(client:proposalShown())
        assert.is_not_nil(client:find("FontString", client.ns.Slash.fakeName(5)).parent.detail.text:find("  ·  fake$"))
        assert.is_not_nil(client:find("FontString", "Solo Player (you)"))
        world:advance(4)
        local row = client:find("FontString", client.ns.Slash.fakeName(6)).parent
        assert.are.equal("Interface\\RaidFrame\\ReadyCheck-Ready", row.status.texture)
        client:acceptPopup()
        world:advance(1)
        assert.is_true(client:said("Its leader is a fake player"))
        assert.are.same({}, client.invites)
        client:slash("/dq")
        assert.is_not_nil(client:findText("^Not in the queue$"))
        assert.is_nil(client:findText("^open$"))
    end)

    it("adds fake players for a dungeon you chose outside your level", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 13 })
        world:advance(CONNECT)
        client:slash("/dq join dps dm")
        client:slash("/dq fake 4")
        world:advance(MATCH)
        assert.is_true(client:proposalShown())
    end)

    it("shows the dungeon's picture in the proposal popup when the client has one", function()
        local function shownPicture(client, expected)
            for _, widget in ipairs(client.widgets) do
                local visible = widget.kind == "Texture" and widget.texture == expected
                local w = widget
                while visible and w do
                    visible = w.shown ~= false
                    w = w.parent
                end
                if visible then
                    return true
                end
            end
            return false
        end
        local pictures = {
            ["Ragefire Chasm"] = "Interface\\Glues\\LoadingScreens\\LoadScreenRagefireChasm",
            ["Hall of Thanes"] = 7963781,
            ["The Drowned City"] = false,
        }
        for dungeon, picture in pairs(pictures) do
            local world = World.new()
            local client = world:addClient("Solo Player", { level = 13 })
            world:advance(CONNECT)
            client:slash("/dq join dps " .. dungeon)
            client:slash("/dq fake 4")
            world:advance(MATCH)
            assert.is_true(client:proposalShown(), dungeon)
            assert.is_not_nil(client:findText("^" .. dungeon .. "$"), dungeon)
            local any = shownPicture(client, "Interface\\Glues\\LoadingScreens\\LoadScreenRagefireChasm")
                or shownPicture(client, 7963781)
            assert.are.equal(picture ~= false, any, dungeon)
            if picture then
                assert.is_true(shownPicture(client, picture), dungeon)
            end
        end
    end)

    it("lists the proposal as tank, healer, then DPS", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(CONNECT)
        client:slash("/dq join dps auto")
        client:slash("/dq fake 2 dps")
        client:slash("/dq fake 1 healer")
        client:slash("/dq fake 1 tank")
        world:advance(MATCH)
        assert.is_true(client:proposalShown())
        local fake = client.ns.Slash.fakeName
        local function rowY(name)
            return client:find("FontString", name).parent.point[3]
        end
        assert.is_true(rowY(fake(4)) > rowY(fake(3)))
        assert.is_true(rowY(fake(3)) > rowY("Solo Player (you)"))
        assert.is_true(rowY(fake(3)) > rowY(fake(1)))
        assert.is_true(rowY(fake(3)) > rowY(fake(2)))
        assert.is_not_nil(client:find("Texture", "Leader", client:find("FontString", fake(4)).parent))
    end)

    it("groups you with the fakes when many were added before you joined", function()
        local world = World.new()
        local client = world:addClient("Roos Bieff", { level = 13 })
        world:advance(CONNECT)
        client:slash("/dq fake 30")
        world:advance(60)
        client:slash("/dq join dps Ragefire Chasm")
        world:advance(MATCH)
        assert.is_true(client:proposalShown())
        assert.is_not_nil(client:find("FontString", "Roos Bieff (you)"))
    end)

    it("makes the next fake decline", function()
        local world, client = queuedWithFakes("4")
        client:slash("/dq fake decline")
        world:advance(MATCH + 4)
        assert.is_true(client:said("You keep your place in the queue"))
    end)

    it("lists the queue with tags", function()
        local _, client = queuedWithFakes("2 healer")
        client:slash("/dq queuelist")
        assert.is_true(client:said("Solo Player DPS.*%[you%]"))
        assert.is_true(client:said(client.ns.Slash.fakeName(1) .. " Healer.*%[fake%]"))
    end)

    it("gives fake players a class and spec that can play their roles", function()
        local client = World.new():addClient("Solo Player", { level = 20 })
        local Specs, fakeSpec = client.ns.Specs, client.ns.Slash.fakeSpec
        for n = 1, 9 do
            for _, roles in ipairs({ "T", "H", "D", "TD", "HD", "THD" }) do
                local token, index = Specs.decode(fakeSpec(roles, n))
                local tree = Specs.tree(token, index)
                assert.is_not_nil(tree, roles)
                assert.is_not_nil(tree.roles:find(roles:sub(1, 1), 1, true), roles .. " " .. token)
                local playable = ""
                for _, t in ipairs(Specs.TREES[token]) do
                    playable = playable .. t[2]
                end
                for role in roles:gmatch(".") do
                    assert.is_not_nil(playable:find(role, 1, true), roles .. " " .. token)
                end
            end
        end
        assert.are_not.equal(fakeSpec("D", 1), fakeSpec("D", 2))
    end)

    it("gives fake players made-up names, all different", function()
        local _, client = queuedWithFakes("100")
        local seen = {}
        for i = 1, 100 do
            local name = client.ns.Slash.fakeName(i)
            assert.is_truthy(name:find("^%a+ %a+$"), name)
            assert.is_nil(seen[name], name)
            seen[name] = true
        end
        assert.is_true(client:said(client.ns.Slash.fakeName(1)))
    end)

    it("adds up to 100 fake players at once", function()
        local _, client = queuedWithFakes("25")
        assert.is_true(client:said("Added 25 fake players"))
        client:slash("/dq fake 101")
        assert.is_true(client:said("Usage: /fg fake"))
    end)

    it("rejects bad fake commands", function()
        local _, client = queuedWithFakes("0")
        assert.is_true(client:said("Usage: /fg fake"))
        client:slash("/dq fake 2 wizard")
        assert.is_true(client:said("Unknown roles"))
    end)
end)

describe("Main window layout", function()
    it("shows per dungeon how many players of each role are looking", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:list("Listed Tank", "TD", 799)
        world:list("Listed Heal", "H", 799)
        world:advance(12)
        client:slash("/dq")
        world:advance(1)
        client.ns.Window.refresh()
        local counts = client:find("CheckButton", "The Deadmines").counts
        assert.are.equal("1", counts.texts.T.text)
        assert.are.equal("1", counts.texts.H.text)
        assert.are.equal("1", counts.texts.D.text)
        assert.are.equal("0", client:find("CheckButton", "Wailing Caverns").counts.texts.T.text)
    end)

    it("keeps unpicked roles looking available and greys out roles the class cannot play", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20, class = "MAGE" })
        world:advance(12)
        client:slash("/dq")
        local dps, tank = client:find("CheckButton", "DPS"), client:find("CheckButton", "Tank")
        assert.is_true(dps.enabled)
        assert.is_falsy(dps.icon.desaturated)
        assert.is_false(dps.mark.shown)
        assert.are.equal(1, dps.box.alpha)
        assert.is_false(tank.enabled)
        assert.is_true(tank.icon.desaturated)
        assert.is_true(tank.box.desaturated)
        assert.is_true(tank.box.alpha < 1)

        client:click("CheckButton", "DPS")
        assert.is_true(dps.mark.shown)
        assert.is_not_nil(client:findText("^DPS  ·  Relaxed  ·  5 dungeons$"))
    end)
end)

describe("Main window hints", function()
    it("shows dashes until the Group Finder was searched", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(12)
        client.ns.Window.show()
        client.ns.Window.refresh()
        assert.are.equal("-", client:find("CheckButton", "The Deadmines").counts.texts.D.text)
    end)

    it("says which of several roles you will most likely play", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20, class = "PRIEST" })
        world:list("Listed Heal", "H", 799)
        world:list("Dps One", "D", 799)
        world:list("Dps Two", "D", 799)
        world:list("Dps Three", "D", 799)
        world:list("Dps Four", "D", 799)
        world:advance(12)
        client:slash("/dq")
        world:advance(1)
        client:click("CheckButton", "DPS")
        assert.is_nil(client:findText("most likely"))
        client:click("CheckButton", "Healer")
        assert.is_not_nil(client:findText("^You will most likely play Healer: 1 healer, 4 DPS looking%.$"))
    end)
end)

describe("Main window stability", function()
    it("keeps its height when roles are ticked and unticked", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20, class = "PRIEST" })
        world:list("Listed Heal", "H", 799)
        world:advance(12)
        client:slash("/dq")
        world:advance(1)
        client:click("CheckButton", "DPS")
        local window = client:frame("ForeverGroupsFrame")
        local height = window.height
        assert.is_not_nil(client:findText("^Can you play another role too%? Tick it: groups form sooner%.$"))
        client:click("CheckButton", "Healer")
        assert.is_not_nil(client:findText("most likely play"))
        assert.are.equal(height, window.height)
        client:click("CheckButton", "Healer")
        assert.are.equal(height, window.height)
    end)
end)

describe("Main window while queued", function()
    it("lists at most eight dungeons and sums up the rest", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(12)
        client:slash("/dq")
        client:click("Button", "Other dungeons")
        client:click("Button", "All")
        client:click("CheckButton", "DPS")
        client:click("Button", "Find group")
        local count = #client.ns.engine.myEntry.dungeons
        assert.is_true(count > 8)
        assert.is_not_nil(client:findText(string.format("^Searching %d dungeons  ·  Relaxed or Learning$", count)))
        assert.is_not_nil(client:findText(string.format("^and %d more: ", count - 7)))
    end)
end)

describe("Main window edge cases", function()
    it("says so in a raid instead of calling the party complete", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(12)
        client.party = { "A A", "B B", "C C", "D D" }
        client.inRaid = true
        client:slash("/dq")
        assert.is_not_nil(client:findText("^You are in a raid$"))
        assert.is_nil(client:findText("complete %(5/5%)"))
    end)

    it("reports /dq fill problems in chat when the window is closed", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(12)
        client:slash("/dq fill")
        assert.is_true(client:said("Choose at least one role%."))
    end)

    it("queues for every dungeon of your level with 'all'", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(12)
        client:slash("/dq join dps all")
        assert.is_true(#client.ns.engine.myEntry.dungeons > 1)
    end)

    it("hides the role and dungeon choices while filling", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:list("Listed Heal", "H", 799, 20, 300)
        world:advance(12)
        client:slash("/dq")
        client:click("CheckButton", "Tank")
        client:click("Button", "None")
        client:click("CheckButton", "The Deadmines")
        client:slash("/dq fill")
        world:advance(2)
        assert.is_true(client.ns.Filler.isActive())
        assert.is_nil(client:find("CheckButton", "Tank"))
        assert.is_not_nil(client:find("Button", "Stop"))
    end)

    it("clears an old error when a role is changed", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(12)
        client:slash("/dq")
        client.ns.Window.onJoinClicked()
        assert.is_not_nil(client:findText("^Choose at least one role%.$"))
        client:click("CheckButton", "DPS")
        assert.is_nil(client:findText("^Choose at least one role%.$"))
    end)
end)

describe("Leaving while messages wait", function()
    it("never sends an old heartbeat after the leave", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(12)
        client:slash("/dq join dps dm")
        world:advance(1)
        for _ = 1, 40 do
            client.sendResults[#client.sendResults + 1] = 11
        end
        world:advance(50)
        client:slash("/dq leave")
        client.sendResults = {}
        world:advance(10)
        local leftAt
        for i, text in ipairs(client.sent) do
            if text:find("^v2|L") then
                leftAt = i
            end
        end
        assert.is_not_nil(leftAt)
        for i = leftAt + 1, #client.sent do
            assert.is_nil(client.sent[i]:find("^v2|Q"), client.sent[i])
        end
    end)
end)

describe("Dungeons chosen outside the player's level", function()
    it("stay in the list and count when the other dungeons are folded again", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(12)
        client:slash("/dq")
        client:click("Button", "None")
        client:click("Button", "Other dungeons")
        client:click("CheckButton", "Gnomeregan")
        client:click("Button", "Other dungeons")
        assert.is_not_nil(client:find("CheckButton", "Gnomeregan"))
        assert.is_true(client:find("CheckButton", "Gnomeregan").checked)
        assert.is_not_nil(client:findText("·  1 selected$"))
        assert.are.same({ "11" }, client.ns.Window.selectedDungeonIds())

        client:click("CheckButton", "Gnomeregan")
        assert.is_nil(client:find("CheckButton", "Gnomeregan"))
    end)
end)

describe("closing the window", function()
    it("works with the close button in combat too", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(12)
        client:slash("/dq")
        local frame = client:frame("ForeverGroupsFrame")
        assert.is_true(frame:IsShown())
        client.inCombat = true
        frame.CloseButton.scripts.OnClick(frame.CloseButton)
        assert.is_false(frame:IsShown())
    end)
end)
