local _, ns = ...

local Compose = ns.Compose

-- "Choose the classes in my party" on the Dungeons tab: the classes a leader wants per
-- place (core/compose.lua), kept per character (charDb.compose). They count
-- while the player builds the group (party leader, or alone wishing to lead):
-- they go with the dungeon queue entry, and the filler only invites players
-- whose class has a free place. They hold for as long as the queue entry
-- does (untilAt 0).
local PartyCompose = {}

function PartyCompose.settings()
    local saved = ns.charDb.compose
    if type(saved) ~= "table" or type(saved.masks) ~= "table" then
        saved = { masks = { 0, 0, 0, 0, 0 } }
        ns.charDb.compose = saved
    end
    return saved
end

function PartyCompose.hasWishes()
    for _, mask in ipairs(PartyCompose.settings().masks) do
        if mask ~= 0 then
            return true
        end
    end
    return false
end

-- Whether the player builds the group: they lead the party, or are alone and
-- would like to lead.
function PartyCompose.isBuilder()
    local state = ns.Party.state()
    return state == "leader" or (state == "solo" and ns.charDb.wantsLead == true)
end

local function firstRole(roles)
    for _, role in ipairs({ "T", "H", "D" }) do
        if roles and string.find(roles, role, 1, true) then
            return role
        end
    end
    return "D"
end

-- The player and these party members, each with the one role they play: the
-- role agreed for them when there is one, else the way the filler shares the
-- roles out (Filler.missingFor: the scarcest places first), so the places
-- here are the ones the filler leaves open.
local function seated(partyMembers)
    local roles = ns.WindowParts and ns.WindowParts.selectedRoles and ns.WindowParts.selectedRoles()
    local class = ns.Party.playerClass()
    local people = { { name = ns.selfName, class = class, self = true,
        roles = roles or ns.Classes.allowed(class) } }
    for _, member in ipairs(partyMembers or {}) do
        people[#people + 1] = { name = member.name, class = member.classToken,
            roles = ns.PartyRoles.rolesOf(member) }
    end
    for _, person in ipairs(people) do
        local agreed = ns.RoleSync.expected(person.name)
        if agreed and string.find(person.roles, agreed, 1, true) then
            person.roles = agreed
        end
    end
    local _, assignment = ns.Filler.missingFor(people)
    for i, person in ipairs(people) do
        person.role = assignment and assignment[i] or firstRole(person.roles)
    end
    return people
end

function PartyCompose.masks()
    return PartyCompose.settings().masks
end

-- Where each player of the group sits, by name (charDb.composeSeats): a
-- player invited for a place keeps it once they join, also after a /reload.
local function seatMemory()
    local saved = ns.charDb.composeSeats
    if type(saved) ~= "table" then
        saved = {}
        ns.charDb.composeSeats = saved
    end
    return saved
end

-- The players on their way: those a formed queue group brought (their class
-- from their queue entry) and the invites still out.
local function comingPlayers()
    local list = {}
    for _, player in ipairs(ns.Group.expectedPlayers()) do
        local entry = ns.engine and ns.engine.queue:get(player.name)
        list[#list + 1] = { name = player.name, role = player.role,
            class = player.class or (entry and (ns.Specs.decode(entry.spec))) or nil }
    end
    for _, invite in ipairs(ns.Filler.pendingPlaces()) do
        list[#list + 1] = invite
    end
    return list
end

-- Seats the player, these party members and (for the real group) those on
-- their way under the wishes in use (Compose.seat). remember: keep where
-- everyone sits for next time.
local function seatGroup(members, coming, remember)
    local memory = seatMemory()
    local people = seated(members)
    for _, person in ipairs(people) do
        person.slot = not person.self and memory[person.name] or nil
    end
    local seat = Compose.seat(PartyCompose.masks(), people, coming)
    seat.people = people
    if remember then
        local kept = {}
        for i, person in ipairs(people) do
            if not person.self and seat.seats[i] then
                kept[person.name] = seat.seats[i]
            end
        end
        for i, player in ipairs(coming) do
            if seat.coming[i] then
                kept[player.name] = seat.coming[i]
            end
        end
        ns.charDb.composeSeats = kept
    end
    return seat
end

-- The group as the leader builds it, seated once for everything (the queue
-- entry, the filler, applicants, whispers, Who is looking, the window's
-- cards). nil when the player does not build the group; nil, true while a
-- party member's name is still loading (keep what was sent).
local function layout()
    if not ns.PartyLevels.wishesCount("dungeons") then
        return nil
    end
    local members = ns.Party.members()
    if not members then
        return nil, true
    end
    return seatGroup(members, comingPlayers(), true)
end

-- The players already in the group in their places: { [place] = { name,
-- class, self } }. Their places carry no wish.
function PartyCompose.fixed()
    local seat = seatGroup(ns.Party.members() or {}, {}, false)
    local fixed = {}
    for i, person in ipairs(seat.people) do
        if seat.seats[i] then
            fixed[seat.seats[i]] = person
        end
    end
    return fixed
end

-- The chosen classes for the places still open, also while switched off (the
-- window's cards).
function PartyCompose.chosenMasks()
    local saved, fixed, masks = PartyCompose.settings(), PartyCompose.fixed(), {}
    for slot = 1, #Compose.SLOT_ROLES do
        masks[slot] = fixed[slot] and 0 or (saved.masks[slot] or 0)
    end
    return masks
end

-- The wishes as they go with the queue entry: every place already taken
-- without a wish. nil without wishes left or when the player does not build
-- the group; nil, true while a name is loading.
function PartyCompose.wireText()
    local seat, loading = layout()
    if not seat then
        return nil, loading
    end
    return Compose.encode({ untilAt = 0, masks = seat.wire })
end

-- Sets the classes for a place (an empty list: any class).
function PartyCompose.setClasses(slot, classes)
    PartyCompose.settings().masks[slot] = Compose.maskOf(classes)
    PartyCompose.apply()
end

-- Back to any class everywhere (the switch stays as it is).
function PartyCompose.reset()
    ns.charDb.compose = nil
    PartyCompose.apply()
end

-- Puts the wishes on the dungeon queue entry (or on the next one); while a
-- name is loading the entry keeps what it has.
function PartyCompose.apply()
    local text, loading = PartyCompose.wireText()
    if ns.engine and not loading then
        ns.engine:setCompose(text)
    end
end

-- The places still free for new players, { { slot, role, mask } }, from the
-- same seating as the queue entry; nil when no free place has a wish (any
-- player of the role fits).
function PartyCompose.freePlaces()
    local seat = layout()
    if not seat then
        return nil
    end
    for _, place in ipairs(seat.free) do
        if place.mask ~= 0 then
            return seat.free
        end
    end
    return nil
end

-- Whether these new players ({ { role or roles, class } }) all fit the free
-- places under the wishes; true without wishes.
function PartyCompose.fits(members)
    local places = PartyCompose.freePlaces()
    return not places or Compose.fitsPlaces(places, members)
end

-- For the listing and the status: "Mage", "Rogue/Warrior" per place with a
-- wish, in English (the listing is read by anyone).
function PartyCompose.describe(english)
    local parts = {}
    for slot, mask in ipairs(PartyCompose.masks()) do
        if mask ~= 0 then
            local names = {}
            for _, class in ipairs(Compose.classesOf(mask)) do
                names[#names + 1] = english and ns.Spec.englishClass(class) or ns.Spec.className(class)
            end
            parts[#parts + 1] = { role = Compose.SLOT_ROLES[slot], text = table.concat(names, "/") }
        end
    end
    return parts
end

function PartyCompose.init()
    -- The roster's changes reach the queue entry through main.lua's syncEntry.
    ns.charDb.composeOn = nil
end

ns.PartyCompose = PartyCompose
