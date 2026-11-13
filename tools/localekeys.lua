-- Lists the English texts the addon looks up for translation: every
-- L["..."], the first text of Log.info / Log.warn, the counts of
-- Locale.count, the hint, and the labels and tooltips the widgets translate
-- themselves. Run: lua tools/localekeys.lua (prints one key per line), or
-- require it for the keys as a set.
local LocaleKeys = {}

-- Calls whose literal arguments (by position) are translation keys.
local CALLS = {
    ["Log.info"] = { 1 }, ["Log.warn"] = { 1 },
    ["Locale.count"] = { 2, 3 },
    ["W.setHint"] = { 1 },
    ["Widgets.tooltip"] = { 2, 3 },
    ["Widgets.button"] = { 2 }, ["Widgets.check"] = { 2 }, ["Widgets.header"] = { 2 },
    ["Widgets.link"] = { 2 }, ["Widgets.tab"] = { 2 }, ["Widgets.expander"] = { 2 }, ["Widgets.window"] = { 2 },
    ["iconButton"] = { 2 }, ["action"] = { 2 }, ["buildBlock"] = { 1 }, ["buildSection"] = { 1 },
    ["caption"] = { 1 },
}

-- Shown translated but defined where no translation is at hand: the talent
-- trees' names (core/specs.lua).
LocaleKeys.EXTRA = {
    "Arms", "Fury", "Protection", "Holy", "Retribution", "Beast Mastery", "Marksmanship", "Survival",
    "Assassination", "Combat", "Subtlety", "Discipline", "Shadow", "Elemental", "Enhancement", "Restoration",
    "Arcane", "Fire", "Frost", "Affliction", "Demonology", "Destruction", "Balance", "Feral",
}

-- Table fields that hold texts the widgets show translated.
local FIELDS = { label = true, tip = true, title = true }

local function readString(src, i)
    local quote = src:sub(i, i)
    local out, j = {}, i + 1
    while j <= #src do
        local c = src:sub(j, j)
        if c == "\\" then
            local n = src:sub(j + 1, j + 1)
            local map = { n = "\n", t = "\t", ["\\"] = "\\", ['"'] = '"', ["'"] = "'" }
            out[#out + 1] = map[n] or n
            j = j + 2
        elseif c == quote then
            return table.concat(out), j + 1
        else
            out[#out + 1] = c
            j = j + 1
        end
    end
    return nil, j
end

local function skipSpace(src, i)
    while true do
        local s, e = src:find("^%s+", i)
        if s then
            i = e + 1
        elseif src:sub(i, i + 1) == "--" then
            local nl = src:find("\n", i)
            i = nl and nl + 1 or #src + 1
        else
            return i
        end
    end
end

-- A literal, or literals joined with .., starting at i: the text and the end.
local function readConcat(src, i)
    local c = src:sub(i, i)
    if c ~= '"' and c ~= "'" then
        return nil, i
    end
    local text, j = readString(src, i)
    local parts = { text }
    while true do
        local k = skipSpace(src, j)
        if src:sub(k, k + 1) ~= ".." then
            break
        end
        k = skipSpace(src, k + 2)
        local q = src:sub(k, k)
        if q ~= '"' and q ~= "'" then
            return nil, j
        end
        local more
        more, j = readString(src, k)
        parts[#parts + 1] = more
    end
    return table.concat(parts), j
end

-- The arguments of a call starting after "(": a list of { from, to } spans.
local function splitArgs(src, i)
    local args, depth, start, j = {}, 0, i, i
    while j <= #src do
        local c = src:sub(j, j)
        if c == '"' or c == "'" then
            local _, e = readString(src, j)
            j = e
        elseif src:sub(j, j + 1) == "--" then
            local nl = src:find("\n", j)
            j = nl and nl + 1 or #src + 1
        else
            if c == "(" or c == "{" or c == "[" then
                depth = depth + 1
            elseif c == ")" or c == "}" or c == "]" then
                if depth == 0 then
                    args[#args + 1] = { start, j - 1 }
                    return args
                end
                depth = depth - 1
            elseif c == "," and depth == 0 then
                args[#args + 1] = { start, j - 1 }
                start = j + 1
            end
            j = j + 1
        end
    end
    return args
end

local function literalOf(src, span)
    local i = skipSpace(src, span[1])
    local text, e = readConcat(src, i)
    if text and skipSpace(src, e) > span[2] then
        return text
    end
    return nil
end

-- Every literal chunk inside L[ ... ] (it may pick between texts).
local function bracketLiterals(src, i, add)
    local depth, j = 0, i
    while j <= #src do
        local c = src:sub(j, j)
        if c == '"' or c == "'" then
            local text, e = readConcat(src, j)
            if text then
                add(text)
            end
            j = e
        elseif c == "[" then
            depth = depth + 1
            j = j + 1
        elseif c == "]" then
            if depth == 0 then
                return
            end
            depth = depth - 1
            j = j + 1
        else
            j = j + 1
        end
    end
end

-- Locale.mark(...): every literal value inside (not a table's [key]).
local function markedLiterals(src, i, add)
    local depth, j = 0, i
    while j <= #src do
        local c = src:sub(j, j)
        if c == '"' or c == "'" then
            local k = j - 1
            while k > 0 and src:sub(k, k):match("%s") do
                k = k - 1
            end
            local text, e = readConcat(src, j)
            if text and src:sub(k, k) ~= "[" then
                add(text)
            end
            j = e
        elseif c == "(" or c == "{" then
            depth = depth + 1
            j = j + 1
        elseif c == ")" or c == "}" then
            if depth == 0 then
                return
            end
            depth = depth - 1
            j = j + 1
        else
            j = j + 1
        end
    end
end

function LocaleKeys.fromSource(src, add)
    for i in src:gmatch("()L%[") do
        local before = src:sub(i - 1, i - 1)
        if not before:match("[%w_]") then
            bracketLiterals(src, i + 2, add)
        end
    end
    for name, positions in pairs(CALLS) do
        local pattern = "()" .. name:gsub("%.", "%%.") .. "%s*%("
        for at, open in src:gmatch(pattern .. "()") do
            local prev = src:sub(at - 1, at - 1)
            if not prev:match("[%w_]") or prev == "." then
                local args = splitArgs(src, open)
                for _, n in ipairs(positions) do
                    local text = args[n] and literalOf(src, args[n])
                    if text then
                        add(text)
                    end
                end
            end
        end
    end
    for open in src:gmatch("Locale%.mark%s*%(()") do
        markedLiterals(src, open, add)
    end
    for field, at in src:gmatch("([%a_]+)%s*=%s*()[\"']") do
        if FIELDS[field] then
            local text = readConcat(src, at)
            if text then
                add(text)
            end
        end
    end
end

-- Files whose texts are translated: the game side, not the protocol.
LocaleKeys.SKIP = {
    ["wow/diagnostics.lua"] = true, ["wow/messages.lua"] = false,
}

function LocaleKeys.files(root, list)
    local files = {}
    for path in (list or io.popen("cd " .. root .. " && ls wow/*.lua wow/ui/*.lua wow/ui/window/*.lua"):lines()) do
        if not LocaleKeys.SKIP[path] then
            files[#files + 1] = path
        end
    end
    return files
end

function LocaleKeys.collect(root)
    root = root or "."
    local keys = {}
    for _, text in ipairs(LocaleKeys.EXTRA) do
        keys[text] = "core/specs.lua"
    end
    for _, path in ipairs(LocaleKeys.files(root)) do
        local f = assert(io.open(root .. "/" .. path))
        local src = f:read("*a")
        f:close()
        LocaleKeys.fromSource(src, function(text)
            if text:match("%a") then
                keys[text] = keys[text] or path
            end
        end)
    end
    return keys
end

if arg and arg[0] and arg[0]:match("localekeys%.lua$") then
    local keys = LocaleKeys.collect(arg[1] or ".")
    local list = {}
    for key in pairs(keys) do
        list[#list + 1] = key
    end
    table.sort(list)
    for _, key in ipairs(list) do
        print(key)
    end
end

return LocaleKeys
