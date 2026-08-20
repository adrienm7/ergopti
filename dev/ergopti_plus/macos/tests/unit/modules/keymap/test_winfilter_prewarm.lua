--- tests/unit/modules/keymap/test_winfilter_prewarm.lua

--- ==============================================================================
--- MODULE: keymap.utils scoped ignored-window watcher preparation (regression)
--- DESCRIPTION:
--- The old fix merely moved hs.window.filter.default's cold global enumeration
--- into a timer. Timers and eventtaps share Hammerspoon's runloop, so a key that
--- arrived during that callback could still wait behind the measured ~3 s cost.
--- The production path must instead bind AX watchers only to the current app and
--- focused window, and it must do so before the keyDown tap is armed.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["modules.keymap.utils"] = nil
package.loaded["infra.logger"] = nil
helpers.load_with_stubs("infra.logger")


local function install_scoped_watcher_fixture()
	local state = { global = 0, focus = 0, title = 0, filter_reads = 0 }
	hs.application.watcher.new = function()
		return {
			start = function(self) state.global = state.global + 1; return self end,
			stop = function(self) return self end,
		}
	end
	local function ui_watcher(kind)
		return {
			start = function(self) state[kind] = state[kind] + 1; return self end,
			stop = function(self) return self end,
		}
	end
	local app = {
		pid = function() return 9001 end,
		name = function() return "Test Editor" end,
		newWatcher = function() return ui_watcher("focus") end,
	}
	hs.window.focusedWindow = function()
		return {
			id = function() return 42 end,
			application = function() return app end,
			title = function() return "Normal Editor" end,
			newWatcher = function() return ui_watcher("title") end,
		}
	end
	hs.window.filter = setmetatable({}, {
		__index = function(_, key)
			if key == "default" then
				state.filter_reads = state.filter_reads + 1
				error("global window enumeration is forbidden")
			end
		end,
	})
	return state
end


helpers.describe("keymap.utils scoped ignored-window watcher preparation", function()
	helpers.it("exposes M.prewarm_ignored_win_watchers as a function", function()
		local KU = helpers.load_with_stubs("modules.keymap.utils")
		helpers.assert_eq(type(KU.prewarm_ignored_win_watchers), "function",
			"keymap.utils must export the lifecycle preparation boundary")
	end)

	helpers.it("binds only current app/window watchers and never reads window.filter.default", function()
		package.loaded["modules.keymap.utils"] = nil
		local KU = helpers.load_with_stubs("modules.keymap.utils")
		local state = install_scoped_watcher_fixture()
		KU.start_ignored_win_tracking({}, {})
		helpers.assert_true(KU.prewarm_ignored_win_watchers({}, {}))
		helpers.assert_eq(state.global, 1, "preparation must start one app activation watcher")
		helpers.assert_eq(state.focus, 1, "preparation must watch focus only in the current app")
		helpers.assert_eq(state.title, 1, "preparation must watch only the current window title")
		helpers.assert_eq(state.filter_reads, 0,
			"the global window filter must remain completely untouched")
	end)

	helpers.it("is idempotent for unchanged app/window ownership", function()
		package.loaded["modules.keymap.utils"] = nil
		local KU = helpers.load_with_stubs("modules.keymap.utils")
		local state = install_scoped_watcher_fixture()
		KU.start_ignored_win_tracking({}, {})
		helpers.assert_true(KU.prewarm_ignored_win_watchers({}, {}))
		helpers.assert_true(KU.prewarm_ignored_win_watchers({}, {}))
		helpers.assert_eq(state.global, 1)
		helpers.assert_eq(state.focus, 1)
		helpers.assert_eq(state.title, 1)
	end)
end)


helpers.describe("keymap.M.start prepares ownership before key capture", function()
	helpers.it("calls watcher preparation before tap:start()", function()
		local src = helpers.read_driver_source("local function invalidate_observed_context")
		helpers.assert_true(src ~= nil, "modules/keymap/init.lua source must be locatable")
		local start_pos = src:find("function M.start()", 1, true)
		helpers.assert_true(start_pos ~= nil, "M.start() must exist")
		local prewarm_pos = src:find("km_utils.prewarm_ignored_win_watchers", start_pos, true)
		helpers.assert_true(prewarm_pos ~= nil, "M.start() must prepare window ownership")
		local tap_start_pos = src:find("for _, spec in ipairs(tap_specs) do", prewarm_pos, true)
		helpers.assert_true(tap_start_pos ~= nil and prewarm_pos < tap_start_pos,
			"scoped watcher preparation must settle before the keyDown tap is armed")
	end)
end)
