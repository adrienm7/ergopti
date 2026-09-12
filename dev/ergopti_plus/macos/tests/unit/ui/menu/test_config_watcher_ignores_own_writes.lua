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
local Fixture = require("tests.support.menu_config_watcher_fixture")


local BASE_DIR  = "/fake/ergopti"
local CACHE_DIR = BASE_DIR .. "/cache/toml_hotstrings"


--- Runs one cache-filter scenario with isolated native state.
--- @param body function Scenario receiving captured events and timer counts.
local function with_watcher(body)
	Fixture.with_watcher(function(w)
		return body(w.callback(), w.armed_count)
	end, { base_dir = BASE_DIR, ignored_dirs = { CACHE_DIR } })
end

-- ==================================================================
-- ==================================================================
-- ======= 1/ The driver's own artefacts arm nothing ================
-- ==================================================================
-- ==================================================================

helpers.describe("config watcher: the driver's own cache writes arm no reload", function()

	helpers.it("reloads sibling directories sharing the ignored name (menu-cache-path-boundary)", function()
		for _, ignored in ipairs({ BASE_DIR .. "/cache", CACHE_DIR }) do
			for _, suffix in ipairs({ "_extra", "-backup", "2" }) do
				for _, trailing in ipairs({ "", "/" }) do
					Fixture.with_watcher(function(w)
						w.fire({ ignored .. suffix .. "/source.lua" })
						helpers.assert_type(w.scheduled(), "function",
							"a shared name prefix must not turn a sibling into a cache descendant")
						w.set_clock(1001)
						w.poll()
						helpers.assert_eq(w.reloads(), 1, "a sibling source edit must reload exactly once")
						helpers.assert_nil(w.scheduled(), "an accepted sibling reload must settle")
					end, { base_dir = BASE_DIR, ignored_dirs = { ignored .. trailing } })
				end
			end
		end
	end)

	helpers.it("keeps cache descendants excluded with a trailing slash (menu-cache-path-boundary)", function()
		for _, trailing in ipairs({ "", "/" }) do
			Fixture.with_watcher(function(w)
				w.fire({ CACHE_DIR .. "/nested/hotstrings_123456.lua" })
				helpers.assert_nil(w.scheduled(), "cache descendants must not arm reloads")
				helpers.assert_eq(w.reloads(), 0, "cache writes must remain inert")
			end, { base_dir = BASE_DIR, ignored_dirs = { CACHE_DIR .. trailing } })
		end
	end)

	helpers.it("ignores a TOML snapshot write", function()
		with_watcher(function(cb, armed)
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
	end)

	helpers.it("still reacts to a real source change", function()
		-- Without this case the assertion above would pass against a watcher that
		-- ignores everything, i.e. one that never reloads on an edit at all.
		with_watcher(function(cb, armed)

			local before = armed()
			cb({ BASE_DIR .. "/modules/keymap/init.lua" })

			helpers.assert_true(armed() > before,
				"an edit to a real source file must still arm a reload")
		end)
	end)

	helpers.it("keeps ignoring logs and paths.toml", function()
		with_watcher(function(cb, armed)

			local before = armed()
			cb({ BASE_DIR .. "/logs/today.lua" })
			cb({ BASE_DIR .. "/paths.toml" })

			helpers.assert_eq(armed(), before,
				"the two exclusions that already existed must survive the change")
		end)
	end)

end)
