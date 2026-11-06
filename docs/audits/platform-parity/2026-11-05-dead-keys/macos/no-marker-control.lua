-- Removes one optional empty-event seed from test scaffolding only.
-- Original public-probe.lua and every production function remain byte-unchanged.
local program = assert(arg[2], "original public probe required")
local file = assert(io.open(program, "rb"))
local source = file:read("*a"); file:close()
local seed = ' if register then table.insert(events,1,{"",14}) end'
local first, last = assert(source:find(seed, 1, true))
assert(not source:find(seed, last + 1, true), "seed must occur exactly once")
local scaffold = source:sub(1, first - 1) .. source:sub(last + 1)
assert(load(scaffold, "@no-marker-public-probe-scaffold", "t"))()
