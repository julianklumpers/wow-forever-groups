local _, ns = ...
ns = ns or {}

local Config = {
    HEARTBEAT_INTERVAL = 45,
    ENTRY_TIMEOUT = 120,
    WARMUP = 10,
    MATCH_INTERVAL = 5,
    ALIVE_INTERVAL = 10,
    ALIVE_TIMEOUT = 25,
    ALIVE_RANKS = 3,
    ACK_TIMEOUT = 10,
    PROPOSAL_TIMEOUT = 30,
    PROPOSAL_GRACE = 5,
    SYNC_JITTER = 5,
    FINISHED_RETENTION = 120,
    MAX_PREMADE = 4,
    PARTIAL_GROUPS = true,
    PARTIAL_AFTER = 0,
    PARTIAL_MIN_PLAYERS = 2,
    SLOTS = { T = 1, H = 1, D = 3 },
}

function Config.with(overrides)
    local result = {}
    for key, value in pairs(Config) do
        if type(value) ~= "function" then
            result[key] = value
        end
    end
    for key, value in pairs(overrides or {}) do
        result[key] = value
    end
    return result
end

ns.Config = Config
return Config
