-- Wire format. Every message is broadcast on the shared channel and the sender
-- is the player the message speaks for.
--   v2|Q|<joinedAt>|<dungeon,...>|<name:roles:level,...>[|<reserved>[|<since>[|<playstyle>[|<spec>]]]]
--       queue entry / heartbeat; the first member is the sender (entry owner);
--       roles is one or more of T, H, D in that order ("D", "TD", "THD");
--       reserved ("HD") are roles the party already invited someone for from
--       WoW's Group Finder, so they count as taken; since is when the
--       sender's client came online (the longest-online player matches);
--       playstyle is 1-4 (core/playstyles.lua), empty for no preference;
--       spec is the owner's class and talent tree ("SHAMAN2", core/specs.lua)
--   v2|K                  keep-alive from a likely matchmaker
--   v2|L                  sender left the queue
--   v2|S[|<nonce>]        sync request; queued players re-send Q. The nonce
--                         lets a client recognise its own echo and learn the
--                         exact sender string the server uses for it.
--   v2|P|<seq>|<dungeon>|<name:role,...;name:role,...>[|<missing>[|<playstyles>]]
--       proposal by the sender (matchmaker) with the role assigned to each
--       member; ';' separates entries, the first member of each entry is its
--       owner, the first entry's owner leads. missing ("HD") lists roles the
--       leader fills from WoW's Group Finder after the group forms.
--       playstyles ("21") are the group's playstyles, the most picked first.
--   v2|A|<matchmaker>|<seq>|<R|Y|N|C>
--       answer from an entry owner: Reserved, Yes, No, Conflict
--   v2|G|<phase>|...      party status from the party leader, sent to the
--                         PARTY addon channel (not the shared channel):
--       Q|<joinedAt>|<dungeon,...>|<name:roles,...>   party is queued
--       P|<dungeon>|<secondsLeft>                      group proposal open
--       F|<dungeon>|<leader>                           group formed
--       L                                              not queued any more
--       R                                              request (from a member)
-- Unknown trailing fields are ignored so later minor additions stay compatible.
local _, ns = ...
ns = ns or {}

local Config = ns.Config or require("core.config")
local Roles = ns.Roles or require("core.roles")
local Playstyles = ns.Playstyles or require("core.playstyles")
local Specs = ns.Specs or require("core.specs")

local Protocol = {}

Protocol.VERSION = "v2"
-- Questing groups use the same messages under their own prefix, so the
-- dungeon and quest queues never mix; a questing group has room for at most
-- one tank and one healer, the rest DPS.
Protocol.QUESTS = { prefix = "q1", slots = { T = 1, H = 1, D = 5 } }
Protocol.MAX_BYTES = 255
Protocol.ROLES = { T = true, H = true, D = true }
Protocol.ANSWERS = { R = true, Y = true, N = true, C = true }

local DUNGEON_PATTERN = "^[%w_%-]+$"
local NONCE_PATTERN = "^%w+$"

local function slotsOf(space)
    return space and space.slots or Config.SLOTS
end

local function prefixOf(space)
    return space and space.prefix or Protocol.VERSION
end

local function split(text, sep)
    local parts, start = {}, 1
    while true do
        local i = string.find(text, sep, start, true)
        if not i then
            parts[#parts + 1] = string.sub(text, start)
            return parts
        end
        parts[#parts + 1] = string.sub(text, start, i - 1)
        start = i + #sep
    end
end

local function toInteger(text)
    if text == nil then
        return nil
    end
    local n = tonumber(text)
    if n and n >= 0 and n == math.floor(n) then
        return n
    end
    return nil
end

-- Forever names can contain a space ("First Last"), so only the separators,
-- control characters and leading/trailing whitespace are refused.
function Protocol.isValidName(name)
    return type(name) == "string"
        and name ~= ""
        and not string.find(name, "[|,;:%c]")
        and not string.find(name, "^%s")
        and not string.find(name, "%s$")
end

function Protocol.isValidDungeon(id)
    return type(id) == "string" and string.find(id, DUNGEON_PATTERN) ~= nil
end

function Protocol.roleCounts(members)
    local counts = { T = 0, H = 0, D = 0 }
    for _, member in ipairs(members) do
        counts[member.role] = counts[member.role] + 1
    end
    return counts
end

local function validateNames(members, maxMembers)
    if type(members) ~= "table" or #members == 0 then
        return false, "no members"
    end
    if #members > maxMembers then
        return false, "too many members"
    end
    local seen = {}
    for _, member in ipairs(members) do
        if not Protocol.isValidName(member.name) then
            return false, "invalid name"
        end
        if seen[member.name] then
            return false, "duplicate member"
        end
        seen[member.name] = true
    end
    return true
end

-- Proposal members: exactly one assigned role each. missing (optional) holds
-- the roles left open for players from WoW's Group Finder.
function Protocol.validateMembers(members, maxMembers, missing, space)
    local ok, err = validateNames(members, maxMembers)
    if not ok then
        return false, err
    end
    for _, member in ipairs(members) do
        if not Protocol.ROLES[member.role] then
            return false, "invalid role"
        end
    end
    local counts = Protocol.roleCounts(members)
    local open = Roles.countLetters(missing or "")
    if not open then
        return false, "invalid missing roles"
    end
    for role, max in pairs(slotsOf(space)) do
        if counts[role] + open[role] > max then
            return false, "role composition does not fit a group"
        end
    end
    return true
end

-- Queue members: one or more roles each, and some assignment of them plus the
-- reserved roles must fit a group.
function Protocol.validateParty(members, reserved, space)
    local ok, err = validateNames(members, Config.MAX_PREMADE)
    if not ok then
        return false, err
    end
    if not Roles.countLetters(reserved or "") then
        return false, "invalid reserved roles"
    end
    if #members + #(reserved or "") > Config.MAX_PREMADE then
        return false, "too many members"
    end
    for _, member in ipairs(members) do
        local normalized = Roles.normalize(member.roles)
        if not normalized or normalized ~= member.roles then
            return false, "invalid role"
        end
    end
    if #Roles.options(Roles.withReserved(members, reserved), slotsOf(space)) == 0 then
        return false, "role composition does not fit a group"
    end
    return true
end

function Protocol.validateEntry(entry, space)
    if type(entry.joinedAt) ~= "number" or entry.joinedAt < 0 or entry.joinedAt ~= math.floor(entry.joinedAt) then
        return false, "invalid joinedAt"
    end
    if type(entry.dungeons) ~= "table" or #entry.dungeons == 0 then
        return false, "no dungeons"
    end
    for _, dungeon in ipairs(entry.dungeons) do
        if not Protocol.isValidDungeon(dungeon) then
            return false, "invalid dungeon"
        end
    end
    local ok, err = Protocol.validateParty(entry.members, entry.reserved, space)
    if not ok then
        return false, err
    end
    for _, member in ipairs(entry.members) do
        if toInteger(member.level) == nil then
            return false, "invalid level"
        end
    end
    if entry.playstyle ~= nil and not Playstyles.isValid(entry.playstyle) then
        return false, "invalid playstyle"
    end
    return true
end

local encoders = {}

function encoders.queue(msg, space)
    local ok, err = Protocol.validateEntry(msg, space)
    if not ok then
        return nil, err
    end
    local members = {}
    for i, member in ipairs(msg.members) do
        members[i] = member.name .. ":" .. member.roles .. ":" .. member.level
    end
    if msg.since ~= nil and toInteger(msg.since) == nil then
        return nil, "invalid since"
    end
    local optional = { msg.reserved or "", msg.since and tostring(msg.since) or "",
        (msg.playstyle or Playstyles.ANY) ~= Playstyles.ANY and tostring(msg.playstyle) or "",
        msg.spec and Specs.decode(msg.spec) and msg.spec or "" }
    while #optional > 0 and optional[#optional] == "" do
        optional[#optional] = nil
    end
    local tail = #optional > 0 and ("|" .. table.concat(optional, "|")) or ""
    return "Q|" .. msg.joinedAt .. "|" .. table.concat(msg.dungeons, ",") .. "|" .. table.concat(members, ",")
        .. tail
end

function encoders.leave()
    return "L"
end

function encoders.alive()
    return "K"
end

function encoders.sync(msg)
    if msg.nonce == nil then
        return "S"
    end
    if type(msg.nonce) ~= "string" or not string.find(msg.nonce, NONCE_PATTERN) then
        return nil, "invalid nonce"
    end
    return "S|" .. msg.nonce
end

function encoders.propose(msg, space)
    if toInteger(msg.seq) == nil then
        return nil, "invalid seq"
    end
    if not Protocol.isValidDungeon(msg.dungeon) then
        return nil, "invalid dungeon"
    end
    if type(msg.entries) ~= "table" or #msg.entries == 0 then
        return nil, "no entries"
    end
    local all, entries = {}, {}
    for i, entry in ipairs(msg.entries) do
        local members = {}
        for j, member in ipairs(entry) do
            members[j] = member.name .. ":" .. member.role
            all[#all + 1] = member
        end
        entries[i] = table.concat(members, ",")
    end
    local ok, err = Protocol.validateMembers(all, 5, msg.missing, space)
    if not ok then
        return nil, err
    end
    local styles = Playstyles.encode(msg.playstyles)
    if not styles then
        return nil, "invalid playstyles"
    end
    local tail = ""
    if styles ~= "" then
        tail = "|" .. (msg.missing or "") .. "|" .. styles
    elseif msg.missing and msg.missing ~= "" then
        tail = "|" .. msg.missing
    end
    return "P|" .. msg.seq .. "|" .. msg.dungeon .. "|" .. table.concat(entries, ";") .. tail
end

function encoders.answer(msg)
    if not Protocol.isValidName(msg.matchmaker) then
        return nil, "invalid matchmaker"
    end
    if toInteger(msg.seq) == nil then
        return nil, "invalid seq"
    end
    if not Protocol.ANSWERS[msg.answer] then
        return nil, "invalid answer"
    end
    return "A|" .. msg.matchmaker .. "|" .. msg.seq .. "|" .. msg.answer
end

-- space: Protocol.QUESTS for the questing queue; nil for dungeons.
function Protocol.encode(msg, space)
    local encoder = encoders[msg.kind]
    if not encoder then
        return nil, "unknown kind"
    end
    local body, err = encoder(msg, space)
    if not body then
        return nil, err
    end
    local text = prefixOf(space) .. "|" .. body
    if #text > Protocol.MAX_BYTES then
        return nil, "message too long"
    end
    return text
end

local PARTY_PHASES = { Q = true, P = true, F = true, L = true, R = true }

function encoders.party(msg)
    local phase = msg.phase
    if not PARTY_PHASES[phase] then
        return nil, "invalid phase"
    end
    if phase == "Q" then
        if toInteger(msg.joinedAt) == nil or type(msg.dungeons) ~= "table" or type(msg.members) ~= "table" then
            return nil, "invalid party queue"
        end
        local members = {}
        for i, member in ipairs(msg.members) do
            if not Protocol.isValidName(member.name) or Roles.normalize(member.roles) ~= member.roles then
                return nil, "invalid member"
            end
            members[i] = member.name .. ":" .. member.roles
        end
        return "G|Q|" .. msg.joinedAt .. "|" .. table.concat(msg.dungeons, ",") .. "|" .. table.concat(members, ",")
    elseif phase == "P" then
        if not Protocol.isValidDungeon(msg.dungeon) or toInteger(msg.secondsLeft) == nil then
            return nil, "invalid party proposal"
        end
        return "G|P|" .. msg.dungeon .. "|" .. msg.secondsLeft
    elseif phase == "F" then
        if not Protocol.isValidDungeon(msg.dungeon) or not Protocol.isValidName(msg.leader) then
            return nil, "invalid party group"
        end
        return "G|F|" .. msg.dungeon .. "|" .. msg.leader
    end
    return "G|" .. phase
end

local decoders = {}

decoders.G = function(fields)
    local phase = fields[3]
    if phase == "Q" then
        local joinedAt = toInteger(fields[4])
        if not joinedAt or not fields[5] or not fields[6] then
            return nil, "malformed party queue"
        end
        local members = {}
        for i, text in ipairs(split(fields[6], ",")) do
            local parts = split(text, ":")
            if not Protocol.isValidName(parts[1]) or not parts[2] or Roles.normalize(parts[2]) ~= parts[2] then
                return nil, "malformed party member"
            end
            members[i] = { name = parts[1], roles = parts[2] }
        end
        return { kind = "party", phase = "Q", joinedAt = joinedAt, dungeons = split(fields[5], ","), members = members }
    elseif phase == "P" then
        local secondsLeft = toInteger(fields[5])
        if not Protocol.isValidDungeon(fields[4]) or not secondsLeft then
            return nil, "malformed party proposal"
        end
        return { kind = "party", phase = "P", dungeon = fields[4], secondsLeft = secondsLeft }
    elseif phase == "F" then
        if not Protocol.isValidDungeon(fields[4]) or not Protocol.isValidName(fields[5]) then
            return nil, "malformed party group"
        end
        return { kind = "party", phase = "F", dungeon = fields[4], leader = fields[5] }
    elseif PARTY_PHASES[phase] then
        return { kind = "party", phase = phase }
    end
    return nil, "unknown party phase"
end

decoders.Q = function(fields, space)
    local joinedAt = toInteger(fields[3])
    if not joinedAt or not fields[4] or not fields[5] then
        return nil, "malformed queue"
    end
    local members = {}
    for i, text in ipairs(split(fields[5], ",")) do
        local parts = split(text, ":")
        members[i] = { name = parts[1], roles = parts[2], level = toInteger(parts[3]) }
    end
    local msg = {
        kind = "queue", joinedAt = joinedAt, dungeons = split(fields[4], ","), members = members,
        reserved = fields[6] or "", since = toInteger(fields[7]),
        playstyle = (fields[8] == nil or fields[8] == "") and Playstyles.ANY or tonumber(fields[8]) or -1,
        spec = Specs.decode(fields[9]) and fields[9] or nil,
    }
    local ok, err = Protocol.validateEntry(msg, space)
    if not ok then
        return nil, err
    end
    return msg
end

decoders.L = function()
    return { kind = "leave" }
end

decoders.K = function()
    return { kind = "alive" }
end

decoders.S = function(fields)
    local nonce = fields[3]
    if nonce ~= nil and string.find(nonce, NONCE_PATTERN) then
        return { kind = "sync", nonce = nonce }
    end
    return { kind = "sync" }
end

decoders.P = function(fields, space)
    local seq = toInteger(fields[3])
    if not seq or not Protocol.isValidDungeon(fields[4]) or not fields[5] then
        return nil, "malformed proposal"
    end
    local entries, all = {}, {}
    for i, entryText in ipairs(split(fields[5], ";")) do
        local entry = {}
        for j, memberText in ipairs(split(entryText, ",")) do
            local parts = split(memberText, ":")
            entry[j] = { name = parts[1], role = parts[2] }
            all[#all + 1] = entry[j]
        end
        entries[i] = entry
    end
    local missing = fields[6] or ""
    local ok, err = Protocol.validateMembers(all, 5, missing, space)
    if not ok then
        return nil, err
    end
    local playstyles = Playstyles.decode(fields[7])
    if not playstyles then
        return nil, "malformed playstyles"
    end
    return { kind = "propose", seq = seq, dungeon = fields[4], entries = entries, missing = missing,
        playstyles = playstyles }
end

decoders.A = function(fields)
    local seq = toInteger(fields[4])
    if not Protocol.isValidName(fields[3]) or not seq or not Protocol.ANSWERS[fields[5]] then
        return nil, "malformed answer"
    end
    return { kind = "answer", matchmaker = fields[3], seq = seq, answer = fields[5] }
end

function Protocol.decode(text, space)
    if type(text) ~= "string" or #text > Protocol.MAX_BYTES then
        return nil, "invalid text"
    end
    local fields = split(text, "|")
    if fields[1] ~= prefixOf(space) then
        return nil, "unsupported version"
    end
    local decoder = decoders[fields[2]]
    if not decoder then
        return nil, "unknown type"
    end
    return decoder(fields, space)
end

ns.Protocol = Protocol
return Protocol
