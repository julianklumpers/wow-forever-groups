local _, ns = ...
ns = ns or {}

-- Translations of what the player reads: the window, tooltips and the chat
-- lines for the player. Whispers and party messages stay English, as their
-- reader may speak any language. Keyed by the English text, placeholders in
-- the same order; a text without a translation shows in English.
local Locale = {}

local translations = {}

function Locale.add(codes, strings)
    for _, code in ipairs(codes) do
        translations[code] = strings
    end
end

-- The languages to choose from in the settings; Automatic follows WoW.
Locale.CHOICES = {
    { code = "enUS", name = "English" },
    { code = "deDE", name = "Deutsch" },
    { code = "esES", name = "Español" },
    { code = "ruRU", name = "Русский" },
}

-- The player's choice in the settings (ForeverGroupsDB.language), else
-- WoW's language.
function Locale.code()
    local chosen = ns.db and ns.db.language
    if chosen then
        return chosen
    end
    local getLocale = _G.GetLocale
    return type(getLocale) == "function" and getLocale() or "enUS"
end

function Locale.text(english)
    local strings = translations[Locale.code()]
    return strings and strings[english] or english
end

-- Marks texts that are translated where they are shown (tools/localekeys.lua
-- lists them); returns its argument unchanged.
function Locale.mark(value)
    return value
end

-- "1 group" or "5 groups": the singular or plural text, with the number.
function Locale.count(n, one, many)
    return string.format(Locale.text(n == 1 and one or many), n)
end

-- All translations, for the test that checks every text has one.
function Locale.all()
    return translations
end

ns.Locale = Locale
ns.L = setmetatable({}, {
    __index = function(_, english)
        return Locale.text(english)
    end,
})
return Locale
