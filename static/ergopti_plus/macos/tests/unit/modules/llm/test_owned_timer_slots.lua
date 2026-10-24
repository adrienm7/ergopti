--- tests/unit/modules/llm/test_owned_timer_slots.lua

--- Replays the shared owned timer slots and checks both dependency checkers use them.
local helpers = require("tests.helpers")
local Contract = require("test.owned_timer_slots_contract")
Contract.register(helpers)
Contract.register_sources(helpers, {
	helpers.driver_root() .. "/modules/llm/mlx_deps_checker.lua",
	helpers.driver_root() .. "/modules/llm/ollama_deps_checker.lua",
})
