--- tests/unit/modules/keymap/test_utils_stop.lua

--- ==============================================================================
--- MODULE: keymap.utils M.stop() Regression Tests
--- DESCRIPTION:
--- Guards the "watcher-leak-on-reload" fix in modules/keymap/utils.lua.
---
--- ROOT CAUSE ENCODED:
--- ensure_ignored_win_watchers() subscribed an application watcher and a
--- window-filter callback but no M.stop() existed to clean them up. Each
--- Hammerspoon reload added a duplicate subscription to the shared
--- hs.window.filter.default global. Over several reloads this caused a
--- measurable performance degradation and potential double-invalidations.
---
--- The fix adds M.stop(), which calls :stop() on the app watcher and
--- :unsubscribe() on the window filter, then nils both references and marks
--- the cache dirty so the next is_ignored_window() call re-arms fresh watchers.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Reload the module fresh so watchers are not already running from a prior test.
package.loaded["modules.keymap.utils"] = nil
package.loaded["infra.logger"]           = nil
helpers.load_with_stubs("infra.logger")

local KU = helpers.load_with_stubs("modules.keymap.utils")





-- =================================================
-- =================================================
-- ======= 1/ M.stop() existence & signature =======
-- =================================================
-- =================================================

helpers.describe("keymap.utils M.stop(): existence (watcher-leak-on-reload)", function()
	helpers.it("M.stop is a function", function()
		helpers.assert_eq(type(KU.stop), "function",
			"keymap.utils must export M.stop() (watcher-leak-on-reload)")
	end)

	helpers.it("M.stop() does not raise when no watchers are running", function()
		-- Called directly: a raise fails with the real error. What the guard has to
		-- leave behind is a USABLE module — the boot path calls this defensively, so a
		-- guard that survived by wedging itself would break the call that follows.
		KU.stop()
		helpers.assert_eq(type(KU.stop), "function",
			"and must leave the module callable")
	end)

	helpers.it("M.stop() is idempotent — safe to call twice", function()
		local ok1 = pcall(KU.stop)
		local ok2 = pcall(KU.stop)
		helpers.assert_true(ok1 and ok2, "M.stop() must be safe to call multiple times")
	end)
end)





-- ==========================================================
-- ==========================================================
-- ======= 2/ Watcher cleanup via injected mock stubs =======
-- ==========================================================
-- ==========================================================

helpers.describe("keymap.utils M.stop(): cleans up injected watchers (watcher-leak-on-reload)", function()
	helpers.it("stop() releases the global, focused-app, and focused-window watchers", function()
		-- Reload module so watchers are in a clean nil state
		package.loaded["modules.keymap.utils"] = nil
		local KU2 = helpers.load_with_stubs("modules.keymap.utils")

		local app_stopped   = false
		local focus_stopped = false
		local title_stopped = false
		local app_callback  = nil
		local focus_callback = nil
		local title_callback = nil

		-- Inject mock watchers by triggering ensure_ignored_win_watchers() via
		-- is_ignored_window() with a mock hs.application.watcher.new that
		-- returns our controlled object.
		local orig_app_watcher_new = hs.application.watcher.new
		local orig_focused_window = hs.window.focusedWindow

		hs.application.watcher.new = function(cb)
			app_callback = cb
			return {
				start  = function(self) return self end,
				stop   = function(self) app_stopped = true end,
			}
		end

		hs.window.focusedWindow = function()
			local app = {
				pid = function() return 9001 end,
				name = function() return "Test App" end,
				newWatcher = function(_self, callback)
					focus_callback = callback
					return {
						start = function(self) return self end,
						stop = function(self) focus_stopped = true; return self end,
					}
				end,
			}
			return {
				id = function() return 17 end,
				application = function() return app end,
				newWatcher = function(_self, callback)
					title_callback = callback
					return {
						start = function(self) return self end,
						stop = function(self) title_stopped = true; return self end,
					}
				end,
				title = function() return "Normal Editor" end,
			}
		end

		-- Watcher construction is deliberately off the keyDown callback. Prewarm is
		-- the production boot path that performs this cold setup.
		helpers.assert_eq(type(KU2.start_ignored_win_tracking({}, {})), "number",
			"the lifecycle owner must open tracking before prewarm")
		helpers.assert_true(KU2.prewarm_ignored_win_watchers({}, {}),
			"the fixture must install live watchers before exercising teardown")

		-- Now stop
		KU2.stop()
		local timer_count_after_stop = #hs.timer.__timers
		-- A native callback already queued before unsubscribe may still arrive. It
		-- must observe the stopped latch and never recreate refresh work post-teardown.
		if app_callback then app_callback("Test", hs.application.watcher.activated, {}) end
		if focus_callback then focus_callback() end
		if title_callback then title_callback() end
		local timer_count_after_stale_callbacks = #hs.timer.__timers

		-- Restore stubs
		hs.application.watcher.new = orig_app_watcher_new
		hs.window.focusedWindow     = orig_focused_window

		helpers.assert_true(app_stopped,  "M.stop() must call stop() on the application watcher")
		helpers.assert_true(focus_stopped, "M.stop() must stop the focused-app AX watcher")
		helpers.assert_true(title_stopped, "M.stop() must stop the focused-window title watcher")
		helpers.assert_true(type(app_callback) == "function"
			and type(focus_callback) == "function" and type(title_callback) == "function",
			"prewarm must install all callbacks before teardown is exercised")
		helpers.assert_eq(timer_count_after_stale_callbacks, timer_count_after_stop,
			"queued watcher callbacks must not arm a new AX refresh after stop")
	end)
end)
