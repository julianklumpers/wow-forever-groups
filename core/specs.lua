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
