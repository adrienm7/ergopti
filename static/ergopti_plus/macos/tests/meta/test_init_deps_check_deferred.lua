--- tests/meta/test_init_deps_check_deferred.lua

--- Structural companion to the behavioral dependency-bootstrap ownership tests.
--- init.lua must register both exact backend owners, then enter through the
--- checker-owned retained zero-delay timer rather than a raw hs.timer callback.

local helpers = require("tests.helpers")

helpers.describe("boot: LLM deps check uses its registered retained owner", function()
	local function read_init()
		local src = helpers.read_driver_source("local function has_common_hotstring_groups")
		helpers.assert_true(src ~= nil, "init.lua source must be locatable")
		return src
	end

	helpers.it("registers both backend owners before scheduling either backend", function()
		local src = read_init()
		local mlx_owner = src:find(
			"mlx_deps_checker.configure_pause_owner(shortcuts)", 1, true)
		local ollama_owner = src:find(
			"ollama_deps_checker.configure_pause_owner(shortcuts)", 1, true)
		local schedule = src:find("selected_checker.schedule_initial_check", 1, true)
		helpers.assert_true(mlx_owner ~= nil and ollama_owner ~= nil and schedule ~= nil)
		helpers.assert_true(mlx_owner < schedule and ollama_owner < schedule,
			"both exact owners must register before the first dependency intent")
	end)

	helpers.it("does not retain a raw boot timer or call either checker directly", function()
		local src = read_init()
		local block_start = src:find("if boot_llm_enabled then", 1, true)
		local block_end = src:find("Boot.mark(\"LLM backend bootstrap\")", block_start, true)
		helpers.assert_true(block_start ~= nil and block_end ~= nil)
		local block = src:sub(block_start, block_end)
		helpers.assert_true(block:find("hs.timer.doAfter", 1, true) == nil,
			"the checker, not init.lua, must own the zero-delay native timer")
		helpers.assert_true(block:find("deps_checker.check_and_install_deps") == nil,
			"init.lua must enter through the retained scheduling capability")
	end)
end)
