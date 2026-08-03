--- tests/unit/modules/keymap/test_winfilter_prewarm.lua

--- ==============================================================================
--- MODULE: keymap.utils ignored-window prewarm (regression)
--- DESCRIPTION:
--- Guards the fix for the ~3 s first-keystroke stall that disabled the keyDown tap.
---
--- ROOT CAUSE ENCODED:
--- ensure_ignored_win_watchers() lazily accesses hs.window.filter.default, which
--- enumerates every open window on first use (~3 s cold on a busy desktop). It was
--- armed lazily INSIDE the first keyDown (is_ignored_window), so the enumeration
--- ran on the event-tap callback and blocked it long enough for macOS to disable
--- the tap ("macOS disabled the keyDown event tap — re-enabling"), dropping the
--- keystroke. The field log showed "Slow keydown: 2951.65 ms" immediately followed
--- by the tap-disable warning.
---
--- The fix exposes M.prewarm_ignored_win_watchers() and schedules it from
--- keymap.M.start() on a short hs.timer.doAfter, so the enumeration is paid on a
--- timer callback during the quiet post-boot window — never on the keystroke tap.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["modules.keymap.utils"] = nil
package.loaded["infra.logger"]           = nil
helpers.load_with_stubs("infra.logger")

helpers.describe("keymap.utils prewarm_ignored_win_watchers (winfilter-cold-start)", function()
	helpers.it("exposes M.prewarm_ignored_win_watchers as a function", function()
		local KU = helpers.load_with_stubs("modules.keymap.utils")
		helpers.assert_eq(type(KU.prewarm_ignored_win_watchers), "function",
			"keymap.utils must export prewarm_ignored_win_watchers() to warm the window filter off the tap")
	end)

	helpers.it("arms the window filter + app watcher WITHOUT a keystroke", function()
		package.loaded["modules.keymap.utils"] = nil
		local KU = helpers.load_with_stubs("modules.keymap.utils")

		local app_started   = false
		local filter_subbed = false

		hs.application.watcher.new = function(_cb)
			return { start = function(self) app_started = true; return self end, stop = function() end }
		end
		hs.window.filter.default = {
			subscribe   = function(self, _events, _cb) filter_subbed = true end,
			unsubscribe = function() end,
		}

		-- Prewarm must do exactly what the first is_ignored_window() would have done,
		-- but here it is the ONLY thing called — proving the cold cost is paid off the
		-- keystroke path.
		-- Called directly: a raise fails with the real error. What the guard has to
		-- leave behind is a USABLE module — the boot path calls this defensively, so a
		-- guard that survived by wedging itself would break the call that follows.
		KU.prewarm_ignored_win_watchers()
		helpers.assert_eq(type(KU.prewarm_ignored_win_watchers), "function",
			"and must leave the module callable")
		helpers.assert_true(app_started,   "prewarm must start the application watcher")
		helpers.assert_true(filter_subbed, "prewarm must subscribe the window filter (paying its cold enumeration)")
	end)

	helpers.it("is idempotent — a second prewarm does not re-arm the filter", function()
		package.loaded["modules.keymap.utils"] = nil
		local KU = helpers.load_with_stubs("modules.keymap.utils")

		local sub_count = 0
		hs.application.watcher.new = function(_cb)
			return { start = function(self) return self end, stop = function() end }
		end
		hs.window.filter.default = {
			subscribe   = function() sub_count = sub_count + 1 end,
			unsubscribe = function() end,
		}

		KU.prewarm_ignored_win_watchers()
		KU.prewarm_ignored_win_watchers()
		helpers.assert_eq(sub_count, 1)  -- ensure_ignored_win_watchers() guards against re-arming
	end)
end)

helpers.describe("keymap.M.start schedules the prewarm off the keystroke path", function()
	helpers.it("M.start defers km_utils.prewarm_ignored_win_watchers via hs.timer.doAfter", function()
		-- Selected by a declaration unique to modules/keymap/init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function invalidate_observed_context")
		helpers.assert_true(src ~= nil, "modules/keymap/init.lua source must be locatable")

		-- The prewarm must be scheduled (doAfter), never called inline in M.start —
		-- an inline call would just move the 3 s cost onto the boot path instead.
		local start_pos = src:find("function M.start()", 1, true)
		helpers.assert_true(start_pos ~= nil, "M.start() must exist")
		local prewarm_pos = src:find("km_utils.prewarm_ignored_win_watchers", start_pos, true)
		helpers.assert_true(prewarm_pos ~= nil, "M.start() must reference the prewarm")
		local defer_pos = src:find("hs.timer.doAfter(WINFILTER_PREWARM_SEC", start_pos, true)
		helpers.assert_true(defer_pos ~= nil and defer_pos < prewarm_pos,
			"the prewarm must be wrapped in hs.timer.doAfter(WINFILTER_PREWARM_SEC, …), not called inline")
	end)
end)
