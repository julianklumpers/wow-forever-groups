local _, ns = ...

local frame = CreateFrame("Frame")
local handlers = {}

function ns.isSecret(value)
    if canaccessvalue ~= nil then
        return not canaccessvalue(value)
    end
    return issecretvalue ~= nil and issecretvalue(value) == true
end

-- During a boss fight WoW hands chat text and names to addons as secret
-- values, and any string function on one raises an error (and taints the
-- addon). Handlers get nil in their place, which they already skip.
local function readable(...)
    local n = select("#", ...)
    local args = { ... }
    for i = 1, n do
        if ns.isSecret(args[i]) then
            args[i] = nil
        end
    end
    return n, args
end

-- One failing handler must not stop the others for the same event; the
-- error still goes to WoW's error handler.
frame:SetScript("OnEvent", function(_, event, ...)
    local n, args = readable(...)
    for _, handler in ipairs(handlers[event]) do
        local ok, err = pcall(handler, unpack(args, 1, n))
        if not ok then
            geterrorhandler()(err)
        end
    end
end)

-- Events this client does not know are skipped instead of raising an error.
function ns.on(event, handler)
    if not handlers[event] then
        handlers[event] = {}
        pcall(frame.RegisterEvent, frame, event)
    end
    table.insert(handlers[event], handler)
end
