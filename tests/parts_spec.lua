-- The Parts table in docs/DEVELOPMENT.md must name every source file (and
-- only files that exist): /bugscan scans a part by it.
local function partsTable()
    local file = assert(io.open("docs/DEVELOPMENT.md"))
    local text = file:read("*a")
    file:close()
    local section = assert(text:match("\n## Parts\n(.-)\n## "), "no Parts section")
    local listed, dirs = {}, {}
    for row in section:gmatch("\n|([^\n]+)|") do
        local cells = {}
        for cell in (row .. "|"):gmatch("([^|]*)|") do
            cells[#cells + 1] = cell
        end
        local files = cells[3] or ""
        local prefix
        for item in files:gmatch("`([^`]+)`") do
            if item:sub(-1) == "/" then
                dirs[#dirs + 1] = item
            else
                local dir, base = item:match("^(.*/)([^/]+)$")
                if dir then
                    prefix = dir
                else
                    base = item
                end
                assert(prefix, "a file without a folder before it: " .. item)
                listed[prefix .. base .. ".lua"] = true
            end
        end
    end
    return listed, dirs
end

local function sourceFiles()
    local files = {}
    local list = io.popen('find core wow -name "*.lua"')
    for path in list:lines() do
        files[#files + 1] = path
    end
    list:close()
    table.sort(files)
    return files
end

describe("the Parts table in docs/DEVELOPMENT.md", function()
    local listed, dirs = partsTable()

    it("names every source file", function()
        local missing = {}
        for _, path in ipairs(sourceFiles()) do
            local inDir = false
            for _, dir in ipairs(dirs) do
                inDir = inDir or path:sub(1, #dir) == dir
            end
            if not listed[path] and not inDir then
                missing[#missing + 1] = path
            end
        end
        assert.are.same({}, missing)
    end)

    it("names only files that exist", function()
        local exists = {}
        for _, path in ipairs(sourceFiles()) do
            exists[path] = true
        end
        local gone = {}
        for path in pairs(listed) do
            if not exists[path] then
                gone[#gone + 1] = path
            end
        end
        table.sort(gone)
        assert.are.same({}, gone)
    end)
end)
