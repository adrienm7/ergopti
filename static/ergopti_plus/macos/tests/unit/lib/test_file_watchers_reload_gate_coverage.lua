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

local Fixture = require("tests.support.file_watcher_self_write_fixture")

local DRIVER_DIR = "/fake/driver/"
local CONFIG_DIR = "/fake/config/"
local CACHE_DIR  = DRIVER_DIR .. "cache/toml_hotstrings"

--- Runs one scenario with its own Git state and deferred UI callback.
--- @param busy_repos table Repositories currently being written.
--- @param body function Watcher scenario.
local function with_watchers(busy_repos, body)
	local held
	Fixture.with_watchers(function(w)
		w.release = function()
			local callback = held
			held = nil
			if callback then callback() end
		end
		w.settle_and_hold = w.settle
		w.settle = function()
			w.settle_and_hold()
			w.release()
		end
		return body(w)
	end, {
		git_probe = function(dir) return busy_repos[dir] == true end,
		defer_reload = function(callback) held = callback; return true end,
		context = {
			hotstrings_dir = CONFIG_DIR,
			base_dir = DRIVER_DIR,
			personal_hotstrings_dir = "/fake/personal",
			self_written_files = {},
			ignored_dirs = { CACHE_DIR },
			git_roots = { DRIVER_DIR, CONFIG_DIR },
		},
	})
end



-- =================================================================
-- =================================================================
-- ======= 1/ Every watched repository gates the reload ============
-- =================================================================
-- =================================================================

helpers.describe("reload gate: a pull in the CONFIG repo holds the reload", function()
	helpers.it("does not reload while the hotstrings repo is mid-pull", function()
		with_watchers({ [CONFIG_DIR] = true }, function(w)

			w.fire(CONFIG_DIR .. "francais.toml")
			w.settle()

			helpers.assert_eq(w.reloads(), 0,
				"a git pull in the personal hotstrings repo rewrites the very files this watcher "
					.. "watches. Probing only the driver repo left it unguarded, and the reload "
					.. "re-exec'd init.lua against a half-updated tree")

		end)
	end)

	helpers.it("still reloads when no watched repo is busy", function()
		with_watchers({}, function(w)

			w.fire(CONFIG_DIR .. "francais.toml")
			w.settle()

			helpers.assert_eq(w.reloads(), 1,
				"with every repo idle the reload must fire — a gate that never opens breaks the "
					.. "auto-reload this module exists for")

		end)
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
		with_watchers(busy, function(w)

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

		end)
	end)
end)




-- =================================================================
-- =================================================================
-- ======= 3/ Our own runtime artefacts are not source =============
-- =================================================================
-- =================================================================

helpers.describe("reload gate: the TOML snapshot cache does not trigger a reload", function()
	helpers.it("ignores a .lua write inside the cache directory", function()
		with_watchers({}, function(w)

			w.fire(CACHE_DIR .. "/francais.toml_12345.lua")

			helpers.assert_true(w.scheduled() == nil,
				"the snapshot cache lives inside the watched driver tree and writes .lua files, so "
					.. "every refresh looked like a source edit — and the reload it triggered re-warmed "
					.. "the cache, which wrote again")
			helpers.assert_eq(w.reloads(), 0, "and must not reload")

		end)
	end)

	helpers.it("still reloads on a real .lua source change", function()
		with_watchers({}, function(w)

			w.fire(DRIVER_DIR .. "modules/keymap/init.lua")
			w.settle()

			helpers.assert_eq(w.reloads(), 1,
				"a genuine source edit must still reload. The cache sits INSIDE the watched tree, so "
					.. "an exclusion that swallowed the tree would disable the auto-reload entirely")

		end)
	end)
end)
