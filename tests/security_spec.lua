local World = require("tests.helpers.wowmock")

local function sendRaw(client, text, chatType)
    local target = chatType == "PARTY" and nil or tostring(client.ns.Comm.channelId())
    client.env.C_ChatInfo.SendAddonMessage("DungeonQueue", text, chatType or "CHANNEL", target)
end

local function heartbeat(client, owner)
    return client.ns.Protocol.encode({
        kind = "queue", joinedAt = client.env.GetServerTime(), dungeons = { "5" },
        members = { { name = owner, roles = "D", level = 20 } }, reserved = "",
    })
end

describe("messages from players who are not who they say", function()
    it("ignores a queue entry sent for someone else", function()
        local world = World.new()
        local liar = world:addClient("Liar Player", { level = 20 })
        local other = world:addClient("Other Player", { level = 20 })
        world:advance(12)
        sendRaw(liar, heartbeat(liar, "Innocent Player"))
        world:advance(1)
        assert.is_nil(other.ns.engine.queue:get("Innocent Player"))
        assert.is_nil(other.ns.engine.queue:get("Liar Player"))
    end)

    it("only takes the party's queue status from the party leader", function()
        local world = World.new()
        local leader = world:addClient("Lead Player", { level = 20 })
        local member = world:addClient("Member Player", { level = 20 })
        local other = world:addClient("Other Member", { level = 20 })
        world:advance(12)
        leader.party, leader.isLeader = { "Member Player", "Other Member" }, true
        member.party = { "Lead Player", "Other Member" }
        other.party = { "Lead Player", "Member Player" }
        sendRaw(other, "v2|G|F|5|Other Member", "PARTY")
        world:advance(1)
        assert.is_nil(member.ns.PartyStatus.current())
        sendRaw(leader, "v2|G|F|5|Lead Player", "PARTY")
        world:advance(1)
        assert.are.equal("formed", member.ns.PartyStatus.current().phase)
    end)
end)

describe("players who send too many messages", function()
    it("are ignored for a while and taken out of the queue", function()
        local world = World.new()
        local spammer = world:addClient("Spam Bot", { level = 20 })
        local other = world:addClient("Other Player", { level = 20 })
        world:advance(12)
        sendRaw(spammer, heartbeat(spammer, "Spam Bot"))
        world:advance(1)
        assert.is_not_nil(other.ns.engine.queue:get("Spam Bot"))
        for _ = 1, 30 do
            sendRaw(spammer, heartbeat(spammer, "Spam Bot"))
        end
        world:advance(1)
        assert.is_nil(other.ns.engine.queue:get("Spam Bot"))
        assert.is_true(other.ns.Comm.limit:isMuted("Spam Bot"))
        world:advance(60)
        sendRaw(spammer, heartbeat(spammer, "Spam Bot"))
        world:advance(1)
        assert.is_nil(other.ns.engine.queue:get("Spam Bot"))
        world:advance(300)
        sendRaw(spammer, heartbeat(spammer, "Spam Bot"))
        world:advance(1)
        assert.is_not_nil(other.ns.engine.queue:get("Spam Bot"))
    end)

    it("never cut off a normal client, also while a group forms", function()
        local world = World.new()
        local clients = {}
        for i, role in ipairs({ "tank", "heal", "dps", "dps", "dps" }) do
            clients[i] = world:addClient("Player " .. string.char(64 + i), { level = 20 })
            world:advance(1)
            clients[i]:slash("/dq join " .. role .. " dm")
        end
        world:advance(240)
        for _, receiver in ipairs(clients) do
            for _, sender in ipairs(clients) do
                assert.is_false(receiver.ns.Comm.limit:isMuted(sender.name))
            end
        end
    end)
end)

describe("version check", function()
    it("warns an older client once two players run a newer version", function()
        local world = World.new()
        local old = world:addClient("Old Client", { level = 20, version = "0.6.0" })
        world:advance(12)
        world:addClient("New One", { level = 20, version = "0.8.0" })
        world:advance(12)
        assert.is_false(old:said("Please update"))
        world:addClient("New Two", { level = 20, version = "0.8.1" })
        world:advance(12)
        assert.is_true(old:said("Forever Groups 0%.8%.0 is out %(you have 0%.6%.0%)%. Please update"))
        old:slash("/dq")
        assert.is_not_nil(old:findText("update available"))
    end)

    it("tells an older client that logs in later, each newer client answering at most once", function()
        local world = World.new()
        local newer = {}
        for i = 1, 4 do
            newer[i] = world:addClient("New Client " .. i, { level = 20, version = "0.8.0" })
        end
        world:advance(40)
        local before = {}
        for i, client in ipairs(newer) do
            before[i] = #client.sent
        end
        local old = world:addClient("Old Client", { level = 20, version = "0.6.0" })
        world:advance(30)
        assert.is_true(old:said("Forever Groups 0%.8%.0 is out"))
        for i, client in ipairs(newer) do
            local answers = 0
            for n = before[i] + 1, #client.sent do
                if client.sent[n]:find("^DQV|") then
                    answers = answers + 1
                end
            end
            assert.is_true(answers <= 1, client.name .. " answered " .. answers .. " times")
        end
    end)

    it("does not warn because of one player announcing a made-up version", function()
        local world = World.new()
        local client = world:addClient("Normal Client", { level = 20 })
        world:advance(12)
        world:addClient("Troll Client", { level = 20, version = "99.0.0" })
        world:advance(12)
        assert.is_false(client:said("Please update"))
    end)

    it("says when the newer version can no longer match with it", function()
        local world = World.new()
        local old = world:addClient("Old Client", { level = 20, version = "0.6.0" })
        world:advance(12)
        for i = 1, 2 do
            world:addClient("Next Protocol " .. i, { level = 20, version = "1.0.0", beforeLogin = function(client)
                client.ns.Protocol.VERSION = "v3"
            end })
        end
        world:advance(12)
        assert.is_true(old:said("cannot be matched with players who updated"))
    end)

    it("keeps reminding after a reload until the player updates", function()
        local world = World.new()
        local old = world:addClient("Old Client", { level = 20, version = "0.6.0" })
        local one = world:addClient("New One", { level = 20, version = "0.8.0" })
        local two = world:addClient("New Two", { level = 20, version = "0.8.0" })
        world:advance(30)
        one:logout()
        two:logout()
        local saved = old:logout()
        local again = world:addClient("Old Client", { level = 20, version = "0.6.0", saved = saved })
        world:advance(12)
        assert.is_true(again:said("Forever Groups 0%.8%.0 is out"))
        local savedAgain = again:logout()
        local updated = world:addClient("Old Client", { level = 20, version = "0.8.0", saved = savedAgain })
        world:advance(12)
        assert.is_false(updated:said("Please update"))
        assert.is_nil(updated.ns.db.newestVersion)
    end)
end)
