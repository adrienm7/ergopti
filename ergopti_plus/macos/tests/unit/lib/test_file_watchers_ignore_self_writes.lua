--- tests/unit/lib/test_file_watchers_ignore_self_writes.lua

--- ==============================================================================
--- MODULE: Regression — the driver's own config writes must not reload it
---         (file-watchers-self-trigger)
--- DESCRIPTION:
--- Every menu toggle reloaded the whole driver half a second later.
---
--- ROOT CAUSE ENCODED: `hotstrings_dir` falls back to the bundled directory only
--- when the config root holds NO ordinary .toml — and the real tree holds
--- wrap_symbols.toml, so it stays the config ROOT. hs.pathwatcher is recursive,
--- so that one watcher also covers hammerspoon/config.toml, and the callback
--- matched every `*.toml`. save_prefs — which every single menu toggle calls —
--- therefore looked exactly like a user hand-editing a hotstring file, and the
--- settle timer reloaded the session it had just been asked to change.
--- config_karabiner.toml is the same story on every layout change.
---
--- WHY IT WAS SILENT: a reload looks like the driver working. The notification
--- says the config changed, which is true; nothing indicates the change was our
--- own write, or that toggling one checkbox tore down and rebuilt every
--- subsystem.
---
--- The exclusion is by resolved PATH, handed in by the boot script from
--- menu_paths, so the watcher cannot disagree with the writers about where these
--- files live.
--- ==============================================================================

local helpers = require("tests.helpers")

local Fixture = require("tests.support.file_watcher_self_write_fixture")
local CONFIG_TOML = Fixture.CONFIG_TOML
local KARABINER_TOML = Fixture.KARABINER_TOML
local HOTSTRING_TOML = Fixture.HOTSTRING_TOML

helpers.describe("file_watchers: a write the session made itself does not reload it", function()
	helpers.it("ignores config.toml, which every menu toggle rewrites", function()
		Fixture.with_watchers(function(w)

			w.fire(CONFIG_TOML)

			helpers.assert_true(w.scheduled() == nil,
				"save_prefs writes config.toml on every menu toggle. Treating that as an external "
					.. "edit reloads the entire driver half a second after the user flips a checkbox — "
					.. "tearing down and rebuilding every subsystem to apply a change already applied")
			helpers.assert_eq(w.reloads(), 0, "and must not reload")

		end)
	end)

	helpers.it("ignores config_karabiner.toml, regenerated on every layout change", function()
		Fixture.with_watchers(function(w)

			w.fire(KARABINER_TOML)

			helpers.assert_true(w.scheduled() == nil,
				"the driver regenerates config_karabiner.toml itself whenever the layout changes — "
					.. "the same self-trigger, on a file written far more often")
			helpers.assert_eq(w.reloads(), 0, "and must not reload")

		end)
	end)
end)



-- ================================================================
-- ================================================================
-- ======= 2/ Real hotstring edits still reload ===================
-- ================================================================
-- ================================================================

helpers.describe("file_watchers: a genuine hotstring edit still reloads", function()
	helpers.it("reloads on an ordinary .toml in the same directory", function()
		Fixture.with_watchers(function(w)

			w.fire(HOTSTRING_TOML)

			helpers.assert_true(type(w.scheduled()) == "function",
				"a hotstring file edited by the user must still schedule a reload. The two config "
					.. "files sit in the SAME watched tree, so an exclusion that swallowed the whole "
					.. "directory would silence the auto-reload this module exists for")

			w.settle()
			helpers.assert_eq(w.reloads(), 1, "and must reload exactly once")

		end)
	end)
end)
