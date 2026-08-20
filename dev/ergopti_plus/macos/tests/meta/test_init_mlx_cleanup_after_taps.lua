--- tests/meta/test_init_mlx_cleanup_after_taps.lua

--- ==============================================================================
--- MODULE: Regression — MLX boot cleanup deferred off the boot critical path (F-HIGH-12)
--- DESCRIPTION:
--- boot_cleanup.run_selective_cleanup() embeds a synchronous hs.execute() shell
--- pipeline (lsof + curl --max-time 1 + a 0.3s sleep on the nuke branch). Before
--- this fix it ran SYNCHRONOUSLY at init.lua boot time, BEFORE keymap.start()
--- (the typing eventtap) and BEFORE shortcuts.start_script_control() (the
--- AltGr+Enter/Backspace/Escape panic-button tap) — a slow/unhealthy prior MLX
--- server session extended that window arbitrarily, and the user's one recourse
--- (the panic button) did not exist yet either.
---
--- Fix: (1) the run_selective_cleanup() call is now wrapped in
--- hs.timer.doAfter(0, ...), so it fires on the next run-loop tick — strictly
--- after init.lua's synchronous body (including keymap.start()) has finished
--- executing. (2) start_script_control() was moved earlier, into Section 1
--- (Module Pre-start), so the panic button exists before ANY of the slow boot
--- steps (MLX cleanup, LLM bootstrap, TOML loading, keymap.start()) — see
--- F-MED-19, whose boot-order change is coordinated with this one.
---
--- Test: source-position scan asserting:
---   1. start_script_control() appears before keymap.start() in init.lua.
---   2. run_selective_cleanup() appears after start_script_control().
---   3. The run_selective_cleanup() call is wrapped in hs.timer.doAfter(0, ...)
---      rather than invoked directly, so it can never re-introduce a
---      synchronous block on the boot critical path even if a future edit
---      moves the byte position around.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_init_src()
	-- Selected by a declaration unique to init.lua rather than by
	-- path, so moving or splitting the module cannot turn this invariant
	-- into a path error.
	local src = helpers.read_driver_source("local function has_common_hotstring_groups")
	helpers.assert_true(src ~= nil, "init.lua source must be locatable")
	return src
end

helpers.describe("F-HIGH-12 + F-MED-19: MLX cleanup deferred, panic button armed early", function()

	helpers.it("start_script_control() appears before keymap.start() in init.lua", function()
		local src = read_init_src()

		local script_control_pos = src:find("start_script_control(keymap, shortcuts, gestures, karabiner)", 1, true)
		local keymap_start_pos   = src:find("keymap.start()", 1, true)

		helpers.assert_true(script_control_pos ~= nil,
			"init.lua must call shortcuts.start_script_control(...)")
		helpers.assert_true(keymap_start_pos ~= nil,
			"init.lua must call keymap.start()")
		helpers.assert_true(script_control_pos < keymap_start_pos,
			"start_script_control() must be armed BEFORE keymap.start() so the panic button " ..
			"exists for the entire remainder of a slow boot (F-MED-19)")
	end)

	helpers.it("run_selective_cleanup() is called after start_script_control() in init.lua", function()
		local src = read_init_src()

		local script_control_pos = src:find("start_script_control(keymap, shortcuts, gestures, karabiner)", 1, true)
		local cleanup_pos        = src:find("run_selective_cleanup()", 1, true)

		helpers.assert_true(script_control_pos ~= nil,
			"init.lua must call shortcuts.start_script_control(...)")
		helpers.assert_true(cleanup_pos ~= nil,
			"init.lua must call boot_cleanup.run_selective_cleanup()")
		helpers.assert_true(script_control_pos < cleanup_pos,
			"run_selective_cleanup() must be scheduled AFTER start_script_control() (F-HIGH-12/F-MED-19)")
	end)

	helpers.it("run_selective_cleanup() is wrapped in hs.timer.doAfter(0, ...), not called inline", function()
		local src = read_init_src()

		local cleanup_pos = src:find("run_selective_cleanup()", 1, true)
		helpers.assert_true(cleanup_pos ~= nil, "init.lua must call boot_cleanup.run_selective_cleanup()")

		-- The nearest preceding hs.timer.doAfter(0, must be closer than the nearest
		-- preceding top-level "if mlx_cleanup_enabled then" body start — i.e. the
		-- call must be wrapped in a deferred tick, not invoked directly on the
		-- synchronous boot path.
		local search_window = src:sub(math.max(1, cleanup_pos - 400), cleanup_pos)
		helpers.assert_true(search_window:find("hs.timer.doAfter(0,", 1, true) ~= nil,
			"run_selective_cleanup() must be wrapped in hs.timer.doAfter(0, ...) so the synchronous " ..
			"lsof+curl+sleep shell pipeline never blocks the boot critical path (F-HIGH-12)")
	end)

	helpers.it("keymap.start() appears before menu.start() (sanity: boot order unchanged downstream)", function()
		local src = read_init_src()
		local keymap_start_pos = src:find("keymap.start()", 1, true)
		local menu_start_pos   = src:find("menu.start(", 1, true)
		helpers.assert_true(keymap_start_pos ~= nil and menu_start_pos ~= nil,
			"init.lua must call both keymap.start() and menu.start(...)")
		helpers.assert_true(keymap_start_pos < menu_start_pos,
			"keymap.start() must still run before menu.start() — this fix must not reorder unrelated boot steps")
	end)
end)
