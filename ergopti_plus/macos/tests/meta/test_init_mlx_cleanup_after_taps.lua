--- tests/meta/test_init_mlx_cleanup_after_taps.lua

--- ==============================================================================
--- MODULE: Regression - asynchronous MLX cleanup and bootstrap ordering
--- DESCRIPTION:
--- Script control must exist before cleanup starts, the cleanup itself must not
--- block the Hammerspoon run loop, and LLM bootstrap admission must wait for the
--- cleanup's exact terminal callback instead of racing it on a zero-delay timer.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_init_src()
	local src = helpers.read_driver_source("local function has_common_hotstring_groups")
	helpers.assert_true(src ~= nil, "init.lua source must be locatable")
	return src
end

local function read_cleanup_src()
	local src = helpers.read_driver_source("function M.run_selective_cleanup(on_done)")
	helpers.assert_true(src ~= nil, "boot_cleanup.lua source must be locatable")
	return src
end

local function assert_async_cleanup(src)
	helpers.assert_true(src:find('require("adapters.shell_runner")', 1, true) ~= nil,
		"boot cleanup must depend on the asynchronous ShellRunner adapter")
	helpers.assert_true(src:find("ShellRunner.spawn", 1, true) ~= nil,
		"boot cleanup must spawn its shell pipeline")
	helpers.assert_true(src:find("handle.start", 1, true) ~= nil,
		"the spawned cleanup task must cross its explicit start boundary")
	helpers.assert_true(src:find("hs.execute", 1, true) == nil,
		"boot cleanup must never execute a subprocess synchronously")
end

local function assert_bootstrap_gate(src)
	local cleanup_call = src:find("run_selective_cleanup(settle_mlx_cleanup)", 1, true)
	local bootstrap_fn = src:find("local function start_llm_bootstrap()", 1, true)
	local pending_assignment = src:find("pending_llm_bootstrap = start_llm_bootstrap", 1, true)
	local pending_delivery = src:find('"Deferred LLM bootstrap", pending', 1, true)
	helpers.assert_true(cleanup_call ~= nil, "init.lua must observe the exact cleanup terminal")
	helpers.assert_true(bootstrap_fn ~= nil, "init.lua must own one LLM bootstrap function")
	helpers.assert_true(pending_assignment ~= nil,
		"LLM bootstrap must remain pending while cleanup is in flight")
	helpers.assert_true(pending_delivery ~= nil,
		"cleanup settlement must deliver the pending LLM bootstrap")
	helpers.assert_true(cleanup_call < bootstrap_fn and bootstrap_fn < pending_assignment,
		"cleanup must start before bootstrap can be admitted or queued")

	local cleanup_block_start = src:find("local mlx_cleanup_enabled", 1, true)
	local cleanup_block_end = src:find('Boot.mark("MLX server cleanup', cleanup_block_start, true)
	helpers.assert_true(cleanup_block_start ~= nil and cleanup_block_end ~= nil,
		"MLX cleanup boot block must be bounded by stable anchors")
	local cleanup_block = src:sub(cleanup_block_start, cleanup_block_end)
	helpers.assert_true(cleanup_block:find("hs.timer.doAfter", 1, true) == nil,
		"async cleanup must start directly without a raw zero-delay timer owner")
end

helpers.describe("HS-195: MLX cleanup is asynchronous and orders LLM bootstrap", function()
	helpers.it("keeps script control armed before starting MLX cleanup", function()
		local src = read_init_src()
		local script_control_pos = src:find(
			"start_script_control(keymap, shortcuts, gestures, karabiner)", 1, true)
		local cleanup_pos = src:find("run_selective_cleanup", 1, true)
		helpers.assert_true(script_control_pos ~= nil and cleanup_pos ~= nil,
			"both script control and MLX cleanup calls must exist")
		helpers.assert_true(script_control_pos < cleanup_pos,
			"panic-button script control must exist before MLX cleanup starts")
	end)

	helpers.it("uses an asynchronous task and an exact bootstrap gate", function()
		assert_async_cleanup(read_cleanup_src())
		assert_bootstrap_gate(read_init_src())
	end)

	helpers.it("the guards reject the former blocking and racing shapes", function()
		local cleanup_mutant = read_cleanup_src():gsub("ShellRunner%.spawn", "hs.execute", 1)
		helpers.assert_throws(function() assert_async_cleanup(cleanup_mutant) end,
			"the async guard must fail if synchronous execution returns")

		local gate_mutant = read_init_src():gsub(
			"pending_llm_bootstrap = start_llm_bootstrap", "start_llm_bootstrap()", 1)
		helpers.assert_throws(function() assert_bootstrap_gate(gate_mutant) end,
			"the ordering guard must fail if bootstrap races an in-flight cleanup")
	end)

	helpers.it("keeps keymap startup before the menu startup", function()
		local src = read_init_src()
		local keymap_start_pos = src:find("keymap.start()", 1, true)
		local menu_start_pos = src:find("menu.start(", 1, true)
		helpers.assert_true(keymap_start_pos ~= nil and menu_start_pos ~= nil,
			"init.lua must call both keymap.start() and menu.start()")
		helpers.assert_true(keymap_start_pos < menu_start_pos,
			"MLX cleanup changes must not reorder downstream input and menu startup")
	end)
end)
