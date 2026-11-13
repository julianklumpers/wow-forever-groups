local _, ns = ...

local Specs = ns.Specs
local Log = ns.Log

-- The player's spec: the talent tree with the most points, read from
-- Forever's talent tree. It ticks the matching roles when the spec changes,
-- warns when the queued roles fit none of it, and is named in whispers, the
-- proposal popup and the group card.
local Spec = {}

local cached
local dirty = true
-- Specs of other players, from the proposals they were in this session.
local known = {}

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
-- or the inspected player's), or nil when the client does not tell.
function Spec.pointsOf(configID)
    if not number(configID) or not (C_Traits and C_Traits.GetConfigInfo and C_Traits.GetTreeNodes) then
        return nil
    end
    local infoOk, info = pcall(C_Traits.GetConfigInfo, configID)
    if not infoOk or type(info) ~= "table" or type(info.treeIDs) ~= "table" then
        return nil
    end
    local points = { 0, 0, 0 }
    for _, treeID in ipairs(info.treeIDs) do
        local nodesOk, nodes = pcall(C_Traits.GetTreeNodes, treeID)
        for _, nodeID in ipairs(nodesOk and type(nodes) == "table" and nodes or {}) do
            local nodeOk, node = pcall(C_Traits.GetNodeInfo, configID, nodeID)
            if nodeOk and type(node) == "table" then
                local ranks = number(node.ranksPurchased) or 0
                local tree = Specs.treeForX(number(node.posX))
                if tree and points[tree] and ranks > 0 then
                    points[tree] = points[tree] + ranks
                end
            end
        end
    end
    return points
end

function Spec.points()
    if not (C_ClassTalents and C_ClassTalents.GetActiveConfigID) then
        return nil
    end
    local ok, configID = pcall(C_ClassTalents.GetActiveConfigID)
    return ok and Spec.pointsOf(configID) or nil
end

-- A party member's spec, from inspecting their talents.
function Spec.learn(name, classToken, points)
    local index = points and Specs.dominant(points)
    local code = index and Specs.encode(classToken, index)
    if name and code then
        known[name] = code
    end
    return code
end

local function classToken()
    local _, token = UnitClass("player")
    return token
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
    for _, member in ipairs(view and view.members or {}) do
        if member.spec then
            known[member.name] = member.spec
        end
    end
end

-- The tree number of a player's spec (the player's own or one learned), or nil.
function Spec.indexOf(name)
    if name == ns.selfName then
        local spec = Spec.current()
        return spec and spec.index
    end
    local _, index = Specs.decode(known[name])
    return index
end

function Spec.className(token)
    return className(token)
end

-- The tree name for a group card slot ("Enhancement"), or nil.
function Spec.treeOf(name)
    if name == ns.selfName then
        local spec = Spec.current()
        return spec and spec.name
    end
    local token, index = Specs.decode(known[name])
    local tree = token and Specs.tree(token, index)
    return tree and tree.name
end

-- When the dominant tree changes (or the first time), its roles are ticked;
-- after that the player's own ticks stay.
local function onTalentsChanged()
    dirty = true
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

function Spec.init()
    for _, event in ipairs({ "PLAYER_LOGIN", "TRAIT_CONFIG_UPDATED", "PLAYER_TALENT_UPDATE",
        "ACTIVE_PLAYER_SPECIALIZATION_CHANGED", "PLAYER_LEVEL_UP" }) do
        ns.on(event, onTalentsChanged)
    end
end

ns.Spec = Spec
