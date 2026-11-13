local World = require("tests.helpers.wowmock")
local LocaleKeys = dofile("tools/localekeys.lua")

local LOCALES = { "deDE", "esES", "ruRU" }

local function translations()
    local all = {}
    local ns = { Locale = { add = function(codes, strings)
        for _, code in ipairs(codes) do
            all[code] = strings
        end
    end } }
    for _, code in ipairs(LOCALES) do
        assert(loadfile("locales/" .. code .. ".lua"))(nil, ns)
    end
    return all
end

local function placeholders(text)
    local list = {}
    for spec in string.gmatch(text, "%%[%d%.]*[sdf]") do
        list[#list + 1] = spec
    end
    return table.concat(list, " ")
end

describe("translations", function()
    local keys = LocaleKeys.collect(".")
    local all = translations()

    for _, code in ipairs(LOCALES) do
        it("cover every text in " .. code .. ", with the same placeholders", function()
            local missing, wrong = {}, {}
            for key in pairs(keys) do
                local text = all[code][key]
                if not text then
                    missing[#missing + 1] = key
                elseif placeholders(text) ~= placeholders(key) then
                    wrong[#wrong + 1] = key .. " => " .. text
                end
            end
            table.sort(missing)
            table.sort(wrong)
            assert.are.same({}, missing)
            assert.are.same({}, wrong)
        end)
    end

    it("can be chosen in the settings, over WoW's language", function()
        local world = World.new()
        local client = world:addClient("Solo Player", { level = 20 })
        world:advance(30)
        client:slash("/fg settings")
        client:click("Button", "Display")
        client:click("Button", "Deutsch")
        assert.are.equal("deDE", client.ns.db.language)
        assert.are.equal(all.deDE["Find group"], client.ns.L["Find group"])
        assert.are.equal("FOREVERGROUPS_LANGUAGE_RELOAD", client.popups[#client.popups])
        client:click("Button", "Automatic")
        assert.is_nil(client.ns.db.language)
        assert.are.equal("Find group", client.ns.L["Find group"])
    end)

    it("show in the player's language, while whispers stay English", function()
        local world = World.new()
        world:listGroup("Group Lead", 799, { T = 0, H = 0, D = 1 })
        local client = world:addClient("Solo Player", { level = 20, locale = "deDE" })
        world:advance(30)
        client:slash("/dq")
        local german = all.deDE["Find group"]
        assert.is_not_nil(client:find("Button", german))
        client:slash("/dq join dps dm")
        world:advance(2)
        assert.is_truthy(client.whispers[1].text:find("could you invite me for The Deadmines", 1, true))
    end)
end)
