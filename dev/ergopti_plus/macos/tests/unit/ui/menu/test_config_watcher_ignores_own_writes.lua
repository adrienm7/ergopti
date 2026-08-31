--- tests/unit/ui/menu/test_config_watcher_ignores_own_writes.lua

--- ==============================================================================
--- MODULE: Regression — the config watcher must not reload on the driver's own
---         cache writes
--- DESCRIPTION:
--- Two independent RECURSIVE pathwatchers cover the same tree, and only one
--- carries exclusions. `infra/file_watchers.lua` filters out runtime artefacts and is
--- fed `ignored_dirs = { TOML_CACHE_DIR }`. `ui/menu/menu_watchers.lua` arms a
--- second recursive watcher on the same `base_dir` whose entire filter is
--- ".lua or .toml, not under logs/, not paths.toml" — no ignored directories at
--- all — and its reaction is a FULL driver reload.
---
--- The TOML snapshot cache writes files named `<base>_<hash>.lua` into
--- `<configdir>/cache/toml_hotstrings`. Under the symlink/copy layout that
--- directory is inside the watched tree, so every snapshot write matches ".lua",
--- the watcher fires, the driver reloads, the reload re-parses and re-writes
--- snapshots, and the cycle repeats. `paths.toml` is already excluded with a
--- comment describing exactly this loop — the same reasoning was never applied to
--- the cache the driver writes far more often.
---
--- ROOT CAUSE ENCODED:
--- Two watchers on one tree with one set of exclusions between them. The
--- assertion drives the real callback with a real cache path and asks whether a
--- reload was armed, so it is about the behaviour and not about the filter's shape.
--- ==============================================================================

local helpers = require("tests.helpers")

local BASE_DIR  = "/fake/ergopti"
local CACHE_DIR = BASE_DIR .. "/cache/toml_hotstrings"


--- Loads menu_watchers with the timer captured so the test can see whether a
--- reload was armed without waiting for one.
--- @return table Watchers, function armed_count
local function load_watchers()
	package.loaded["ui.menu.menu_watchers"] = nil
	package.loaded["infra.logger"] = nil
	_ = helpers.load_with_stubs("infra.logger")

	local armed = { n = 0 }
	local Watchers = helpers.load_with_stubs("ui.menu.menu_watchers", {
		timer = {
			-- Every settle/debounce arm goes through here. Counting arms is the
			-- observable "the watcher decided this was a source change".
			doAfter = function(_d, _fn) armed.n = armed.n + 1
				return { stop = function() end, running = function() return true end } end,
			delayed = { new = function(_d, _fn)
				return { start = function() armed.n = armed.n + 1 end, stop = function() end } end },
			secondsSinceEpoch = function() return 10000 end,
		},
		pathwatcher = {
			new = function(_dir, cb)
				local watcher = { _cb = cb }
				function watcher:start() return self end
				function watcher:stop() return nil end
				return watcher
			end,
		},
	})
	return Watchers, function() return armed.n end
end


--- Starts the watcher and returns the callback the pathwatcher was handed.
--- @param Watchers table
--- @return function|nil
local function captured_callback(Watchers)
	local captured
	local real_new = _G.hs.pathwatcher.new
	_G.hs.pathwatcher.new = function(dir, cb)
		captured = cb
		local watcher = {}
		function watcher:start() return self end
		function watcher:stop() return nil end
		return watcher
	end
	Watchers.start_config_watcher(BASE_DIR, function() end, function() return 0 end,
		{ defer_reload = function(fn) fn() end, is_reloading = function() return false end },
		{ CACHE_DIR })
	_G.hs.pathwatcher.new = real_new
	return captured
end




-- ==================================================================
-- ==================================================================
-- ======= 1/ The driver's own artefacts arm nothing ================
-- ==================================================================
-- ==================================================================

helpers.describe("config watcher: the driver's own cache writes arm no reload", function()

	helpers.it("ignores a TOML snapshot write", function()
		local Watchers, armed = load_watchers()
		local cb = captured_callback(Watchers)
		helpers.assert_type(cb, "function",
			"the watcher must hand a callback to hs.pathwatcher.new, or there is nothing "
			.. "for this test to drive")

		local before = armed()
		cb({ CACHE_DIR .. "/hotstrings_123456.lua" })

		helpers.assert_eq(armed(), before,
			"the snapshot cache is written BY this driver, and its files end in .lua — the "
			.. "one extension this watcher treats as a source change. Under the symlink/copy "
			.. "layout the cache sits inside the watched tree, so a write reloads the driver, "
			.. "the reload re-parses and re-writes snapshots, and the cycle repeats. "
			.. "paths.toml is already excluded with a comment describing exactly this loop")
	end)

	helpers.it("still reacts to a real source change", function()
		-- Without this case the assertion above would pass against a watcher that
		-- ignores everything, i.e. one that never reloads on an edit at all.
		local Watchers, armed = load_watchers()
		local cb = captured_callback(Watchers)

		local before = armed()
		cb({ BASE_DIR .. "/modules/keymap/init.lua" })

		helpers.assert_true(armed() > before,
			"an edit to a real source file must still arm a reload")
	end)

	helpers.it("keeps ignoring logs and paths.toml", function()
		local Watchers, armed = load_watchers()
		local cb = captured_callback(Watchers)

		local before = armed()
		cb({ BASE_DIR .. "/logs/today.lua" })
		cb({ BASE_DIR .. "/paths.toml" })

		helpers.assert_eq(armed(), before,
			"the two exclusions that already existed must survive the change")
	end)

end)
