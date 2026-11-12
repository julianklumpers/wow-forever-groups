local _, ns = ...
ns = ns or {}

-- A player's roles are a string of role letters in T, H, D order: "D", "TD",
-- "THD". In a proposal every member has exactly one assigned role.
local Roles = {}

Roles.ORDER = { "T", "H", "D" }
local VALID = { T = true, H = true, D = true }

-- Returns the normalized string ("DT" -> "TD"), or nil when invalid.
function Roles.normalize(text)
    if type(text) ~= "string" or text == "" then
        return nil
    end
    local seen = {}
    for i = 1, #text do
        local letter = string.sub(text, i, i)
        if not VALID[letter] or seen[letter] then
            return nil
        end
        seen[letter] = true
    end
    local result = ""
    for _, role in ipairs(Roles.ORDER) do
        if seen[role] then
            result = result .. role
        end
    end
    return result
end

function Roles.has(roles, role)
    return string.find(roles, role, 1, true) ~= nil
end

local function key(counts)
    return counts.T .. ":" .. counts.H .. ":" .. counts.D
end

-- Every distinct role composition the members can take within the slots,
-- each with one concrete assignment. Earlier members get the earlier role in
-- T, H, D order when several assignments give the same composition.
function Roles.options(members, slots)
    local options, seen = {}, {}
    local assignment = {}
    local counts = { T = 0, H = 0, D = 0 }
    local function walk(index)
        if index > #members then
            local k = key(counts)
            if not seen[k] then
                seen[k] = true
                local copy = {}
                for i, role in ipairs(assignment) do
                    copy[i] = role
                end
                options[#options + 1] = { counts = { T = counts.T, H = counts.H, D = counts.D }, assignment = copy }
            end
            return
        end
        for _, role in ipairs(Roles.ORDER) do
            if Roles.has(members[index].roles, role) and counts[role] < slots[role] then
                counts[role] = counts[role] + 1
                assignment[index] = role
                walk(index + 1)
                counts[role] = counts[role] - 1
            end
        end
    end
    walk(1)
    return options
end

-- How many members could play each role (a flexible member counts for each).
function Roles.supply(members)
    local supply = { T = 0, H = 0, D = 0 }
    for _, member in ipairs(members) do
        for _, role in ipairs(Roles.ORDER) do
            if Roles.has(member.roles, role) then
                supply[role] = supply[role] + 1
            end
        end
    end
    return supply
end

-- The members plus one placeholder per reserved role letter, for roles a
-- party has already invited someone for from WoW's Group Finder.
function Roles.withReserved(members, reserved)
    local all = {}
    for i, member in ipairs(members) do
        all[i] = member
    end
    for letter in string.gmatch(reserved or "", ".") do
        all[#all + 1] = { roles = letter, reserved = true }
    end
    return all
end

-- "HDD" -> { T = 0, H = 1, D = 2 }; nil when the string has other letters.
function Roles.countLetters(text)
    if type(text) ~= "string" or string.find(text, "[^THD]") then
        return nil
    end
    local counts = { T = 0, H = 0, D = 0 }
    for letter in string.gmatch(text, ".") do
        counts[letter] = counts[letter] + 1
    end
    return counts
end

function Roles.fromCounts(counts)
    return string.rep("T", counts.T) .. string.rep("H", counts.H) .. string.rep("D", counts.D)
end

ns.Roles = Roles
return Roles
