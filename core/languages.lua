local _, ns = ...
ns = ns or {}

-- Players are grouped by the language of their game, as in WoW's Group
-- Finder: everyone has their own language and the other languages they are
-- willing to be grouped with. On the wire it is one field of the queue
-- entry: "<own>:<mask>", the mask a bit per language of CODES that the owner
-- accepts ("deDE:3" is German, taking English and German players). An entry
-- without it (an older version) goes with everyone.
local Languages = {}

-- The bits on the wire follow this order: add new codes at the end only.
Languages.CODES = { "enUS", "deDE", "esES", "frFR", "ruRU", "ptBR" }

-- WoW's Group Finder lists these game languages under one of CODES.
local SAME_AS = { enGB = "enUS", esMX = "esES", ptPT = "ptBR" }

local MAX_MASK = 65535

local BIT = {}
for i, code in ipairs(Languages.CODES) do
    BIT[code] = 2 ^ (i - 1)
end

local function hasBit(mask, bit)
    return math.floor(mask / bit) % 2 == 1
end

function Languages.normalize(code)
    return SAME_AS[code] or code
end

function Languages.isKnown(code)
    return BIT[code] ~= nil
end

-- own: a code; accepts: a set of codes (own is always in it). nil when own
-- is not a known code: the entry then goes without the field.
function Languages.encode(own, accepts)
    if not BIT[own] then
        return nil
    end
    local mask = BIT[own]
    for code in pairs(accepts or {}) do
        if BIT[code] and code ~= own and accepts[code] then
            mask = mask + BIT[code]
        end
    end
    return own .. ":" .. mask
end

-- { code, accepts = set } or nil. Bits past CODES (languages of a later
-- version) are left out.
function Languages.decode(text)
    if type(text) ~= "string" then
        return nil
    end
    local own, mask = string.match(text, "^(%a%a%a%a):(%d+)$")
    mask = tonumber(mask)
    if not own or not BIT[own] or mask > MAX_MASK or not hasBit(mask, BIT[own]) then
        return nil
    end
    local accepts = {}
    for code, bit in pairs(BIT) do
        if hasBit(mask, bit) then
            accepts[code] = true
        end
    end
    return { code = own, accepts = accepts }
end

function Languages.isValid(text)
    return Languages.decode(text) ~= nil
end

local function view(value)
    if type(value) == "string" then
        return Languages.decode(value)
    end
    return value
end

-- Whether two players may be in one group: each takes the other's language.
-- a and b: wire texts or decoded; nil (unknown) goes with everyone.
function Languages.compatible(a, b)
    a, b = view(a), view(b)
    if not a or not b then
        return true
    end
    return a.accepts[b.code] == true and b.accepts[a.code] == true
end

-- Whether the entry goes with every entry of the list (each with a
-- `language`), as every pair in a group must.
function Languages.fitsAll(list, entry)
    for _, other in ipairs(list) do
        if not Languages.compatible(other.language, entry.language) then
            return false
        end
    end
    return true
end

ns.Languages = Languages
return Languages
