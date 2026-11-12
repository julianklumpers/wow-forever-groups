local World = require("tests.helpers.wowmock")

local function filling()
    local world = World.new()
    local tank = world:addClient("Solo Tank", { level = 20 })
    world:list("Listed Heal", "H", 799, 20, 300)
    world:advance(30)
    return world, tank
end

local function whispersTo(client, name)
    local texts = {}
    for _, w in ipairs(client.whispers) do
        if w.target == name then
            texts[#texts + 1] = w.text
        end
    end
    return texts
end

describe("the messages Forever Groups sends", function()
    it("uses the player's own text, with the placeholders filled in", function()
        local world, tank = filling()
        tank.ns.Messages.set("fillInvite", "Hoi! {dungeon} zoekt een {role}, ik nodig je uit.")
        tank:slash("/dq join tank dm")
        world:advance(2)
        assert.are.same({ "[Forever Groups] Hoi! The Deadmines zoekt een healer, ik nodig je uit." },
            whispersTo(tank, "Listed Heal"))
    end)

    it("still invites, without the whisper, when that message is turned off", function()
        local world, tank = filling()
        tank.ns.Messages.setOn("fillInvite", false)
        tank:slash("/dq join tank dm")
        world:advance(2)
        assert.are.same({}, whispersTo(tank, "Listed Heal"))
        local invited = false
        for _, name in ipairs(tank.invites) do
            invited = invited or name == "Listed Heal"
        end
        assert.is_true(invited)
    end)

    it("leaves out a sentence whose placeholder has no value, and keeps chat-safe text", function()
        local _, tank = filling()
        local Messages = tank.ns.Messages
        Messages.set("groupInvite", "Found {dungeon}|r! I'm the {spec}. Come in.")
        assert.are.equal("[Forever Groups] Found The Deadmines! Come in.",
            Messages.text("groupInvite", { dungeon = "The Deadmines" }))
        Messages.set("groupInvite", string.rep("é", 200))
        assert.is_true(#Messages.text("groupInvite", {}) <= 255)
        Messages.reset("groupInvite")
        assert.are.equal("[Forever Groups] Group found for DM. Inviting you now.",
            Messages.text("groupInvite", { dungeon = "DM", spec = "Shaman" }))
    end)

    it("are edited in the Messages window, with a preview and a reset", function()
        local _, tank = filling()
        tank:slash("/fg messages")
        assert.is_true(tank:frame("ForeverGroupsSettingsFrame").shown)
        assert.is_not_nil(tank:find("CheckButton", "Whisper players before inviting them"))
        assert.is_nil(tank:find("CheckButton", "Use WoW's Group Finder"))
        local row = tank.ns.MessagesWindow.row("partyComplete")
        assert.is_not_nil(tank:findText("^Sends: %[Forever Groups%] Group complete for The Deadmines!"))
        row.edit:SetText("Klaar! Op naar {dungeon}.")
        row.edit.scripts.OnTextChanged(row.edit, true)
        assert.are.equal("Klaar! Op naar {dungeon}.", tank.ns.db.messages.partyComplete.text)
        assert.is_not_nil(tank:findText("^Sends: %[Forever Groups%] Klaar! Op naar The Deadmines%.$"))
        row.check:SetChecked(false)
        row.check.scripts.OnClick(row.check)
        assert.is_not_nil(tank:findText("^Turned off: nothing is sent%.$"))
        row.reset.scripts.OnClick(row.reset)
        assert.is_nil(tank.ns.db.messages.partyComplete)
        assert.is_true(tank.ns.Messages.isOn("partyComplete"))
        tank:slash("/fg settings")
        assert.is_false(tank:frame("ForeverGroupsSettingsFrame").shown)
        tank:slash("/fg settings")
        assert.is_not_nil(tank:find("CheckButton", "Whisper players before inviting them"))
    end)
end)
