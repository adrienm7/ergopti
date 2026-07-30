--- tests/unit/ui/test_preferences_corrupt_not_absent.lua

--- ==============================================================================
--- MODULE: Regression — a corrupt config.toml must not be treated as absent
---         (preferences-corrupt-not-absent)
--- DESCRIPTION:
--- Make config.toml unparseable — a typo in the expert [script]/[features]
--- layer, a git merge-conflict marker, or a torn write from the cloud-synced
--- directory it lives in — then reload Hammerspoon. Every preference is gone,
--- with no warning, no backup and no way back: boot factory-resets every group
--- and then OVERWRITES the file with those defaults.
---
--- ROOT CAUSE ENCODED: Preferences.load collapsed three different outcomes into
--- one silent empty table — file missing, file unreadable, decode failed. The
--- caller derives `config_absent` from `next(saved) == nil`, and that flag
--- legitimately means "fresh install, seed the factory defaults and save them".
--- A corrupt file produced a byte-identical signal, so the recovery path for a
--- brand-new user became the destruction path for an existing one.
---
--- The loss is permanent on macOS: preferences.save keeps a .bak only when
--- package.config's separator is a backslash, i.e. on Windows.
---
--- DECISIVE CORROBORATION: the karabiner loader already fixed this exact class,
--- and test_config_corrupt_toml's own docstring describes the identical
--- "absent vs corrupt both yield nil, then get persisted over the recoverable
--- file" failure. Preferences.load is the parallel loader that never got it.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Write a throwaway config file and return its path.
local function write_temp(contents)
	local path = os.tmpname()
	-- os.tmpname can return a bare name on some platforms; keep it beside the
	-- other temp files rather than in the current working directory.
	local fh = io.open(path, "w")
	if not fh then return nil end
	fh:write(contents)
	fh:close()
	return path
end

local function preferences()
	return helpers.load_with_stubs("ui.menu.preferences", {})
end




-- =========================================================================
-- =========================================================================
-- ======= 1/ The three outcomes are distinguishable =======================
-- =========================================================================
-- =========================================================================

helpers.describe("Preferences.load: corrupt is not absent", function()
	helpers.it("a missing file reports absent", function()
		local prefs = preferences()
		local saved, status = prefs.load("/nonexistent/ergopti-test/config.toml")

		helpers.assert_true(type(saved) == "table", "load must still return a table")
		helpers.assert_eq(status, "absent",
			"a genuinely missing file must report absent — that is the fresh-install path, and it "
				.. "is the ONLY case in which seeding factory defaults and saving them is correct")
	end)

	helpers.it("an unparseable file reports corrupt, not absent", function()
		local prefs = preferences()
		local path = write_temp("<<<<<<< HEAD\nthis is not = [valid toml\n=======\n")
		helpers.assert_true(path ~= nil, "the fixture file must be writable")

		local saved, status = prefs.load(path)
		os.remove(path)

		helpers.assert_true(type(saved) == "table", "load must stay non-throwing on malformed input")
		helpers.assert_eq(status, "corrupt",
			"an unparseable config.toml must report CORRUPT. Reported as absent it is "
				.. "indistinguishable from a fresh install, and boot then factory-resets every group "
				.. "and overwrites the file with defaults — permanently, because the .bak path is "
				.. "Windows-only")
	end)

	helpers.it("a valid file reports ok and decodes", function()
		local prefs = preferences()
		local path = write_temp("[script]\nlocale = \"fr\"\n")
		helpers.assert_true(path ~= nil, "the fixture file must be writable")

		local saved, status = prefs.load(path)
		os.remove(path)

		helpers.assert_eq(status, "ok",
			"a valid file must report ok — without this the guard could be satisfied by reporting "
				.. "corrupt for everything, which would block every legitimate save")
		helpers.assert_true(type(saved) == "table",
			"a valid file must decode to a table. Whether it is POPULATED depends on KEY_MAP "
				.. "recognising the keys, which is a different concern from this finding — asserting "
				.. "it here would couple the corruption guard to the preference schema")
	end)

	helpers.it("the failure is logged, not swallowed", function()
		-- Source-level, not behavioural: helpers.load_with_stubs installs a NOOP
		-- logger (set_sink is a no-op there), so a sink capture around a stubbed
		-- module observes nothing and would pass vacuously whatever the code did.
		local src = helpers.read_driver_source("flatten_from_disk")
		helpers.assert_true(src ~= nil and src ~= "",
			"the preferences source must be locatable by its flatten_from_disk symbol")

		local at = src:find("function M.load", 1, true)
		helpers.assert_true(at ~= nil, "M.load must exist")
		local body = src:sub(at, at + 1600)

		helpers.assert_true(body:find("Logger.error", 1, true) ~= nil,
			"a corrupt config must be reported at ERROR. Silent, the user's first sign is that "
				.. "every setting reverted overnight, with nothing in the log connecting it to a cause")
		helpers.assert_true(body:find("corrupt", 1, true) ~= nil,
			"and it must return the corrupt status alongside that log line, so the caller can act "
				.. "on it rather than merely being told after the fact")
	end)
end)




-- =========================================================================
-- =========================================================================
-- ======= 2/ The caller acts on the distinction ===========================
-- =========================================================================
-- =========================================================================

helpers.describe("menu boot: a corrupt config never triggers the factory save", function()
	helpers.it("config_absent is derived from the load status, not just emptiness", function()
		local src = helpers.read_driver_source("config_absent")
		helpers.assert_true(src ~= nil and src ~= "",
			"the menu boot source must be locatable by its config_absent symbol")

		local at = src:find("local config_absent", 1, true)
		helpers.assert_true(at ~= nil, "config_absent must still be derived at boot")

		local line = src:sub(at, (src:find("\n", at) or (at + 200)))
		-- "absent" alone is NOT accepted as evidence: the variable is literally
		-- named config_absent, so that word matches the UNFIXED line too. This
		-- assertion passed against the bug until the alternative was removed.
		-- The loader's status must actually be consulted.
		helpers.assert_true(
			line:find("load_status", 1, true) ~= nil,
			"config_absent must consult the loader's status. Derived from `next(saved) == nil` "
				.. "alone, a corrupt file is indistinguishable from a fresh install — and that flag "
				.. "is what runs the factory reset AND the save that overwrites the user's file. "
				.. "Got: " .. line
		)
	end)

	helpers.it("the save is still reached for a genuine fresh install", function()
		local src = helpers.read_driver_source("config_absent")
		helpers.assert_true(src:find("if config_absent then save_prefs() end", 1, true) ~= nil,
			"a real fresh install must still persist its seeded defaults — narrowing the flag must "
				.. "not disable the path it exists for")
	end)
end)
