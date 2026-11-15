local _, ns = ...
ns = ns or {}

local Roles = ns.Roles or require("core.roles")
local Classes = ns.Classes or require("core.classes")

-- A leader's wishes for the classes in their group ("Compose your party"):
-- per place of a dungeon group (tank, healer, three DPS) the classes allowed
-- there, 0 for any class. Prefer mode lets anyone in after a while (`until`,
-- server time); 0 keeps the wishes for good. On the wire it is one field of
-- the queue entry: "<until>:<mask>.<mask>.<mask>.<mask>.<mask>".
local Compose = {}

Compose.CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
Compose.SLOT_ROLES = { "T", "H", "D", "D", "D" }

local BIT = {}
for i, class in ipairs(Compose.CLASSES) do
    BIT[class] = 2 ^ (i - 1)
end
local ALL = 2 ^ #Compose.CLASSES - 1

local function hasBit(mask, bit)
    return mask % (bit * 2) >= bit
end

function Compose.allows(mask, class)
    if mask == 0 then
        return true
    end
    return class ~= nil and BIT[class] ~= nil and hasBit(mask, BIT[class])
end

function Compose.maskOf(classes)
    local mask = 0
    for _, class in ipairs(classes) do
        if BIT[class] and not hasBit(mask, BIT[class]) then
            mask = mask + BIT[class]
        end
    end
    return mask
end

function Compose.classesOf(mask)
    local list = {}
    for _, class in ipairs(Compose.CLASSES) do
        if mask ~= 0 and hasBit(mask, BIT[class]) then
            list[#list + 1] = class
        end
    end
    return list
end

-- The classes that can play a place's role, in the order above.
function Compose.classesFor(role)
    local list = {}
    for _, class in ipairs(Compose.CLASSES) do
        if Classes.canPlay(class, role) then
            list[#list + 1] = class
        end
    end
    return list
end

local function anyWish(masks)
    for _, mask in ipairs(masks or {}) do
        if mask ~= 0 then
            return true
        end
    end
    return false
end

-- rules: { untilAt = server time or 0, masks = { one per place } }; nil
-- when no place has a wish.
function Compose.encode(rules)
    if not rules or not anyWish(rules.masks) then
        return nil
    end
    local parts = {}
    for i = 1, #Compose.SLOT_ROLES do
        parts[i] = tostring(math.floor(rules.masks[i] or 0))
    end
    return tostring(math.floor(rules.untilAt or 0)) .. ":" .. table.concat(parts, ".")
end

function Compose.decode(text)
    if type(text) ~= "string" then
        return nil
    end
    local untilText, rest = string.match(text, "^(%d+):([%d%.]+)$")
    if not untilText then
        return nil
    end
    local masks = {}
    for mask in string.gmatch(rest, "%d+") do
        masks[#masks + 1] = tonumber(mask)
    end
    if #masks ~= #Compose.SLOT_ROLES then
        return nil
    end
    for _, mask in ipairs(masks) do
        if mask > ALL then
            return nil
        end
    end
    local rules = { untilAt = tonumber(untilText), masks = masks }
    return anyWish(masks) and rules or nil
end

function Compose.isValid(text)
    return Compose.decode(text) ~= nil
end

-- The wishes still in force at `now`: prefer mode ends at untilAt.
function Compose.active(text, now)
    local rules = Compose.decode(text)
    if rules and (rules.untilAt == 0 or (type(now) == "number" and now < rules.untilAt)) then
        return rules
    end
    return nil
end

-- Gives each member a place of their own: places { { role, mask } },
-- members { { role or roles ("TD"), class or nil } }. A member takes a place
-- of a role they play whose mask allows their class (unknown class: only a
-- place for any class). Places with a wish are tried first, the strictest
-- (fewest classes) before the others, so the open ones stay free for players
-- whose class is not known and a Rogue does not take the "Mage or Rogue"
-- place while a "Rogue" one is free. Returns the place (index) of each
-- member, or nil when they don't all fit.
local function classCount(mask)
    if mask == 0 then
        return math.huge
    end
    local count = 0
    for _, class in ipairs(Compose.CLASSES) do
        if hasBit(mask, BIT[class]) then
            count = count + 1
        end
    end
    return count
end

local function match(places, members)
    local order = {}
    for i = 1, #places do
        order[i] = i
    end
    table.sort(order, function(a, b)
        local countA, countB = classCount(places[a].mask), classCount(places[b].mask)
        if countA ~= countB then
            return countA < countB
        end
        return a < b
    end)
    local taken, placed = {}, {}
    local function walk(index)
        if index > #members then
            return true
        end
        local member = members[index]
        local roles = member.roles or member.role or ""
        for _, at in ipairs(order) do
            local place = places[at]
            if not taken[at] and string.find(roles, place.role, 1, true)
                and Compose.allows(place.mask, member.class) then
                taken[at], placed[index] = true, at
                if walk(index + 1) then
                    return true
                end
                taken[at], placed[index] = nil, nil
            end
        end
        return false
    end
    if walk(1) then
        return placed
    end
    return nil
end

local function allPlaces(masks)
    local places = {}
    for slot, role in ipairs(Compose.SLOT_ROLES) do
        places[slot] = { slot = slot, role = role, mask = masks[slot] or 0 }
    end
    return places
end

-- members: { { role or roles, class } }. The place of each member, by index,
-- or nil.
function Compose.place(rules, members)
    return match(allPlaces(rules.masks), members)
end

function Compose.fits(rules, members)
    return match(allPlaces(rules.masks), members) ~= nil
end

-- Whether these members (picks still to come) all fit the free places
-- ({ { role, mask } }) left of a group.
function Compose.fitsPlaces(places, members)
    return match(places, members) ~= nil
end

-- One way to seat a leader's own group under their wishes, used for what
-- goes with the queue entry, the filler and the window alike, so they always
-- agree. people: the player and the party, each { role, class, slot }: a
-- remembered place (slot) is kept; otherwise a place of their role without a
-- wish, so they never use up a wish meant for someone still to come (a Mage
-- leader wishing for a Mage wants a second one); only then a wished place
-- their class fits, then any. coming: players on their way (invites still
-- out, players a formed group brought), { role, class }: matched with
-- `match`, a wished place their class fits first, the strictest first, as
-- that is what they were taken for. Returns { seats (place per person),
-- coming (place per player coming), wire (the masks with every place taken
-- set to 0: the matchmaker knows these players only by role), free (the
-- places left, { slot, role, mask }) }.
function Compose.seat(masks, people, coming)
    local taken, seats = {}, {}
    local function mask(slot)
        return masks[slot] or 0
    end
    for i, person in ipairs(people) do
        local slot = person.slot
        if slot and Compose.SLOT_ROLES[slot] == person.role and not taken[slot] then
            taken[slot], seats[i] = true, slot
        end
    end
    for i, person in ipairs(people) do
        if not seats[i] then
            local chosen
            for _, wanted in ipairs({ "open", "fits", "any" }) do
                for slot, role in ipairs(Compose.SLOT_ROLES) do
                    if not chosen and not taken[slot] and role == person.role
                        and ((wanted == "open" and mask(slot) == 0)
                            or (wanted == "fits" and Compose.allows(mask(slot), person.class))
                            or wanted == "any") then
                        chosen = slot
                    end
                end
            end
            if chosen then
                taken[chosen], seats[i] = true, chosen
            end
        end
    end
    local left = {}
    for _, place in ipairs(allPlaces(masks)) do
        if not taken[place.slot] then
            left[#left + 1] = place
        end
    end
    local comingSeats = {}
    local placed = match(left, coming)
    if placed then
        for i, at in pairs(placed) do
            taken[left[at].slot], comingSeats[i] = true, left[at].slot
        end
    else
        -- The wishes changed after inviting: a player coming still takes a
        -- place of their role, so it is not filled twice over.
        for i, player in ipairs(coming) do
            for _, place in ipairs(left) do
                if not taken[place.slot] and place.role == player.role then
                    taken[place.slot], comingSeats[i] = true, place.slot
                    break
                end
            end
        end
    end
    local wire, free = {}, {}
    for slot, role in ipairs(Compose.SLOT_ROLES) do
        wire[slot] = taken[slot] and 0 or mask(slot)
        if not taken[slot] then
            free[#free + 1] = { slot = slot, role = role, mask = mask(slot) }
        end
    end
    return { seats = seats, coming = comingSeats, wire = wire, free = free }
end

-- Whether every place of the group can get a player at all: each place a
-- different one of these members (each { roles, class }) whose roles include
-- the place's and whose class the place allows. A quick test before a
-- search: a wish for a class nobody in the queue plays fails it at once.
function Compose.canFill(rules, members)
    local owner = {}
    local function augment(slot, seen)
        for index, member in ipairs(members) do
            if not seen[index] and string.find(member.roles or member.role or "", Compose.SLOT_ROLES[slot], 1, true)
                and Compose.allows(rules.masks[slot] or 0, member.class) then
                seen[index] = true
                local current
                for other, holder in pairs(owner) do
                    if holder == index then
                        current = other
                    end
                end
                -- A member who holds another place may move when that place can
                -- get someone else (augment fills it again).
                if not current or augment(current, seen) then
                    owner[slot] = index
                    return true
                end
            end
        end
        return false
    end
    for slot = 1, #Compose.SLOT_ROLES do
        if not augment(slot, {}) then
            return false
        end
    end
    return true
end

-- The roles of `roles` a player of this class could still take at all.
function Compose.rolesFor(rules, class, roles)
    local result = ""
    for _, role in ipairs(Roles.ORDER) do
        if Roles.has(roles, role) then
            for slot, slotRole in ipairs(Compose.SLOT_ROLES) do
                if slotRole == role and Compose.allows(rules.masks[slot], class) then
                    result = result .. role
                    break
                end
            end
        end
    end
    return result
end

ns.Compose = Compose
return Compose
