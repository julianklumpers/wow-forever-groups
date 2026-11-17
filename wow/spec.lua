local _, ns = ...

local Specs = ns.Specs
local Log = ns.Log

-- The player's spec: the talent tree with the most points, read from
-- Forever's talent tree. It ticks the matching roles when the spec changes,
-- warns when the queued roles fit none of it, and is named in whispers, the
-- proposal popup and the group's places.
local Spec = {}

local cached
local dirty = true
-- Specs of other players, from the proposals they were in this session.
local known = {}
-- Their points per tree, where inspecting told them.
local pointsKnown = {}
-- Who this session learned a spec of (inspected or shared), not kept over a
-- /reload.
local learnedNow = {}
-- Next to the tree with the most points, another counts in a hybrid spec
-- ("Shadow/Holy") with at least this share of all points: a level 20 player
-- has only 11 points.
local HYBRID_SHARE = 1 / 3

local function isSecret(value)
    if canaccessvalue ~= nil then
        return not canaccessvalue(value)
    end
    return issecretvalue ~= nil and issecretvalue(value) == true
end

local function number(value)
    if value == nil or isSecret(value) or type(value) ~= "number" then
        return nil
    end
    return value
end

-- Points spent per tree { n1, n2, n3 } in a talent config (the player's,
-- or the inspected player's), or nil when the client does not tell; second,
-- what WoW gave, for the log: "2 trees, 31 nodes, 0 ranks".
function Spec.pointsOf(configID)
    if not number(configID) or not (C_Traits and C_Traits.GetConfigInfo and C_Traits.GetTreeNodes) then
        return nil
    end
    local infoOk, info = pcall(C_Traits.GetConfigInfo, configID)
    if not infoOk or type(info) ~= "table" or type(info.treeIDs) ~= "table" then
        return nil
    end
    local points, nodeCount, rankCount = { 0, 0, 0 }, 0, 0
    for _, treeID in ipairs(info.treeIDs) do
        local nodesOk, nodes = pcall(C_Traits.GetTreeNodes, treeID)
        for _, nodeID in ipairs(nodesOk and type(nodes) == "table" and nodes or {}) do
            local nodeOk, node = pcall(C_Traits.GetNodeInfo, configID, nodeID)
            if nodeOk and type(node) == "table" then
                nodeCount = nodeCount + 1
                local ranks = number(node.ranksPurchased) or 0
                local tree = Specs.treeForX(number(node.posX))
                if tree and points[tree] and ranks > 0 then
                    points[tree] = points[tree] + ranks
                    rankCount = rankCount + ranks
                end
            end
        end
    end
    return points, string.format("%d trees, %d nodes, %d ranks", #info.treeIDs, nodeCount, rankCount)
end

-- The last points WoW gave: it does not always give them (no active config
-- for a moment), and the spec does not change in between.
local lastPoints

function Spec.points()
    if not (C_ClassTalents and C_ClassTalents.GetActiveConfigID) then
        return lastPoints
    end
    local ok, configID = pcall(C_ClassTalents.GetActiveConfigID)
    local points = ok and Spec.pointsOf(configID) or nil
    lastPoints = points or lastPoints
    return lastPoints
end

-- Other players' specs are saved per character, so a /reload keeps what
-- this session learned: { [name] = { spec, points, class, at } }, each for
-- KEEP_SPECS seconds after it was last learned.
local KEEP_SPECS = 4 * 3600
local loaded = false

local function savedSpecs()
    if not ns.charDb then
        return nil
    end
    ns.charDb.knownSpecs = type(ns.charDb.knownSpecs) == "table" and ns.charDb.knownSpecs or {}
    return ns.charDb.knownSpecs
end

local function load()
    local saved = savedSpecs()
    if loaded or not saved then
        return
    end
    loaded = true
    local now = GetServerTime()
    for name, entry in pairs(saved) do
        if type(entry) ~= "table" or now - (tonumber(entry.at) or 0) > KEEP_SPECS then
            saved[name] = nil
        else
            known[name] = known[name] or entry.spec
            if not pointsKnown[name] and entry.class and type(entry.points) == "table" then
                pointsKnown[name] = { classToken = entry.class, points = entry.points }
            end
        end
    end
end

local function save(name)
    local saved = savedSpecs()
    if not saved or not name then
        return
    end
    local points = pointsKnown[name]
    saved[name] = { spec = known[name], class = points and points.classToken, points = points and points.points,
        at = GetServerTime() }
end

-- A party member's spec, from inspecting their talents or their message.
function Spec.learn(name, classToken, points)
    load()
    local index = points and Specs.dominant(points)
    local code = index and Specs.encode(classToken, index)
    local spent = type(points) == "table" and ((points[1] or 0) + (points[2] or 0) + (points[3] or 0)) or 0
    if name and type(classToken) == "string" and spent > 0 then
        -- A tie (6/6/0) has no single spec but still its trees. No points
        -- at all is also what an inspect gives before WoW has the data.
        known[name] = code
        learnedNow[name] = true
        pointsKnown[name] = { classToken = classToken, points = { points[1] or 0, points[2] or 0, points[3] or 0 } }
        save(name)
    end
    return code
end

-- The tree with the most points and any other with at least HYBRID_SHARE of
-- all points, most points first, as their names ("Shadow/Holy", "Holy"); nil
-- when the points are not known (only the main tree came with the queue, or
-- nobody inspected them yet) or none are spent.
function Spec.treesOf(name)
    load()
    local classToken, points
    if name == ns.selfName then
        classToken, points = ns.Party.playerClass(), Spec.points()
    elseif pointsKnown[name] then
        classToken, points = pointsKnown[name].classToken, pointsKnown[name].points
    end
    if not classToken or type(points) ~= "table" then
        return nil
    end
    local total, most = 0, 0
    for index = 1, 3 do
        total = total + (points[index] or 0)
        most = math.max(most, points[index] or 0)
    end
    if most == 0 then
        return nil
    end
    local trees = {}
    for index = 1, 3 do
        local spent = points[index] or 0
        local tree = spent > 0 and (spent == most or spent >= total * HYBRID_SHARE) and Specs.tree(classToken, index)
        if tree then
            trees[#trees + 1] = { name = tree.name, points = spent, index = index }
        end
    end
    table.sort(trees, function(a, b)
        if a.points ~= b.points then
            return a.points > b.points
        end
        return a.index < b.index
    end)
    local names = {}
    for i, tree in ipairs(trees) do
        names[i] = tree.name
    end
    return names
end

local function classToken()
    return ns.Party.playerClass()
end

-- { index, name, roles, class } for the player, or nil (no talents yet, a
-- tie, or a class without known trees).
function Spec.current()
    if dirty then
        dirty = false
        local points = Spec.points()
        local index = points and Specs.dominant(points)
        local tree = index and Specs.tree(classToken(), index)
        cached = tree and { index = index, name = tree.name, roles = tree.roles, class = classToken() } or nil
        if points then
            Log.debug("talent points per tree: %d / %d / %d -> %s", points[1], points[2], points[3],
                cached and cached.name or "no spec")
        end
    end
    return cached
end

-- The code sent in the queue entry ("SHAMAN2"), or the class alone.
function Spec.code()
    local spec = Spec.current()
    return Specs.encode(classToken(), spec and spec.index)
end

local function englishClass(token)
    return token and (token:sub(1, 1) .. token:sub(2):lower()) or nil
end

-- In the player's language, for the screen.
local function className(token)
    if not token then
        return nil
    end
    local names = LOCALIZED_CLASS_NAMES_MALE
    return (names and names[token]) or englishClass(token)
end

-- "Enhancement Shaman" from a spec code, or the class name alone; English,
-- for whispers.
function Spec.label(code)
    local token, index = Specs.decode(code)
    if not token then
        return nil
    end
    local tree = Specs.tree(token, index)
    return tree and (tree.name .. " " .. englishClass(token)) or englishClass(token)
end

-- A spec code's label as played in a role: the spec itself when it plays
-- the role, else the tree the class plays the role with (a Feral druid
-- healing is a Restoration Druid), the class alone when several could.
-- For the player's own screen: the spec's name in their language.
function Spec.labelInRole(code, role)
    local token, index = Specs.decode(code)
    local look = token and role and Specs.forRole(token, role, index)
    local name = look and look.name
    if not look then
        local tree = token and Specs.tree(token, index)
        name = tree and tree.name
    end
    if not token then
        return nil
    end
    return name and (ns.L[name] .. " " .. className(token)) or className(token)
end

-- "Enhancement Shaman", the class alone, or nil when even that is unknown.
-- With roles ("H", "HD"): when the current spec plays none of them, the spec
-- the player plays the first one in (a Feral druid looking as healer is a
-- Restoration Druid), or the class alone when the class has several.
function Spec.myLabel(roles)
    local current = Spec.current()
    local fits = false
    for letter in string.gmatch(type(roles) == "string" and roles or "", "[THD]") do
        fits = fits or (current ~= nil and string.find(current.roles, letter, 1, true) ~= nil)
    end
    if type(roles) == "string" and roles ~= "" and not fits then
        local token = classToken()
        for letter in string.gmatch(roles, "[THD]") do
            local spec = Specs.forRole(token, letter, current and current.index)
            if spec then
                return spec.name and (spec.name .. " " .. englishClass(token)) or englishClass(token)
            end
        end
    end
    return Spec.label(Spec.code()) or englishClass(classToken())
end


function Spec.remember(view)
    load()
    for _, member in ipairs(view and view.members or {}) do
        if member.spec then
            known[member.name] = member.spec
            save(member.name)
        end
    end
end

-- The tree number of a player's spec (the player's own or one learned), or nil.
function Spec.indexOf(name)
    if name == ns.selfName then
        local spec = Spec.current()
        return spec and spec.index
    end
    load()
    local _, index = Specs.decode(known[name])
    return index
end

function Spec.className(token)
    return className(token)
end

-- In English, for messages other players read ("Warlock").
function Spec.englishClass(token)
    return englishClass(token)
end

function Spec.learnedThisSession(name)
    return learnedNow[name] == true
end

-- The tree name for one of the group's places ("Enhancement"), or nil.
function Spec.treeOf(name)
    if name == ns.selfName then
        local spec = Spec.current()
        return spec and spec.name
    end
    load()
    local token, index = Specs.decode(known[name])
    local tree = token and Specs.tree(token, index)
    return tree and tree.name
end

-- When the dominant tree changes (or the first time), its roles are ticked;
-- after that the player's own ticks stay.
local function onTalentsChanged()
    dirty = true
    Spec.shareSoon(false)
    for _, engine in ipairs(ns.Queues.engines()) do
        engine:setSpec(Spec.code())
    end
    local spec = Spec.current()
    if not spec or not ns.charDb or ns.charDb.specIndex == spec.index then
        return
    end
    ns.charDb.specIndex = spec.index
    ns.charDb.lastRoles = ns.Classes.filter(spec.roles, classToken()) or ns.charDb.lastRoles
    Log.debug("spec is now %s; ticked %s", spec.name, tostring(ns.charDb.lastRoles))
    if ns.Window then
        ns.Window.refresh()
    end
end

-- Warns once per queue join when none of the queued roles fits the spec.
function Spec.checkRoles(roles)
    local spec = Spec.current()
    if not spec or not roles then
        return
    end
    for letter in string.gmatch(roles, ".") do
        if string.find(spec.roles, letter, 1, true) then
            return
        end
    end
    Log.warn("You queue as %s, but most of your talents are in %s.", ns.Widgets.describeRoles(roles), spec.name)
end

-- Party members with Forever Groups tell each other their points per tree
-- over the PARTY addon channel (inspecting gives nothing on Forever as of
-- 2026-11): "v1|SP|<class>|<points>/<points>/<points>".
local PARTY_PREFIX = "v1|SP|"
local SHARE_DELAY = 2
local sharedText
local shareScheduled = false

local function shareText()
    local points, class = Spec.points(), classToken()
    if type(points) ~= "table" or not class or not Specs.TREES[class] then
        return nil
    end
    return string.format("%s%s|%d/%d/%d", PARTY_PREFIX, class, points[1] or 0, points[2] or 0, points[3] or 0)
end

-- force: the party changed, so a newcomer gets it even when it is the same.
function Spec.shareSoon(force)
    if force then
        sharedText = nil
    end
    if shareScheduled then
        return
    end
    shareScheduled = true
    C_Timer.After(SHARE_DELAY, function()
        shareScheduled = false
        local text = IsInGroup() and shareText()
        if text and text ~= sharedText then
            if ns.Comm.sendParty(text) then
                sharedText = text
            else
                Spec.shareSoon(false)
            end
        end
    end)
end

-- From the PARTY addon channel; returns true when the message was ours.
function Spec.onMessage(sender, text)
    if string.sub(text, 1, #PARTY_PREFIX) ~= PARTY_PREFIX then
        return false
    end
    local class, a, b, c = string.match(text, "^v1|SP|(%u+)|(%d+)/(%d+)/(%d+)$")
    a, b, c = tonumber(a), tonumber(b), tonumber(c)
    if class and Specs.TREES[class] and a <= 100 and b <= 100 and c <= 100 then
        Spec.learn(sender, class, { a, b, c })
        if ns.Window then
            ns.Window.refresh()
        end
    end
    return true
end

function Spec.init()
    -- Again for a newcomer only: roster updates also come with every role
    -- change and member going offline.
    local members
    ns.on("GROUP_ROSTER_UPDATE", function()
        local list = ns.Party.members()
        if not list and IsInGroup() then
            return
        end
        local names = {}
        for _, member in ipairs(list or {}) do
            names[#names + 1] = member.name
        end
        table.sort(names)
        local now = table.concat(names, ",")
        Spec.shareSoon(now ~= members)
        members = now
    end)
    for _, event in ipairs({ "PLAYER_LOGIN", "TRAIT_CONFIG_UPDATED", "PLAYER_TALENT_UPDATE",
        "ACTIVE_PLAYER_SPECIALIZATION_CHANGED", "PLAYER_LEVEL_UP" }) do
        ns.on(event, onTalentsChanged)
    end
end

ns.Spec = Spec
