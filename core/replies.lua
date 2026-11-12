local _, ns = ...
ns = ns or {}

-- Reads a group leader's whispered answer to "could you invite me?": "no"
-- for a clear refusal, "yes" for a clear yes, nil when it says both or
-- neither (then the invite is simply waited for).
local Replies = {}

-- Taken out first, so their "no" is not read as a refusal.
local YES_PHRASES = { "no problem", "no prob", "no worries", "why not" }
local NO_PHRASES = {
    "no thanks", "no thx", "no ty", "not needed", "dont need", "don't need", "do not need", "no need",
    "already have", "already got", "got one", "we're full", "were full", "we are full", "is full",
    "not looking", "no room", "no spot", "no space", "filled",
}
local NO_WORDS = { "no", "nope", "nah", "sorry", "sry", "full", "nvm", "found", "declined" }
local YES_WORDS = {
    "sure", "yes", "yep", "yup", "yeah", "yea", "ya", "ok", "okay", "kk", "k", "np", "inv", "invite", "invited",
    "inviting", "invd", "sec", "secs", "moment", "min", "omw", "coming", "come", "welcome", "y",
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
