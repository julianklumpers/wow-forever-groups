local _, ns = ...

local Log = {}

local MAX_LINES = 500
local PREFIX = "|cff33ccffForever Groups|r "

local function escape(text)
    return (string.gsub(tostring(text), "|", "||"))
end

local function isSecret(value)
    if canaccessvalue ~= nil then
        return not canaccessvalue(value)
    end
    return issecretvalue ~= nil and issecretvalue(value) == true
end

-- A secret value in a log line would raise an error (and taint): it is
-- written as <secret>, and a line that still fails keeps its format.
local function format(fmt, ...)
    local n = select("#", ...)
    if n == 0 then
        return fmt
    end
    local args = { ... }
    for i = 1, n do
        if isSecret(args[i]) then
            args[i] = "<secret>"
        end
    end
    local ok, text = pcall(string.format, fmt, unpack(args, 1, n))
    return ok and text or (fmt .. " (unformattable)")
end

local function store(tag, msg)
    local db = ns.db
    if not db then
        return
    end
    db.log = db.log or {}
    db.log[#db.log + 1] = date("%Y-%m-%d %H:%M:%S") .. " [" .. tag .. "] " .. msg
    while #db.log > MAX_LINES do
        table.remove(db.log, 1)
    end
end

-- Into the saved log only, not the chat.
function Log.record(tag, fmt, ...)
    store(tag, format(fmt, ...))
end

function Log.escape(text)
    return escape(text)
end

-- The chat shows the player's language; the saved log stays English.
function Log.info(fmt, ...)
    print(PREFIX .. format(ns.L[fmt], ...))
    store("INFO", format(fmt, ...))
end

-- How Forever Groups gets a group (asking leaders, inviting from the Group
-- Finder, whispers): kept out of the chat so it simply seems to happen;
-- shown with /fg debug on, and always in the saved log.
function Log.detail(fmt, ...)
    local msg = format(fmt, ...)
    store("DETAIL", msg)
    if ns.db and ns.db.debug then
        print(PREFIX .. msg)
    end
end

function Log.warn(fmt, ...)
    print(PREFIX .. "|cffffd040" .. format(ns.L[fmt], ...) .. "|r")
    store("WARN", format(fmt, ...))
end

function Log.debug(fmt, ...)
    local msg = format(fmt, ...)
    store("DEBUG", msg)
    if ns.db and ns.db.debug then
        print(PREFIX .. "|cff909090" .. escape(msg) .. "|r")
    end
end

function Log.lines(n)
    local lines = ns.db and ns.db.log or {}
    local result = {}
    for i = math.max(1, #lines - n + 1), #lines do
        result[#result + 1] = lines[i]
    end
    return result
end

ns.Log = Log
