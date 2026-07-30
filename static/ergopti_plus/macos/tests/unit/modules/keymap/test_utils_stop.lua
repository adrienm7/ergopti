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
package.loaded["lib.logger"]           = nil
helpers.load_with_stubs("lib.logger")

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
		local ok = pcall(KU.stop)
		helpers.assert_true(ok, "M.stop() must not throw before any watcher is armed")
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
	helpers.it("stop() calls stop() on the app watcher and unsubscribe() on the window filter", function()
		-- Reload module so watchers are in a clean nil state
		package.loaded["modules.keymap.utils"] = nil
		local KU2 = helpers.load_with_stubs("modules.keymap.utils")

		local app_stopped   = false
		local filter_unsub  = false

		-- Inject mock watchers by triggering ensure_ignored_win_watchers() via
		-- is_ignored_window() with a mock hs.application.watcher.new that
		-- returns our controlled object.
		local orig_app_watcher_new = hs.application.watcher.new
		local orig_window_filter   = hs.window.filter

		hs.application.watcher.new = function(cb)
			return {
				start  = function(self) return self end,
				stop   = function(self) app_stopped = true end,
			}
		end

		-- The filter stub used by load_with_stubs already provides .default;
		-- replace subscribe/unsubscribe so we can track them.
		local mock_filter = {
			subscribe   = function(self, events, cb) self._cb = cb end,
			unsubscribe = function(self, cb) filter_unsub = true end,
		}
		hs.window.filter.default = mock_filter

		-- Trigger watcher creation
		KU2.is_ignored_window({}, {}, 0)

		-- Now stop
		KU2.stop()

		-- Restore stubs
		hs.application.watcher.new = orig_app_watcher_new
		hs.window.filter            = orig_window_filter

		helpers.assert_true(app_stopped,  "M.stop() must call stop() on the application watcher")
		helpers.assert_true(filter_unsub, "M.stop() must call unsubscribe() on the window filter")
	end)
end)
