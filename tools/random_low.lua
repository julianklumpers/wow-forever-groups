-- busted --helper=tools/random_low.lua: math.random() always 0, the other extreme.
local real = math.random
math.random = function(a, b)
    if a == nil then
        return 0.0
    end
    return real(a, b)
end
