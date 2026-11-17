local _, ns = ...

local Languages = ns.Languages

-- The languages the player is grouped with, in both Forever Groups' queues
-- and WoW's Group Finder: the game's own language always, and the others
-- ticked in the settings (ForeverGroupsDB.languages, a set of codes).
local MatchLanguages = {}

MatchLanguages.NAMES = ns.Locale.mark({
    enUS = "English", deDE = "German", esES = "Spanish", frFR = "French", ruRU = "Russian", ptBR = "Portuguese",
})

function MatchLanguages.own()
    local code = type(GetLocale) == "function" and GetLocale() or nil
    return Languages.normalize(type(code) == "string" and code or "enUS")
end

-- A set: the own language and the ticked ones.
function MatchLanguages.accepted()
    local set = { [MatchLanguages.own()] = true }
    for code, on in pairs(ns.db.languages or {}) do
        if on == true then
            set[code] = true
        end
    end
    return set
end

function MatchLanguages.wireText()
    return Languages.encode(MatchLanguages.own(), MatchLanguages.accepted())
end

-- The queued entries change right away.
function MatchLanguages.apply()
    local text = MatchLanguages.wireText()
    for _, engine in ipairs(ns.Queues.engines()) do
        engine:setLanguage(text)
    end
end

function MatchLanguages.set(code, on)
    if code == MatchLanguages.own() then
        return
    end
    local set = ns.db.languages or {}
    local was = set[code] == true
    if was == (on == true) then
        return
    end
    set[code] = on and true or nil
    ns.db.languages = next(set) and set or nil
    MatchLanguages.apply()
    if ns.LfgList then
        ns.LfgList.languagesChanged(was)
    end
end

-- The languages WoW's Group Finder can search that Forever Groups knows
-- (Languages.CODES), the own one first; all of those when the game does not
-- tell.
function MatchLanguages.offered()
    local api = C_LFGList and C_LFGList.GetAvailableLanguageSearchFilter
    local ok, offered = false, nil
    if type(api) == "function" then
        ok, offered = pcall(api)
    end
    if not ok or type(offered) ~= "table" or #offered == 0 then
        offered = Languages.CODES
    end
    local own = MatchLanguages.own()
    local list = { own }
    for _, code in ipairs(offered) do
        if type(code) == "string" and code ~= own and Languages.isKnown(code) then
            list[#list + 1] = code
        end
    end
    return list
end

-- The most languages offered() can return, for the room the settings keep.
function MatchLanguages.mostOffered()
    return #Languages.CODES + (Languages.isKnown(MatchLanguages.own()) and 0 or 1)
end

ns.MatchLanguages = MatchLanguages
