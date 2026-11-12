local World = require("tests.helpers.wowmock")

-- Many players doing random things for a long time, both queues at once;
-- after every step nobody may be stuck. Seeded, so a failure repeats.
local QUEST_LOG = {
    { "Elwynn Forest", true }, { "Hogger", false, 176, 1 },
    { "Westfall", true }, { "The Big Four", false, 300, nil, 4 },
}
local ROLES = { "tank", "healer", "dps", "dps", "dps", "tank,dps", "healer,dps" }
local DUNGEONS = { "dm", "wc", "sfk", "dm, wc" }
local QUESTS = { { "176-3" }, { "300-4" }, { "176-3", "300-4" } }

local function rng(seed)
    local state = seed
    return function(n)
        state = (state * 1103515245 + 12345) % 2147483648
        return math.floor(state / 65536) % n + 1
    end
end

local function openProposal(engine)
    local key = engine and engine.myProposalKey
    local proposal = key and engine.proposals[key]
    return proposal and not proposal.outcome and proposal or nil
end

-- Whether the player still has to answer the proposal the popup shows.
local function mustAnswer(client)
    for _, engine in ipairs({ client.ns.engine, client.ns.questEngine }) do
        local proposal = openProposal(engine)
        local answer = proposal and proposal.answers[client.name]
        if proposal and (answer == nil or answer == "R") then
            return true
        end
    end
    return false
end

local function checkClient(client, now)
    local name = client.name
    local engines = { client.ns.engine, client.ns.questEngine }
    for _, pair in ipairs({ { engines[1], engines[2] }, { engines[2], engines[1] } }) do
        local engine, other = pair[1], pair[2]
        if engine.held then
            assert(openProposal(other), name .. ": a queue is held without a proposal in the other one")
        end
        local proposal = openProposal(engine)
        if proposal then
            local age = now - proposal.createdAt
            assert(age <= engine.config.PROPOSAL_TIMEOUT + engine.config.PROPOSAL_GRACE + 15,
                name .. ": a proposal stays open for " .. age .. " s")
        end
    end
    if client:proposalShown() then
        assert(openProposal(client.ns.engine) or openProposal(client.ns.questEngine),
            name .. ": the popup shows without an open proposal")
    elseif mustAnswer(client) then
        error(name .. ": a proposal waits for an answer without a popup")
    end
end

local function act(world, client, roll)
    local action = roll(10)
    local quests = client.ns.questEngine
    if action <= 3 and not client.ns.engine.myEntry then
        client:slash("/dq join " .. ROLES[roll(#ROLES)] .. " " .. DUNGEONS[roll(#DUNGEONS)])
    elseif action <= 5 and not quests.myEntry then
        local members = { { name = client.name, roles = ({ "T", "H", "D", "TD" })[roll(4)], level = 20 } }
        client.ns.QuestQueue.join(QUESTS[roll(#QUESTS)], members)
    elseif action == 6 and client.ns.engine.myEntry then
        client:slash("/dq leave")
    elseif action == 7 and quests.myEntry then
        client.ns.QuestQueue.leave()
    end
    world:advance(0)
end

describe("a long random session", function()
    it("never leaves a player stuck", function()
        local world = World.new()
        -- SOAK_SEED and SOAK_STEPS let a longer search run outside the suite.
        local roll = rng(tonumber(os.getenv("SOAK_SEED")) or 20261111)
        local clients = {}
        for i = 1, 10 do
            clients[i] = world:addClient(string.format("Player %02d", i), { level = 20, questLog = QUEST_LOG })
        end
        world:advance(12)
        for step = 1, tonumber(os.getenv("SOAK_STEPS")) or 300 do
            local index = roll(#clients)
            local client = clients[index]
            if roll(40) == 1 then
                local saved = client:logout()
                world:advance(roll(5))
                clients[index] = world:addClient(client.name, { level = 20, questLog = QUEST_LOG, saved = saved })
                world:advance(8)
            else
                act(world, client, roll)
            end
            for _, other in ipairs(clients) do
                if other.ns.engine and other:proposalShown() and mustAnswer(other) and roll(3) ~= 1 then
                    if roll(8) == 1 then
                        other:declinePopup()
                    else
                        other:acceptPopup()
                    end
                end
            end
            world:advance(roll(3))
            local now = world:serverTime()
            for _, other in ipairs(clients) do
                if other.ns.engine then
                    local ok, err = pcall(checkClient, other, now)
                    assert(ok, "step " .. step .. ": " .. tostring(err))
                end
            end
        end
    end)
end)
