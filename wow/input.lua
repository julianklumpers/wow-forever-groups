local _, ns = ...

local Log = ns.Log

-- Actions WoW only allows straight after player input (applying to a group,
-- withdrawing, listing, inviting applicants) wait here and run on the
-- player's next key press or click, one per input.
local Input = {}

local queue = {}

-- A queued action with the same key is replaced instead of added twice.
function Input.queue(key, label, fn)
    for _, item in ipairs(queue) do
        if item.key == key then
            item.fn, item.label = fn, label
            return
        end
    end
    queue[#queue + 1] = { key = key, label = label, fn = fn }
end

function Input.cancel(key)
    for i, item in ipairs(queue) do
        if item.key == key then
            table.remove(queue, i)
            return
        end
    end
end

function Input.has(key)
    for _, item in ipairs(queue) do
        if item.key == key then
            return true
        end
    end
    return false
end

function Input.size()
    return #queue
end

-- From a key press or click handler only. Returns true if an action ran.
function Input.run()
    local item = table.remove(queue, 1)
    if not item then
        return false
    end
    local ok, err = pcall(item.fn)
    Log.debug("on input: %s %s", item.label, ok and "done" or ("failed: " .. tostring(err)))
    return true
end

ns.Input = Input
