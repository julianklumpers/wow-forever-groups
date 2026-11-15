local World = require("tests.helpers.wowmock")
local Sim = require("tests.helpers.sim")
local Languages = require("core.languages")
local Protocol = require("core.protocol")
local Matchmaker = require("core.matchmaker")
local QuestMatch = require("core.questmatch")
local BgMatch = require("core.bgmatch")
local Config = require("core.config")

local NOW = 1000000
local CONNECT = 30
local GERMAN_ONLY, GERMAN_TAKES_ENGLISH = "deDE:2", "deDE:3"
local ENGLISH_ONLY, ENGLISH_TAKES_GERMAN = "enUS:1", "enUS:3"

local function entry(id, joinedAt, roles, language, dungeons)
    return { id = id, joinedAt = joinedAt, dungeons = dungeons or { "5" }, language = language,
        members = { { name = id, roles = roles, level = 20 } } }
end

local function dungeonGroups(tank, others)
    return Matchmaker.findGroups({
        entry("Tank", 1, "T", tank), entry("Heal", 2, "H", others), entry("Dps1", 3, "D", others),
        entry("Dps2", 4, "D", others), entry("Dps3", 5, "D", others),
    }, Config.SLOTS, NOW)
end

local function questGroups(first, others)
    local key = "176-3"
    return QuestMatch.findGroups({
        entry("Lead", 1, "T", first, { key }), entry("Two", 2, "H", others, { key }),
        entry("Three", 3, "D", others, { key }),
    }, nil, NOW)
end

local function bgGroups(first, second)
    local key = "wsg-10"
    return BgMatch.findGroups({ entry("One", 1, "D", first, { key }), entry("Two", 2, "D", second, { key }) })
end

describe("game languages", function()
    it("count WoW's regional variants as the Group Finder's language", function()
        assert.are.equal("enUS", Languages.normalize("enGB"))
        assert.are.equal("esES", Languages.normalize("esMX"))
        assert.are.equal("ptBR", Languages.normalize("ptPT"))
        assert.are.equal("deDE", Languages.normalize("deDE"))
    end)

    it("travel as the own language and a mask of those taken", function()
        local text = Languages.encode("deDE", { deDE = true, enUS = true, xxXX = true })
        assert.are.equal("deDE:3", text)
        assert.are.same({ code = "deDE", accepts = { deDE = true, enUS = true } }, Languages.decode(text))
        assert.are.equal("ruRU:16", Languages.encode("ruRU", {}))
        assert.is_nil(Languages.encode("itIT", { enUS = true }))
        for _, bad in ipairs({ "deDE:1", "xxXX:1", "deDE:", "deDE", "deDE:x", "deDE:99999", "", 5 }) do
            assert.is_nil(Languages.decode(bad), tostring(bad))
        end
    end)

    it("ride along in a queue entry; an invalid or missing one is unknown", function()
        local msg = { kind = "queue", joinedAt = 5, dungeons = { "5" }, members = { { name = "Lead-R", roles = "T",
            level = 20 } }, language = "frFR:9" }
        local text = Protocol.encode(msg)
        assert.are.equal("v2|Q|5|5|Lead-R:T:20||||||||frFR:9", text)
        assert.are.equal("frFR:9", Protocol.decode(text).language)
        local invalid = Protocol.decode("v2|Q|5|5|Lead-R:T:20||||||||frFR:1")
        assert.is_not_nil(invalid)
        assert.is_nil(invalid.language)
        local old = Protocol.decode("v2|Q|5|5|Lead-R:T:20||1000")
        assert.is_not_nil(old)
        assert.is_nil(old.language)
    end)

    it("group two players only when each takes the other's language", function()
        assert.is_false(Languages.compatible(GERMAN_ONLY, ENGLISH_ONLY))
        assert.is_false(Languages.compatible(GERMAN_TAKES_ENGLISH, ENGLISH_ONLY))
        assert.is_false(Languages.compatible(ENGLISH_ONLY, GERMAN_TAKES_ENGLISH))
        assert.is_true(Languages.compatible(GERMAN_TAKES_ENGLISH, ENGLISH_TAKES_GERMAN))
        assert.is_true(Languages.compatible(ENGLISH_ONLY, ENGLISH_TAKES_GERMAN))
        assert.is_true(Languages.compatible(nil, GERMAN_ONLY))
        assert.is_true(Languages.compatible(ENGLISH_ONLY, nil))
    end)
end)

describe("matchmaking by language", function()
    it("forms a dungeon group only from players who take each other's language", function()
        assert.are.same({}, dungeonGroups(GERMAN_ONLY, ENGLISH_ONLY))
        assert.are.same({}, dungeonGroups(GERMAN_TAKES_ENGLISH, ENGLISH_ONLY))
        assert.are.same({}, dungeonGroups(GERMAN_ONLY, ENGLISH_TAKES_GERMAN))
        assert.are.equal(1, #dungeonGroups(GERMAN_TAKES_ENGLISH, ENGLISH_TAKES_GERMAN))
        assert.are.equal(1, #dungeonGroups(GERMAN_ONLY, nil))
        assert.are.equal(1, #dungeonGroups(nil, ENGLISH_ONLY))
    end)

    it("checks every pair of a dungeon group, not only the one with the anchor", function()
        local list = {
            entry("Tank", 1, "T", nil), entry("Heal", 2, "H", GERMAN_ONLY), entry("Dps1", 3, "D", ENGLISH_ONLY),
            entry("Dps2", 4, "D", ENGLISH_ONLY), entry("Dps3", 5, "D", ENGLISH_ONLY),
        }
        assert.are.same({}, Matchmaker.findGroups(list, Config.SLOTS, NOW))
        list[2].language = ENGLISH_TAKES_GERMAN
        assert.are.equal(1, #Matchmaker.findGroups(list, Config.SLOTS, NOW))
    end)

    it("leaves a player of another language out of a partial group", function()
        local list = { entry("Tank", 1, "T", GERMAN_ONLY), entry("Heal", 2, "H", ENGLISH_ONLY) }
        assert.is_nil(Matchmaker.findPartialGroup(list, Config.SLOTS, NOW, 0, 2))
        list[2].language = ENGLISH_TAKES_GERMAN
        list[1].language = GERMAN_TAKES_ENGLISH
        assert.is_not_nil(Matchmaker.findPartialGroup(list, Config.SLOTS, NOW, 0, 2))
    end)

    it("holds for questing groups", function()
        assert.are.same({}, questGroups(GERMAN_ONLY, ENGLISH_ONLY))
        assert.are.same({}, questGroups(GERMAN_TAKES_ENGLISH, ENGLISH_ONLY))
        assert.are.equal(1, #questGroups(GERMAN_TAKES_ENGLISH, ENGLISH_TAKES_GERMAN))
        assert.are.equal(1, #questGroups(nil, ENGLISH_ONLY))
    end)

    it("holds for battleground groups", function()
        assert.are.same({}, bgGroups(GERMAN_ONLY, ENGLISH_ONLY))
        assert.are.same({}, bgGroups(GERMAN_TAKES_ENGLISH, ENGLISH_ONLY))
        assert.are.same({}, bgGroups(ENGLISH_ONLY, GERMAN_TAKES_ENGLISH))
        assert.are.equal(1, #bgGroups(GERMAN_TAKES_ENGLISH, ENGLISH_TAKES_GERMAN))
        assert.are.equal(1, #bgGroups(GERMAN_ONLY, nil))
    end)
end)

describe("Engine: a proposal with a player of another language", function()
    local function answerTo(language, theirs)
        local sim = Sim.new()
        sim:add("Ger-R")
        local engine = sim:engine("Ger-R")
        engine:setLanguage(language)
        sim:join("Ger-R", "T", { "DM" })
        engine.queue:upsert({ id = "Eng-R", joinedAt = 1, dungeons = { "DM" }, language = theirs,
            members = { { name = "Eng-R", roles = "H", level = 60 } } }, engine:now())
        local seq = engine:now() * 1000 + 1
        engine:addProposal("Match-R", { seq = seq, dungeon = "DM", missing = "DDD", playstyles = {},
            entries = { { { name = "Eng-R", role = "H" } }, { { name = "Ger-R", role = "T" } } } })
        for _, msg in ipairs(sim.sent) do
            local answer = msg.text:match("^v2|A|Match%-R|" .. seq .. "|(%a)$")
            if answer then
                return answer
            end
        end
    end

    it("is turned down, and taken when both take each other's language", function()
        assert.are.equal("C", answerTo(GERMAN_ONLY, ENGLISH_ONLY))
        assert.are.equal("C", answerTo(GERMAN_TAKES_ENGLISH, ENGLISH_ONLY))
        assert.are.equal("R", answerTo(GERMAN_TAKES_ENGLISH, ENGLISH_TAKES_GERMAN))
        assert.are.equal("R", answerTo(GERMAN_ONLY, nil))
    end)
end)

describe("languages in the game", function()
    local function lastQueueMessage(client)
        for i = #client.sent, 1, -1 do
            if client.sent[i]:find("^v2|Q|") then
                return client.sent[i]
            end
        end
    end

    it("are ticked in the settings, the own one always, and change the queued entry at once", function()
        local world = World.new()
        local client = world:addClient("Solo Dps", { level = 20 })
        world:advance(CONNECT)
        client:slash("/dq join dps dm")
        assert.are.equal("enUS:1", client.ns.engine.myEntry.language)
        client:slash("/fg settings")
        assert.is_not_nil(client:findText("^Languages you are matched with$"))
        local own = client:find("CheckButton", "English (your language)")
        assert.is_true(own.checked)
        assert.is_false(own.enabled)
        assert.is_nil(client:find("CheckButton", "Spanish"))
        assert.is_false(client:find("CheckButton", "German").checked)
        client:click("CheckButton", "German")
        assert.are.same({ deDE = true }, client.ns.db.languages)
        assert.are.equal("enUS:3", client.ns.engine.myEntry.language)
        assert.is_truthy(lastQueueMessage(client):find("|enUS:3$"))
        assert.are.equal("enUS:3", client.ns.questEngine.language)
        assert.are.equal("enUS:3", client.ns.bgEngine.language)
        client:click("CheckButton", "German")
        assert.is_nil(client.ns.db.languages)
        assert.are.equal("enUS:1", client.ns.engine.myEntry.language)
    end)

    it("fall back to a fixed list when the Group Finder does not tell, with the game's own first", function()
        local world = World.new()
        local client = world:addClient("Solo Dps", { level = 20, locale = "enGB" })
        world:advance(CONNECT)
        client.env.C_LFGList.GetAvailableLanguageSearchFilter = function()
            return {}
        end
        client:slash("/fg settings")
        assert.is_not_nil(client:find("CheckButton", "English (your language)"))
        for _, name in ipairs({ "German", "Spanish", "French", "Russian", "Portuguese" }) do
            assert.is_not_nil(client:find("CheckButton", name), name)
        end
    end)

    it("offer only languages Forever Groups knows, never more than the settings keep room for", function()
        local world = World.new()
        local client = world:addClient("Solo Dps", { level = 20, locale = "itIT" })
        world:advance(CONNECT)
        client.env.C_LFGList.GetAvailableLanguageSearchFilter = function()
            return { "enUS", "deDE", "koKR", "zhCN", "esES", "frFR", "ruRU", "ptBR", "zhTW" }
        end
        local offered = client.ns.MatchLanguages.offered()
        assert.are.same({ "itIT", "enUS", "deDE", "esES", "frFR", "ruRU", "ptBR" }, offered)
        assert.is_true(#offered <= client.ns.MatchLanguages.mostOffered())
    end)

    it("leave players out of the counts when you cannot be grouped with them", function()
        local world = World.new()
        local english = world:addClient("Solo Tank", { level = 20 })
        local german = world:addClient("Solo Heal", { level = 20, locale = "deDE" })
        world:advance(CONNECT)
        english:slash("/dq join tank dm")
        german:slash("/dq join heal dm")
        world:advance(2)
        local function healers()
            return english.ns.QueueWindow.lookingCounts({ ["5"] = true }).H
        end
        assert.are.equal("deDE:2", german.ns.engine.myEntry.language)
        assert.are.equal(0, healers())
        english.ns.MatchLanguages.set("deDE", true)
        assert.are.equal(0, healers())
        german.ns.MatchLanguages.set("enUS", true)
        world:advance(2)
        assert.are.equal(1, healers())
    end)
end)

describe("players of two game languages, end to end", function()
    local PLAYERS = {
        { "Tank Deutsch", "tank", "deDE" }, { "Heal English", "healer" }, { "Dps One", "dps" }, { "Dps Two", "dps" },
        { "Dps Three", "dps" },
    }

    local function queue(prepare)
        local world = World.new()
        local clients = {}
        for i, p in ipairs(PLAYERS) do
            clients[i] = world:addClient(p[1], { locale = p[3] })
        end
        world:advance(CONNECT)
        if prepare then
            prepare(clients)
        end
        for i, p in ipairs(PLAYERS) do
            clients[i]:slash("/dq join " .. p[2] .. " auto")
        end
        world:advance(20)
        return world, clients
    end

    local function proposed(client)
        local engine = client.ns.engine
        local proposal = engine.myProposalKey and engine.proposals[engine.myProposalKey]
        local names = {}
        for _, member in ipairs(proposal and proposal.members or {}) do
            names[member.name] = true
        end
        assert.is_not_nil(next(names), client.name .. " has no proposal")
        return names
    end

    it("leave a player of another language out of the group the others form", function()
        local _, clients = queue()
        assert.is_false(clients[1]:proposalShown())
        for i = 2, #clients do
            assert.is_true(clients[i]:proposalShown(), clients[i].name)
            assert.is_nil(proposed(clients[i])["Tank Deutsch"], clients[i].name)
        end
    end)

    it("are not grouped when only one side ticks the other's language", function()
        local _, clients = queue(function(all)
            all[1].ns.MatchLanguages.set("enUS", true)
        end)
        assert.is_false(clients[1]:proposalShown())
        assert.is_nil(proposed(clients[2])["Tank Deutsch"])
    end)

    it("are grouped when each ticks the other's language", function()
        local _, clients = queue(function(all)
            all[1].ns.MatchLanguages.set("enUS", true)
            for i = 2, #all do
                all[i].ns.MatchLanguages.set("deDE", true)
            end
        end)
        for _, client in ipairs(clients) do
            assert.is_true(client:proposalShown(), client.name)
            assert.is_true(proposed(client)["Tank Deutsch"], client.name)
        end
    end)
end)

describe("languages in a long questing queue entry", function()
    it("are left out when the entry would not fit with them, so the player still queues", function()
        local world = World.new()
        local client = world:addClient("Questy Mcquestface", { level = 20 })
        world:advance(CONNECT)
        local keys = {}
        for i = 1, 25 do
            keys[i] = tostring(10000 + i) .. "-3"
        end
        local ok = client.ns.QuestQueue.join(keys, { { name = client.ns.selfName, roles = "D", level = 20 } })
        assert.is_true(ok)
        assert.is_nil(client.ns.questEngine.myEntry.language)
        assert.is_true(client:said("Your languages do not fit in the queue message with this many quests"))
    end)
end)
