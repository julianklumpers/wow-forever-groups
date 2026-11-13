local _, ns = ...
ns = ns or {}

-- The three Classic talent trees of each class and the roles each one plays.
-- Forever shows them side by side in one talent tree, in this order, so a
-- talent's column (its x position) tells its tree; the tree with the most
-- points is the player's spec. A spec only informs (whispers, the popup, the
-- card, the role ticked by default); matchmaking never uses it.
local Specs = {}

-- Tree columns in Forever's talent tree (NyteLytePaladinToolkit's probe:
-- x ~1000-2800, ~5000-6800, ~9000-10900).
Specs.COLUMN_BOUNDS = { 4000, 8000 }

Specs.TREES = {
    WARRIOR = { { "Arms", "D" }, { "Fury", "D" }, { "Protection", "T" } },
    PALADIN = { { "Holy", "H" }, { "Protection", "T" }, { "Retribution", "D" } },
    HUNTER = { { "Beast Mastery", "D" }, { "Marksmanship", "D" }, { "Survival", "D" } },
    ROGUE = { { "Assassination", "D" }, { "Combat", "D" }, { "Subtlety", "D" } },
    PRIEST = { { "Discipline", "H" }, { "Holy", "H" }, { "Shadow", "D" } },
    SHAMAN = { { "Elemental", "D" }, { "Enhancement", "D" }, { "Restoration", "H" } },
    MAGE = { { "Arcane", "D" }, { "Fire", "D" }, { "Frost", "D" } },
    WARLOCK = { { "Affliction", "D" }, { "Demonology", "D" }, { "Destruction", "D" } },
    DRUID = { { "Balance", "D" }, { "Feral", "TD" }, { "Restoration", "H" } },
}

-- Per tree: the retail spec art (atlas spec-thumbnail-<class>-<name>).
-- Feral as a tank shows the guardian (bear) art.
Specs.ART = {
    WARRIOR = { "arms", "fury", "protection" },
    PALADIN = { "holy", "protection", "retribution" },
    HUNTER = { "beastmastery", "marksmanship", "survival" },
    ROGUE = { "assassination", "outlaw", "subtlety" },
    PRIEST = { "discipline", "holy", "shadow" },
    SHAMAN = { "elemental", "enhancement", "restoration" },
    MAGE = { "arcane", "fire", "frost" },
    WARLOCK = { "affliction", "demonology", "destruction" },
    DRUID = { "balance", "feral", "restoration" },
}
Specs.TANK_ART = { DRUID = "guardian" }
-- How a class looks in a role: the tree it plays the role with (the current
-- one if it fits, else the first that does), its art and name. The
-- name only when that tree is certain: the current one, or the only one for
-- the role. nil when the class cannot play the role.
function Specs.forRole(classToken, role, current)
    local trees = Specs.TREES[classToken]
    if not trees then
        return nil
    end
    local index, count = nil, 0
    for i, tree in ipairs(trees) do
        if string.find(tree[2], role, 1, true) then
            count = count + 1
            index = index or i
        end
    end
    if not index then
        return nil
    end
    if current and trees[current] and string.find(trees[current][2], role, 1, true) then
        index = current
    end
    return {
        index = index,
        atlas = Specs.artFor(classToken, index, role),
        name = (count == 1 or index == current) and trees[index][1] or nil,
    }
end

-- The spec art atlas of a class's tree, as played in a role (Feral as a
-- tank shows the guardian art), or nil.
function Specs.artFor(classToken, index, role)
    local names = Specs.ART[classToken]
    if not names or not names[index] then
        return nil
    end
    local tank = role == "T" and string.find(Specs.TREES[classToken][index][2], "T", 1, true)
    local art = tank and Specs.TANK_ART[classToken] or names[index]
    return "spec-thumbnail-" .. string.lower(classToken) .. "-" .. art
end

function Specs.treeForX(x)
    if type(x) ~= "number" then
        return nil
    end
    for i, bound in ipairs(Specs.COLUMN_BOUNDS) do
        if x < bound then
            return i
        end
    end
    return #Specs.COLUMN_BOUNDS + 1
end

-- The tree with the most points ({ n1, n2, n3 }), or nil without points or
-- on a tie for the most.
function Specs.dominant(points)
    local best, bestPoints, tie = nil, 0, false
    for i = 1, 3 do
        local n = points[i] or 0
        if n > bestPoints then
            best, bestPoints, tie = i, n, false
        elseif n == bestPoints and n > 0 then
            tie = true
        end
    end
    return not tie and best or nil
end

function Specs.tree(classToken, index)
    local trees = Specs.TREES[classToken]
    local tree = trees and trees[index]
    return tree and { name = tree[1], roles = tree[2] } or nil
end

-- A spec code for the wire: class token plus tree number ("SHAMAN2"); the
-- class alone when the tree is unknown.
function Specs.encode(classToken, index)
    if type(classToken) ~= "string" or not Specs.TREES[classToken] then
        return nil
    end
    return classToken .. (Specs.tree(classToken, index) and index or "")
end

function Specs.decode(code)
    local classToken, index = string.match(code or "", "^(%u+)(%d?)$")
    if not classToken or not Specs.TREES[classToken] then
        return nil
    end
    index = tonumber(index)
    return classToken, Specs.tree(classToken, index) and index or nil
end

ns.Specs = Specs
return Specs
