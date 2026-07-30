--- tests/unit/modules/karabiner/test_init_hotkey_defer.lua

--- ==============================================================================
--- MODULE: karabiner.init defers convenience hotkeys off the boot path (regression)
--- DESCRIPTION:
--- The window-management convenience hotkeys (cycle windows, alt-tab windows,
--- alt-tab apps) were bound synchronously inside karabiner.init(), adding their
--- hs.hotkey setup to the critical boot sequence even though nothing on the boot
--- path needs them. They are now bound on a short hs.timer.doAfter so the cost
--- lands after boot. The timer handle is stored so M.stop() can cancel it if a
--- reload happens before it fires (otherwise the pending bind would leak a hotkey
--- the matching stop() disable already skipped as nil).
---
--- Source-level guard: karabiner.init wires many live hs watchers, so the boot
--- path is exercised at integration time, not headlessly — we pin the structural
--- invariants (deferred bind + stop() cancellation) that the optimisation relies on.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("karabiner.init defers the convenience hotkeys", function()
	local function read_src()
		-- Selected by a declaration unique to modules/karabiner/init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function build_paused_ke_config")
		helpers.assert_true(src ~= nil, "modules/karabiner/init.lua source must be locatable")
		return src
	end

	helpers.it("binds the convenience hotkeys inside a doAfter timer, not inline", function()
		local src = read_src()
		local defer_pos = src:find("_deferred_hotkeys_timer = hs.timer.doAfter(HOTKEY_BIND_DEFER_SEC", 1, true)
		helpers.assert_true(defer_pos ~= nil,
			"the convenience hotkeys must be bound on a deferred hs.timer.doAfter(HOTKEY_BIND_DEFER_SEC, …)")

		-- All three hotkey binds must live AFTER the deferral opens (inside the closure).
		for _, fn in ipairs({
			"start_cycle_windows_hotkey",
			"start_alt_tab_windows_hotkey",
			"start_alt_tab_apps_hotkey",
		}) do
			local pos = src:find(fn, defer_pos, true)
			helpers.assert_true(pos ~= nil, fn .. " must be bound inside the deferred closure")
		end
	end)

	helpers.it("guards the deferred closure against a module stopped before it fires", function()
		local src = read_src()
		local defer_pos = src:find("_deferred_hotkeys_timer = hs.timer.doAfter(HOTKEY_BIND_DEFER_SEC", 1, true)
		helpers.assert_true(defer_pos ~= nil, "deferred bind must exist")
		-- The closure must early-return when _state was cleared by a concurrent stop().
		local guard_pos = src:find("if not _state then return end", defer_pos, true)
		local first_bind = src:find("start_cycle_windows_hotkey", defer_pos, true)
		helpers.assert_true(guard_pos ~= nil and guard_pos < first_bind,
			"the deferred closure must check `if not _state then return end` before binding")
	end)

	helpers.it("M.stop() cancels a still-pending deferred hotkey timer", function()
		local src = read_src()
		local stop_pos = src:find("function M.stop()", 1, true)
		helpers.assert_true(stop_pos ~= nil, "M.stop() must exist")
		local cancel_pos = src:find("_deferred_hotkeys_timer", stop_pos, true)
		helpers.assert_true(cancel_pos ~= nil,
			"M.stop() must cancel the pending _deferred_hotkeys_timer so it cannot leak a hotkey post-stop")
		-- The cancellation must :stop() the timer, not merely nil it.
		local stop_call = src:find("_deferred_hotkeys_timer:stop()", stop_pos, true)
		helpers.assert_true(stop_call ~= nil, "M.stop() must call :stop() on the pending timer")
	end)
end)
