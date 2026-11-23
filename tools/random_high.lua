-- busted --helper=tools/random_high.lua: math.random() always 0.999, to catch
-- timing that only passes for lucky random waits.
local real = math.random
math.random = function(a, b)
    if a == nil then
        return 0.999
    end
    return real(a, b)
end
