local _, ns = ...

-- The texts Forever Groups sends to other players (whispers and party chat).
-- Each has a default; the player may write their own (any language) with
-- {placeholders}, or turn a message off. Whispers and party messages carry
-- the [Forever Groups] mark: other players' addons skip what carries it, so
-- two addons never answer each other.
local Messages = {}

local MARK = "[Forever Groups]"
local MAX_BYTES = 255

Messages.LIST = {
    { id = "fillInvite", label = "Inviting a player from the Group Finder",
        default = "Hi! Our group for {dungeon} needs a {role}. Inviting you now. I'm the {spec}.",
        keys = { "dungeon", "role", "spec" } },
    { id = "groupInvite", label = "Inviting the group the queue found",
        default = "Group found for {dungeon}. Inviting you now.",
        keys = { "dungeon" } },
    { id = "questInvite", label = "Inviting a player for a group quest",
        default = "Inviting you for {quest} ({zone}, group of {size}). I can share the quest.",
        keys = { "quest", "zone", "size" } },
    { id = "applyAsk", label = "Asking a group leader to invite you (dungeon)",
        default = "Hi! Level {level} {spec} ({role}) here, could you invite me for {dungeon}?",
        keys = { "level", "spec", "role", "dungeon" }, markAtEnd = true },
    { id = "questAsk", label = "Asking a group leader to invite you (quest)",
        default = "Level {level} {spec} ({role}) here, could you invite me for {quest}?",
        keys = { "level", "spec", "role", "quest" } },
    { id = "bgAsk", label = "Asking a group leader to invite you (battleground)",
        default = "Hi! Level {level} {spec} ({role}) here, could you invite me for {battleground}?",
        keys = { "level", "spec", "role", "battleground" }, markAtEnd = true },
    { id = "bgInvite", label = "Inviting a player for a battleground group",
        default = "Hi! Making a {battleground} group of {size}, inviting you now.",
        keys = { "battleground", "size" } },
    { id = "askAnswer", label = "Answer to an asked leader's question (level, class, spec)",
        default = "Level {level} {spec}, {role}.",
        keys = { "level", "spec", "role" }, markAtEnd = true },
    { id = "askLead", label = "Asking a leader without Forever Groups to make you leader",
        default = "Hi! Could you make me leader? Forever Groups will fill the group for us ({roles} needed).",
        keys = { "roles", "dungeon" }, markAtEnd = true },
    { id = "whisperYes", label = "Answer: inviting a player who whispered you",
        default = "Inviting you as {role} for {dungeon}.",
        keys = { "role", "dungeon" } },
    { id = "whisperNo", label = "Answer: their role is already taken",
        default = "Sorry, we only need {roles} right now.",
        keys = { "roles" } },
    { id = "whisperWhich", label = "Answer: asking which role they play",
        default = "Hi! Which role do you play? Reply tank, heal or dps. Still needed: {roles}.",
        keys = { "roles" } },
    { id = "partyComplete", label = "Party chat: the group is complete",
        default = "Group complete for {dungeon}! Meet at the entrance.",
        keys = { "dungeon" } },
    { id = "partyReplacement", label = "Party chat: looking for a replacement",
        default = "Looking for a replacement {role}.",
        keys = { "role" } },
}

Messages.PLACEHOLDERS = { "dungeon", "quest", "zone", "size", "role", "roles", "spec", "level", "battleground" }

local byId, known = {}, {}
for _, message in ipairs(Messages.LIST) do
    byId[message.id] = message
end
for _, key in ipairs(Messages.PLACEHOLDERS) do
    known[key] = true
end

local function stored(id)
    ns.db.messages = ns.db.messages or {}
    return ns.db.messages[id]
end

-- One line without WoW's escape codes ("|"), which chat would refuse.
local function clean(text)
    text = string.gsub(text or "", "|c%x%x%x%x%x%x%x%x", "")
    text = string.gsub(text, "|r", "")
    text = string.gsub(text, "|", "")
    text = string.gsub(text, "[\r\n]+", " ")
    return (string.gsub(text, "^%s+", ""))
end

-- Fills in the placeholders. A sentence with a placeholder that has no value
-- (no spec known yet, say) is left out rather than sent half empty; an
-- unknown {word} stays as typed.
local function fill(template, values)
    if values.spec == nil or values.spec == "" then
        template = string.gsub(template, "{spec} %({role}%)", "{role}")
        template = string.gsub(template, " {spec},", ",")
    end
    local parts = {}
    for sentence in string.gmatch(template, "[^%.!%?]+[%.!%?]*%s*") do
        local missing = false
        local filled = string.gsub(sentence, "{(%a+)}", function(key)
            local value = values[key]
            if value == nil or value == "" then
                missing = missing or known[key] == true
                return nil
            end
            return tostring(value)
        end)
        if not missing then
            parts[#parts + 1] = filled
        end
    end
    return (string.gsub(table.concat(parts), "%s+$", ""))
end

-- At most 255 bytes (WoW cuts longer messages), without a broken UTF-8
-- character at the end.
local function fit(text)
    if #text <= MAX_BYTES then
        return text
    end
    text = string.sub(text, 1, MAX_BYTES)
    for i = #text, math.max(1, #text - 3), -1 do
        local byte = string.byte(text, i)
        if byte < 0x80 then
            break
        elseif byte >= 0xC0 then
            text = string.sub(text, 1, i - 1)
            break
        end
    end
    return text
end

function Messages.template(id)
    local own = stored(id)
    return own and own.text or byId[id].default
end

function Messages.isOn(id)
    local own = stored(id)
    return not (own and own.off)
end

-- The message to send, or nil when the player turned it off.
function Messages.text(id, values)
    local message = byId[id]
    if not message or not Messages.isOn(id) then
        return nil
    end
    local body = fill(clean(Messages.template(id)), values or {})
    if body == "" then
        return nil
    end
    if message.markAtEnd then
        return fit(body .. " (Forever Groups)")
    end
    return fit(MARK .. " " .. body)
end

-- Example values for the preview in the Messages window.
function Messages.sample(id)
    local spec = ns.Spec.myLabel()
    return Messages.text(id, {
        dungeon = "The Deadmines", quest = "Hogger", zone = "Elwynn Forest", size = 3, role = "healer",
        roles = "Healer, DPS", spec = spec ~= nil and spec or "Enhancement Shaman", level = UnitLevel("player"),
        battleground = "Warsong Gulch",
    })
end

-- Stores the player's own text; the default text (or nothing) clears it.
function Messages.set(id, text)
    text = clean(text)
    local own = stored(id) or {}
    own.text = (text ~= "" and text ~= byId[id].default) and text or nil
    ns.db.messages[id] = (own.text or own.off) and own or nil
end

function Messages.setOn(id, on)
    local own = stored(id) or {}
    own.off = not on or nil
    ns.db.messages[id] = (own.text or own.off) and own or nil
end

function Messages.reset(id)
    stored(id)
    ns.db.messages[id] = nil
end

ns.Messages = Messages
