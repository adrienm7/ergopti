--- tests/unit/modules/keystats/lifecycle/test_stop_nils_win_filter.lua

--- ==============================================================================
--- MODULE: Keystats Stop Nils Watcher Handles Regression Test
--- DESCRIPTION:
--- Guards against the regression where keystats/init.lua stopped the browser
--- window watcher but did not nil its handle afterwards. A subsequent M.start()
--- saw a non-nil handle and skipped creating a new watcher, leaving the
--- browser-tab tracker disconnected after a reload. The fix nils each watcher
--- handle (and the other watcher locals) immediately after stopping it.
--- ==============================================================================

local helpers = require("tests.helpers")
local ActivationFixture = require("tests.unit.modules.keystats.lifecycle.test_activation_callback_fail_closed")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local src = helpers.read_driver_source(selector)
	return src
end

local function strip_comments(src)
	local out = {}
	for line in src:gmatch("[^\n]*") do
		if not line:match("^%s*%-%-") then out[#out + 1] = line end
	end
	return table.concat(out, "\n")
end


-- =====================================================================
-- =====================================================================
-- ======= 1/ M.stop() nils watchers after stopping them ===============
-- =====================================================================
-- =====================================================================

helpers.describe("keystats/init.lua: M.stop() nils watcher locals", function()

	helpers.it("browser window watchers are nilled after they stop", function()
		local src = strip_comments(read_source("local function ensure_browser_window_watchers"))
		local release = src:find("local function release_browser_window_watchers", 1, true)
		helpers.assert_true(release ~= nil, "the browser watchers must have one release owner")
		local body = src:sub(release, src:find("\nend\n", release, true))
		helpers.assert_true(body:find("_browser_title_watcher, _browser_title_window_id = nil, nil", 1, true) ~= nil
			and body:find("_browser_app_watcher, _browser_app_watcher_pid = nil, nil", 1, true) ~= nil,
			"each stopped watcher handle must be nilled so a restart rebinds it")
		helpers.assert_true(src:find("run = release_browser_window_watchers", 1, true) ~= nil,
			"M.stop() must run the browser watcher release")
	end)

	helpers.it("retains refused keyboard cleanup and releases it before a restart (keystats-keyboard-cleanup)", function()
		local ctx = ActivationFixture.load_keystats({ keyboard_stop_results = { false, true } })
		helpers.assert_eq(ctx.start_result, true)
		helpers.assert_eq(ctx.keyboard_start_calls, 1)
		helpers.assert_eq(ctx.keystats.stop(), false, "a refused keyboard release must keep stop incomplete")
		helpers.assert_eq(ctx.keyboard_stop_calls, 1)
		helpers.assert_eq(ctx.state.is_enabled, false, "cleanup debt must never keep recording enabled")
		helpers.assert_eq(ctx.keystats.stop(), true, "the next stop must retry the retained keyboard owner")
		helpers.assert_eq(ctx.keyboard_stop_calls, 2)
		helpers.assert_eq(ctx.keystats.stop(), true)
		helpers.assert_eq(ctx.keyboard_stop_calls, 2, "completed cleanup cannot release an owner twice")
		helpers.assert_eq(ctx.keystats.start({ is_paused = function() return false end }), true)
		helpers.assert_eq(ctx.keyboard_start_calls, 2, "a released keyboard owner must be acquired on restart")
		helpers.assert_eq(ctx.keystats.stop(), true)
		helpers.assert_eq(ctx.keyboard_stop_calls, 3)
	end)

	helpers.it("stops the app-activation lifecycle in M.stop()", function()
		local src = strip_comments(read_source("local function ensure_browser_window_watchers"))
		helpers.assert_true(
			src:find("ProcessLifecycle:stop%(%s*%)") ~= nil
				or src:find("ProcessLifecycle%.stop%(%s*%)") ~= nil,
			"M.stop() must stop the delegated app-activation lifecycle")
	end)

end)
