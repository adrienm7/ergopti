--- tests/unit/modules/llm/test_owned_timer_slots.lua

--- Replays the shared owned timer slots and checks both dependency checkers use them.
local helpers = require("tests.helpers")
local Contract = require("test.owned_timer_slots_contract")
Contract.register(helpers)
--- Finds one dependency checker by its module header, not by its path.
--- @param header string The checker's MODULE banner.
--- @return function read Returns that one unit's source.
local function unit(header)
	return function() return assert(helpers.read_driver_unit("--- MODULE: " .. header .. "\n")) end
end

Contract.register_sources(helpers, {
	{ name = "the MLX dependencies checker", read = unit("MLX Dependencies Checker") },
	{ name = "the Ollama dependencies checker", read = unit("Ollama Dependencies Checker") },
})
