local World = require("tests.helpers.wowmock")

local PLAYERS = {
    { "Tanky Mctank", "tank" }, { "Heally Mcheal", "healer" }, { "Dps One", "dps" }, { "Dps Two", "dps" },
    { "Dps Three", "dps" },
}

describe("a proposal that could not be sent in time", function()
    it("is called off by its matchmaker, and nobody counts as gone", function()
        local world = World.new()
        local clients = {}
        for i, p in ipairs(PLAYERS) do
            clients[i] = world:addClient(p[1])
        end
        world:advance(30)
        for i, p in ipairs(PLAYERS) do
            clients[i]:slash("/dq join " .. p[2] .. " auto")
        end
        local matchmaker = clients[3]
        assert.is_true(matchmaker.ns.engine:isMatchmaker())
        assert.is_nil(next(matchmaker.ns.engine.proposals))
        matchmaker.lockdown = true
        local proposed
        for _ = 1, 30 do
            world:advance(1)
            if next(matchmaker.ns.engine.proposals) then
                proposed = true
                break
            end
        end
        assert.is_true(proposed)
        world:advance(9)
        assert.is_nil(next(matchmaker.ns.engine.proposals))
        for _, client in ipairs(clients) do
            if client ~= matchmaker then
                assert.is_false(client:proposalShown(), client.name)
            end
            assert.is_not_nil(matchmaker.ns.engine.queue:get(client.name), client.name)
        end
        matchmaker.lockdown = false
        world:advance(12)
        for _, client in ipairs(clients) do
            assert.is_true(client:proposalShown(), client.name)
        end
    end)
end)
