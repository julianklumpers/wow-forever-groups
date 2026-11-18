local World = require("tests.helpers.wowmock")
local Config = require("core.config")

local function asked(client)
    local names = {}
    for _, w in ipairs(client.whispers) do
        if w.text:find("could you invite me") then
            names[#names + 1] = w.target
        end
    end
    return names
end

local function invitedCount(client, name)
    local count = 0
    for _, n in ipairs(client.invites) do
        if n == name then
            count = count + 1
        end
    end
    return count
end

describe("Group Finder flows after review", function()
    it("does not invite a whisperer while a queue proposal is open", function()
        local world = World.new()
        local tank = world:addClient("Tanky Mctank", { level = 20 })
        local heal = world:addClient("Heally Mcheal", { level = 20 })
        world:list("Listed Dps", "D", 799, 20, 300)
        world:advance(30)
        tank:slash("/dq join tank dm")
        world:advance(3)
        assert.is_true(tank.ns.Filler.isActive())
        heal:slash("/dq join healer dm")
        world:advance(Config.MATCH_INTERVAL + 2)
        assert.is_true(tank:proposalShown())
        tank:whisperFrom("Whisper Heal", "healer here, inv?")
        assert.are.equal(0, invitedCount(tank, "Whisper Heal"))
    end)

    it("stops inviting and listing after joining someone else's group", function()
        local world = World.new()
        local solo = world:addClient("Solo Dps", { level = 20 })
        world:list("Listed Heal", "H", 799, 20, 300)
        world:advance(30)
        solo:slash("/dq join dps dm")
        world:advance(3)
        assert.is_true(solo.ns.Filler.isActive())
        solo:joinGroupOf("Random Leader")
        world:advance(70)
        assert.is_false(solo.ns.Filler.isActive())
        solo:press("W")
        solo:press("W")
        assert.is_falsy(solo.listed)
    end)

    it("asks groups first even when an older search is cached", function()
        for _, offset in ipairs({ 0, 0.2, 0.5, 0.7, 0.9 }) do
            local world = World.new()
            local solo = world:addClient("Solo Dps", { level = 20 })
            world:advance(30)
            solo.inClick, solo.clickSearched = true, false
            solo.ns.LfgList.search()
            solo.inClick = false
            world:advance(2)
            world:listGroup("Group Lead", 799, { T = 0, H = 1, D = 1 })
            world:list("Listed Heal", "H", 799, 20, 300)
            world:advance(20 + offset)
            solo:slash("/dq join dps dm")
            world:advance(3)
            assert.are.same({ "Group Lead" }, asked(solo), "offset " .. offset)
            assert.is_false(solo.ns.Filler.isActive(), "offset " .. offset)
        end
    end)

    it("counts a player who accepts just before the invite expires and does not overfill", function()
        local world = World.new()
        local tank = world:addClient("Solo Tank", { level = 20 })
        world:list("Heal A", "H", 799, 20, 300)
        world:list("Dps A", "D", 799, 20, 300)
        world:list("Dps B", "D", 799, 20, 100)
        world:list("Dps C", "D", 799, 20, 100)
        world:advance(30)
        tank:slash("/dq join tank dm")
        world:advance(3)
        tank:joins("Dps A")
        tank:joins("Dps B")
        tank:joins("Dps C")
        world:advance(55)
        tank:joins("Heal A")
        world:advance(3)
        assert.is_false(tank.ns.Filler.isActive())
        assert.is_true(tank:logged("Heal A joined as Healer"))
    end)

    it("lists the group even when nobody fitting is listed yet", function()
        local world = World.new()
        local tank = world:addClient("Solo Tank", { level = 20 })
        world:advance(30)
        tank:slash("/dq join tank dm")
        world:advance(3)
        assert.is_true(tank.ns.Filler.isActive())
        tank:press("W")
        assert.is_true(tank.listed)
        tank:whisperFrom("Whisper Heal", "heal")
        world:advance(1)
        assert.truthy(tank.whispers[#tank.whispers].text:find("for The Deadmines"))
    end)

    it("does not treat Forever Groups's own whispers as role offers", function()
        local world = World.new()
        local tank = world:addClient("Solo Tank", { level = 20 })
        world:advance(30)
        tank:slash("/dq join tank dm")
        world:advance(3)
        tank:whisperFrom("Other Builder",
            "[Forever Groups] Hi! Our group for The Deadmines needs a dps. Inviting you now.")
        assert.are.equal(0, invitedCount(tank, "Other Builder"))
        tank:whisperFrom("Seeker Dps", "Hi! Level 20 DPS here, could you invite me for The Deadmines? (Forever Groups)")
        assert.are.equal(1, invitedCount(tank, "Seeker Dps"))
    end)
end)

describe("Who is looking", function()
    it("puts a crown before a group's leader, its classes in a column, a player's class before them", function()
        local world = World.new()
        world:listGroup("Group Lead", 799, { T = 0, H = 0, D = 2 })
        world.listings[#world.listings].memberList = { { class = "MAGE", role = "DAMAGER", level = 19 },
            { class = "SHAMAN", role = "HEALER", level = 18 } }
        world:list("Solo Mage", "D", 799, 20, 200)
        world.listings[#world.listings].class = "MAGE"
        world:list("Solo Unknown", "D", 799, 20, 100)
        local client = world:addClient("Look Player", { level = 20,
            atlases = { ["classicon-mage"] = true, ["classicon-shaman"] = true } })
        world:advance(30)
        client:slash("/dq")
        client:click("CheckButton", "Healer")
        client:press("W")
        world:advance(1)
        client.ns.QueueWindow.refresh()
        local group = client:findText("^Group Lead %+").parent
        assert.is_true(group.badge.shown)
        client.ns.QueueWindow.showRowTooltip(group, group.item)
        assert.are.same({
            "Paladin   |TInterface\\GroupFrame\\UI-Group-LeaderIcon:12:12|t Group Lead | Tank  ·  Lvl 20",
            "|A:classicon-shaman:14:14|a Shaman | Healer  ·  Lvl 18",
            "|A:classicon-mage:14:14|a Mage | DPS  ·  Lvl 19",
        }, { client.env.GameTooltip.lines[1], client.env.GameTooltip.lines[2], client.env.GameTooltip.lines[3] })
        for _, line in ipairs(client.env.GameTooltip.lines) do
            assert.is_nil(line:find("^Has:"))
        end
        assert.are.equal("Interface\\GroupFrame\\UI-Group-LeaderIcon", group.badge.texture)
        assert.is_true(group.name.point[2] > group.badge.point[2])
        assert.are.same({ true, true, false },
            { group.classIcons[1].shown, group.classIcons[2].shown, group.classIcons[3].shown })
        assert.are.same({ "classicon-shaman", "classicon-mage" },
            { group.classIcons[1].atlas, group.classIcons[2].atlas })
        client:click("Button", "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:16:16|t Lead a group")
        client.ns.QueueWindow.refresh()
        local mage = client:findText("^Solo Mage$").parent
        local unknown = client:findText("^Solo Unknown$").parent
        assert.is_true(mage.badge.shown)
        assert.are.equal("classicon-mage", mage.badge.atlas)
        assert.is_false(mage.classIcons[1].shown)
        assert.is_false(unknown.badge.shown)
        assert.is_true(mage.name.point[2] > unknown.name.point[2])
    end)

    it("shows a listed player only in the roles their class can play", function()
        local world = World.new()
        world:list("Lock Everything", "THD", 799, 20, 200)
        world.listings[#world.listings].class = "WARLOCK"
        world:list("Priest Tank", "T", 799, 20, 100)
        world.listings[#world.listings].class = "PRIEST"
        local client = world:addClient("Look Player", { level = 20 })
        world:advance(30)
        client:slash("/dq")
        client:click("CheckButton", "Tank")
        client:click("Button", "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:16:16|t Lead a group")
        client:press("W")
        world:advance(1)
        local roles = {}
        for _, listing in ipairs(client.ns.LfgList.listings()) do
            roles[listing.name] = listing.roles
        end
        assert.are.same({ ["Lock Everything"] = "D" }, roles)
    end)

    it("lists both sources in one table, a player in both once, Forever Groups first on a tie", function()
        local world = World.new()
        local client = world:addClient("Look Player", { level = 20 })
        local both = world:addClient("Both Player", { level = 20 })
        world:list("Both Player", "D", 799, 20, 300)
        world:list("Listed Only", "D", 799, 20, 300)
        world:advance(30)
        client.ns.db.queueFold = { players = false }
        both:slash("/dq join dps dm")
        client:slash("/dq")
        client:click("CheckButton", "Healer")
        client:press("W")
        world:advance(1)
        client.ns.QueueWindow.refresh()
        local rows = {}
        for _, widget in ipairs(client.widgets) do
            if widget.kind == "FontString" and widget.parent and widget.parent.item and widget == widget.parent.name
                and widget.parent.shown and widget.parent.parent.shown then
                rows[#rows + 1] = widget.text .. " " .. widget.parent.item.source
            end
        end
        assert.are.same({ "Both Player addon", "Listed Only finder" }, rows)
    end)

    it("shows a party's wished classes in the Needs column, its other places by role", function()
        local world = World.new()
        local client = world:addClient("Look Player", { level = 20, atlases = { ["classicon-mage"] = true } })
        world:advance(30)
        client.ns.db.queueFold = { groups = false }
        local engine = client.ns.engine
        client:slash("/dq queue")
        engine.queue:upsert({ id = "Party Lead", joinedAt = 1, dungeons = { "5" }, reserved = "",
            compose = "0:0.0.64.0.0", members = {
                { name = "Party Lead", roles = "H", level = 20 }, { name = "Friend One", roles = "T", level = 20 },
            } }, engine:now())
        client.ns.QueueWindow.refresh()
        local row = client:findText("^Party Lead %+1$").parent
        assert.is_false(row.needs[1].shown == true)
        assert.are.same({ true, false, false },
            { row.wishIcons[1].shown, row.wishIcons[2].shown, row.wishIcons[3].shown })
        assert.are.same({ false, true, false },
            { row.wishRoles[1].shown, row.wishRoles[2].shown, row.wishRoles[3].shown })
        assert.are.equal("classicon-mage", row.wishIcons[1].atlas)
        client.ns.QueueWindow.showRowTooltip(row, row.item)
        local tip = table.concat(client.env.GameTooltip.lines, "\n")
        assert.is_truthy(tip:find("Wants: DPS: Mage", 1, true))
    end)
end)

