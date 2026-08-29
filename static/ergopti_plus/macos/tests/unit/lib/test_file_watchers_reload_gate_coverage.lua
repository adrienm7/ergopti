--- tests/unit/lib/test_file_watchers_reload_gate_coverage.lua

--- ==============================================================================
--- MODULE: Regression — the reload gate must cover every watched tree, at fire
---         time (file-watchers-reload-gate-coverage)
--- DESCRIPTION:
--- Three holes in the same gate. It exists to stop hs.reload() re-exec'ing
--- init.lua against a half-written tree — the failure that boots into an error
--- and, through repeated reloads, cascades into the keyboard-freezing storm.
---
--- ROOT CAUSE ENCODED:
---   1. The git probe asked only the DRIVER repository. The personal hotstrings
---      tree is usually a separate repository, and a pull there rewrites files
---      this watcher is watching while the driver's own .git sits perfectly
---      idle — so the config repo was completely unguarded.
---   2. The verdict was computed at SCHEDULE time. ui_restore.defer_reload then
---      holds the reload for as long as a UI stays open, and a pull starting
---      during that hold met a decision made before it existed.
---   3. The TOML snapshot cache writes .lua files INSIDE the watched driver
---      tree, so every cache refresh looked like a source edit — and the reload
---      it triggered re-warmed the cache, which wrote again.
---
--- WHY THEY WERE SILENT: each produces a reload, and a reload looks like the
--- driver working. The cost only shows when the reload lands mid-write.
--- ==============================================================================

local helpers = require("tests.helpers")

-- defer_reload HOLDS the callback rather than firing it, which is what it does
-- whenever a UI is open. That hold is the whole window this file is about: with
-- a stub that fires synchronously there is no gap between the decision and the
-- reload, and the fire-time re-check below would pass against the unfixed code.
local _held_reload = nil
package.loaded["infra.ui_restore"] = {
	defer_reload = function(fn) _held_reload = fn; return true end,
	snapshot     = function() end,
	restore      = function() end,
}

--- Releases a reload held behind a notional open UI.
local function release_held_reload()
	local fn = _held_reload
	_held_reload = nil
	if type(fn) == "function" then fn() end
end

local DRIVER_DIR = "/fake/driver/"
local CONFIG_DIR = "/fake/config/"
local CACHE_DIR  = DRIVER_DIR .. "cache/toml_hotstrings"

--- Arms the watchers with a controllable git probe.
--- @param busy_repos table Map of repo path → true for repos reporting a pull.
--- @return table driver
local function arm_watchers(busy_repos)
	local probed = {}
	package.loaded["infra.git_status"] = {
		operation_in_progress = function(dir)
			probed[#probed + 1] = dir
			return busy_repos[dir] == true
		end,
	}
	package.loaded["infra.file_watchers"] = nil
	local FW = require("infra.file_watchers")

	local prev_pw, prev_timer, prev_attr, prev_reload =
		hs.pathwatcher, hs.timer, hs.fs.attributes, hs.reload

	local clock       = 0
	local watch_cbs   = {}
	local captured_fn = nil
	local reloads     = 0

	hs.pathwatcher = { new = function(_p, cb)
		watch_cbs[#watch_cbs + 1] = cb
		local watcher = {}
		function watcher:start() return self end
		function watcher:stop() return nil end
		return watcher
	end }
	hs.timer = {
		doAfter = function(_s, fn) captured_fn = fn; return { stop = function() end } end,
		secondsSinceEpoch = function() return clock end,
	}
	hs.fs.attributes = function(_p) return nil end
	hs.reload = function() reloads = reloads + 1; return true end

	_G.script_watchers = nil
	FW.start({
		hotstrings_dir          = CONFIG_DIR,
		base_dir                = DRIVER_DIR,
		personal_hotstrings_dir = "/fake/personal",
		self_written_files      = {},
		ignored_dirs            = { CACHE_DIR },
		git_roots               = { DRIVER_DIR, CONFIG_DIR },
	})

	-- Past the post-boot FSEvents-replay suppression window.
	clock = 30

	return {
		fire = function(path)
			captured_fn = nil
			for _, cb in ipairs(watch_cbs) do pcall(cb, { path }) end
		end,
		scheduled = function() return captured_fn end,
		settle    = function()
			clock = clock + 10
			if captured_fn then local fn = captured_fn; captured_fn = nil; fn() end
			release_held_reload()
		end,
		-- Runs the settle poll but leaves the reload parked behind the UI hold.
		settle_and_hold = function()
			clock = clock + 10
			if captured_fn then local fn = captured_fn; captured_fn = nil; fn() end
		end,
		release = release_held_reload,
		reloads = function() return reloads end,
		probed  = function() return probed end,
		restore = function()
			hs.pathwatcher, hs.timer, hs.fs.attributes, hs.reload =
				prev_pw, prev_timer, prev_attr, prev_reload
			_G.script_watchers = nil
			package.loaded["infra.git_status"] = nil
			package.loaded["infra.file_watchers"] = nil
		end,
	}
end




-- =================================================================
-- =================================================================
-- ======= 1/ Every watched repository gates the reload ============
-- =================================================================
-- =================================================================

helpers.describe("reload gate: a pull in the CONFIG repo holds the reload", function()
	helpers.it("does not reload while the hotstrings repo is mid-pull", function()
		local w = arm_watchers({ [CONFIG_DIR] = true })

		w.fire(CONFIG_DIR .. "francais.toml")
		w.settle()

		helpers.assert_eq(w.reloads(), 0,
			"a git pull in the personal hotstrings repo rewrites the very files this watcher "
				.. "watches. Probing only the driver repo left it unguarded, and the reload "
				.. "re-exec'd init.lua against a half-updated tree")

		w.restore()
	end)

	helpers.it("still reloads when no watched repo is busy", function()
		local w = arm_watchers({})

		w.fire(CONFIG_DIR .. "francais.toml")
		w.settle()

		helpers.assert_eq(w.reloads(), 1,
			"with every repo idle the reload must fire — a gate that never opens breaks the "
				.. "auto-reload this module exists for")

		w.restore()
	end)
end)




-- =================================================================
-- =================================================================
-- ======= 2/ The verdict is taken at fire time ====================
-- =================================================================
-- =================================================================

helpers.describe("reload gate: the git state is re-checked when the reload finally fires", function()
	helpers.it("aborts a reload whose repo went busy during the UI hold", function()
		local busy = {}
		local w = arm_watchers(busy)

		w.fire(DRIVER_DIR .. "modules/foo.lua")
		helpers.assert_true(w.scheduled() ~= nil, "the change must schedule a reload")

		-- The gate passes, and the reload is handed to defer_reload — which parks
		-- it behind the open UI. THEN a pull starts.
		w.settle_and_hold()
		busy[DRIVER_DIR] = true
		w.release()

		helpers.assert_eq(w.reloads(), 0,
			"defer_reload holds the reload for as long as a UI stays open, so a verdict computed "
				.. "before that wait says nothing about the tree now. A pull that starts during "
				.. "the hold must abort the reload, not be re-exec'd into mid-write")

		w.restore()
	end)
end)




-- =================================================================
-- =================================================================
-- ======= 3/ Our own runtime artefacts are not source =============
-- =================================================================
-- =================================================================

helpers.describe("reload gate: the TOML snapshot cache does not trigger a reload", function()
	helpers.it("ignores a .lua write inside the cache directory", function()
		local w = arm_watchers({})

		w.fire(CACHE_DIR .. "/francais.toml_12345.lua")

		helpers.assert_true(w.scheduled() == nil,
			"the snapshot cache lives inside the watched driver tree and writes .lua files, so "
				.. "every refresh looked like a source edit — and the reload it triggered re-warmed "
				.. "the cache, which wrote again")
		helpers.assert_eq(w.reloads(), 0, "and must not reload")

		w.restore()
	end)

	helpers.it("still reloads on a real .lua source change", function()
		local w = arm_watchers({})

		w.fire(DRIVER_DIR .. "modules/keymap/init.lua")
		w.settle()

		helpers.assert_eq(w.reloads(), 1,
			"a genuine source edit must still reload. The cache sits INSIDE the watched tree, so "
				.. "an exclusion that swallowed the tree would disable the auto-reload entirely")

		w.restore()
	end)
end)

-- Restore the real modules for later test files.
package.loaded["infra.ui_restore"] = nil
package.loaded["infra.git_status"] = nil
package.loaded["infra.file_watchers"] = nil
