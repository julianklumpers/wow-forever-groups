local _, ns = ...
ns = ns or {}

-- Reads a group leader's whispered answer to "could you invite me?": "no"
-- for a clear refusal, "yes" for a clear yes, nil when it says both or
-- neither (then the invite is simply waited for).
local Replies = {}

-- Taken out first, so their "no" is not read as a refusal.
local YES_PHRASES = { "no problemo", "no problem", "no probs", "no prob", "no worries", "why not", "1 min", "one min",
    "a min", "in a min", "1 sec", "a sec" }
-- Taken out too: a "no" or "full" that says what the group lacks, not a
-- refusal ("we have no tank", "not full yet").
local NEUTRAL_PHRASES = { "not full", "no tank", "no tanks", "no healer", "no healers", "no heal", "no heals",
    "no dps", "no damage" }
local NO_PHRASES = {
    "no thanks", "no thx", "no ty", "not needed", "dont need", "don't need", "do not need", "no need",
    "already have", "already got", "got one", "we're full", "were full", "we are full", "is full",
    "not looking", "no room", "no spot", "no space", "filled",
}
local NO_WORDS = { "no", "nope", "nah", "sorry", "sry", "full", "nvm", "found", "declined" }
local YES_WORDS = {
    "sure", "yes", "yep", "yup", "yeah", "yea", "ya", "ok", "okay", "kk", "np", "inv", "invite", "invited",
    "inviting", "invd", "sec", "secs", "moment", "omw", "coming", "come", "welcome", "y",
}

local function contains(text, phrase)
    local escaped = string.gsub(phrase, "(%p)", "%%%1")
    return string.find(" " .. text .. " ", "[^%a']" .. escaped .. "[^%a']") ~= nil
end

local function anyWord(set, list)
    for _, word in ipairs(list) do
        if set[word] then
            return true
        end
    end
    return false
end

-- Words of a question about the player, which the addon can answer itself
-- ("lvl?", "what spec?", "class?", "you tank?").
local QUESTION_WORDS = { "lvl", "level", "class", "spec", "role", "ilvl", "gs", "gear", "tank", "heal", "healer",
    "dps", "what", "which" }

function Replies.isQuestion(text)
    if type(text) ~= "string" then
        return false
    end
    local set = {}
    for word in string.gmatch(string.lower(text), "[%a]+") do
        set[word] = true
    end
    return anyWord(set, QUESTION_WORDS)
end

function Replies.classify(text)
    if type(text) ~= "string" then
        return nil
    end
    text = string.lower(text)
    local yes, no = false, false
    for _, phrase in ipairs(YES_PHRASES) do
        if contains(text, phrase) then
            yes = true
            text = string.gsub(text, string.gsub(phrase, "(%p)", "%%%1"), " ")
        end
    end
    for _, phrase in ipairs(NEUTRAL_PHRASES) do
        if contains(text, phrase) then
            text = string.gsub(text, string.gsub(phrase, "(%p)", "%%%1"), " ")
        end
    end
    for _, phrase in ipairs(NO_PHRASES) do
        no = no or contains(text, phrase)
    end
    local set = {}
    for word in string.gmatch(text, "[%a]+") do
        set[word] = true
    end
    no = no or anyWord(set, NO_WORDS)
    yes = yes or anyWord(set, YES_WORDS)
    if no and not yes then
        return "no"
    elseif yes and not no then
        return "yes"
    end
    return nil
end

ns.Replies = Replies
return Replies
