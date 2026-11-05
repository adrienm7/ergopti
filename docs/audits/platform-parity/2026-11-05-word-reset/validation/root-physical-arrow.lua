-- Extend the retained audit fixture with one matched-default physical control.
-- Only fixture invocations are added; production source bodies stay unchanged.
local here = assert(debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$"))
local path = here .. "/../linux/continuity-probe.lua"
local file = assert(io.open(path, "rb"))
local source = file:read("*a"); file:close()
local function insert_before(marker, addition)
    local first = assert(source:find(marker, 1, true), "fixture marker must exist")
    assert(not source:find(marker, first + 1, true), "fixture marker must be unique")
    source = source:sub(1, first - 1) .. addition .. source:sub(first)
end
insert_before("local by = {};", [[
run("root_both_default_physical_arrow", { tokens = { "a", "b", "left", "c" } })
]])
insert_before('print(assert(require("json").encode(', [[
assert(by.root_both_default_physical_arrow.word == "c")
assert(by.root_both_default_physical_arrow.context == "c")
]])
assert(loadstring and loadstring(source, "@" .. path) or load(source, "@" .. path))()
