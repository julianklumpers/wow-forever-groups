local World = require("tests.helpers.wowmock")

local function search(client, zones)
    client.inClick = true
    if zones then
        client.ns.QuestFinder.searchNow()
    else
        client.ns.LfgList.search()
    end
    client.inClick = false
end

describe("chat-messaging lockdown", function()
    it("reads no Group Finder results while they are secret, and reads them again after", function()
        local world = World.new()
        world:list("Listed Heal", "H", 799, 20, 300, "FunRelaxed")
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(30)
        client:slash("/dq")
        client.lockdown = true
        search(client)
        world:advance(1)
        assert.are.equal(0, #client.ns.LfgList.listings())
        client.ns.Window.refresh()
        client.lockdown = false
        world:advance(11)
        search(client)
        world:advance(1)
        assert.are.equal(1, #client.ns.LfgList.listings())
    end)

    it("reads no zone results while they are secret", function()
        local world = World.new()
        world:list("Zone Tank", "T", 9001, 20, 300)
        local client = world:addClient("Solo Quester", { level = 20, questLog = {
            { "Elwynn Forest", true }, { "Hogger", false, 176, 1 },
        } })
        world:advance(30)
        client:slash("/dq")
        client:click("Button", "Quests")
        client:click("CheckButton", "DPS")
        client.lockdown = true
        client:click("Button", "Find questing group")
        world:advance(2)
        assert.are.equal(0, #client.ns.LfgList.zoneListings())
        assert.are.same({}, client.invites)
    end)

    it("holds the queue's messages and sends them once it ends", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(12)
        client:slash("/dq join dps dm")
        world:advance(2)
        client.lockdown = true
        local before = #client.sent
        world:advance(60)
        assert.are.equal(before, #client.sent)
        assert.are.equal("paused", client.ns.Comm.connection().state)
        client.lockdown = false
        world:advance(8)
        local queued = false
        for i = before + 1, #client.sent do
            queued = queued or client.sent[i]:find("^v2|Q|") ~= nil
        end
        assert.is_true(queued)
    end)

    it("ignores addon messages it cannot read", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(12)
        client:fire("CHAT_MSG_ADDON", "ForeverGroups", World.SECRET, "CHANNEL", "Some One", "", 0, 6,
            "ForeverGroupsNet")
        client:fire("CHAT_MSG_ADDON", "ForeverGroups", "v2|L", "CHANNEL", World.SECRET, "", 0, 6, "ForeverGroupsNet")
        client:fire("CHAT_MSG_ADDON", "ForeverGroups", World.SECRET, "PARTY", "Some One")
    end)

    it("ignores chat text and names it cannot read during a boss fight", function()
        local world = World.new()
        local client = world:addClient("Tanky Mctank", { level = 20 })
        world:advance(12)
        client:slash("/dq fill")
        for _, event in ipairs({ "CHAT_MSG_SYSTEM", "CHAT_MSG_WHISPER", "PARTY_INVITE_REQUEST",
            "ADDON_ACTION_BLOCKED", "CHAT_MSG_CHANNEL_NOTICE", "ROLE_CHANGED_INFORM" }) do
            client:fire(event, World.SECRET, World.SECRET, World.SECRET, World.SECRET, World.SECRET,
                World.SECRET, World.SECRET, World.SECRET, World.SECRET)
        end
        client:fire("ENCOUNTER_END", World.SECRET, World.SECRET, 1, 5, World.SECRET)
    end)

    it("leaves out a secret playstyle or talent position", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20, class = "SHAMAN",
            talents = { { World.SECRET, 5 }, { 5000, 3 } } })
        world:advance(12)
        assert.is_nil(client.ns.Playstyle.fromWoW(World.SECRET))
        assert.are.same({ 0, 3, 0 }, client.ns.Spec.points())
    end)
end)
