local Asks = require("core.asks")

local function find(names, name)
    if names[name] then
        return name
    end
    for key in pairs(names) do
        if key:match("^[^%-]+") == name:match("^[^%-]+") then
            return key
        end
    end
end

describe("Asks", function()
    local now, asks

    before_each(function()
        now = 100
        asks = Asks.new({ clock = function() return now end, find = find, wait = 20, promiseWait = 30 })
    end)

    it("waits for an invite a while, longer after a yes, and not after a no", function()
        asks:add("Lead-Realm", 7, "H")
        asks:add("Other", 8, "D")
        assert.are.equal(2, asks:waiting())
        asks:answer("Other", "no")
        assert.are.equal(1, asks:waiting())
        asks:answer("Lead-Realm", "yes")
        now = 125
        assert.are.equal(1, asks:waiting())
        now = 156
        assert.are.equal(0, asks:waiting())
    end)

    it("finds a leader with or without the realm", function()
        asks:add("Lead-Realm", 7, "H")
        local ask, key = asks:get("Lead")
        assert.are.equal("Lead-Realm", key)
        assert.are.equal("H", ask.role)
        assert.is_nil(asks:find("Nobody"))
    end)

    it("ends asks whose group left the Group Finder in newer results", function()
        asks:add("Gone", 1, "D")
        asks:add("Here", 2, "D")
        asks:add("Promised", 3, "D")
        asks:answer("Promised", "yes")
        assert.are.same({}, asks:settle(100, function() return false end))
        local ended = asks:settle(101, function(leader) return leader == "Here" end)
        assert.are.same({ "Gone" }, ended)
        assert.are.equal(2, asks:waiting())
    end)

    it("answers a leader's question once", function()
        asks:add("Lead", 1, "D")
        assert.is_true(asks:firstQuestion("Lead"))
        assert.is_false(asks:firstQuestion("Lead"))
        assert.is_false(asks:firstQuestion("Nobody"))
    end)
end)
