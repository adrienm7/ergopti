--- tests/meta/test_scratch_dir_gitignored.lua

--- ==============================================================================
--- MODULE: Test Scratch Directory Ignore Guard Meta Test
--- DESCRIPTION:
--- Asserts the repository ignores tests/scratch_test_dir/, the scratch area the
--- macOS suite writes into while running.
---
--- ROOT CAUSE ENCODED — A DOCUMENTED ASSUMPTION THAT WAS NEVER TRUE:
--- tests/unit/adapters/test_toml_cache.lua states outright that
--- "scratch_test_dir is gitignored and absent in CI", and two other tests
--- (test_preferences_gesture_space_wrap.lua, test_jsonl_survives_sqlite_open_failure.lua)
--- write into it on that basis. The repository .gitignore listed
--- static/ergopti_plus/scratch/ and .scratch/ but never the test scratch path, so
--- the assumption was false: test_jsonl_survives_sqlite_open_failure creates a
--- by_device/<uuid>/ tree and removes only its log file, leaving data.sql,
--- device.json and device.json.tmp behind. Running the suite therefore dirtied the
--- working tree with untracked files that showed up in git status and could be
--- swept into an unrelated commit by `git add -A`.
---
--- The fix makes the configuration match the documented contract rather than
--- rewriting the comment, because three call sites already depend on it.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Path the guard requires an ignore entry for, relative to the repository root.
local SCRATCH_PATH = "static/ergopti_plus/macos/tests/scratch_test_dir/"





-- ==========================================
-- ==========================================
-- ======= 1/ The Ignore Entry Exists =======
-- ==========================================
-- ==========================================

helpers.describe("the macOS test scratch directory is gitignored", function()
	helpers.it(".gitignore covers tests/scratch_test_dir so a test run leaves the tree clean", function()
		-- Walk up from the driver root to the repository root that owns .gitignore.
		local driver_root = helpers.driver_root()
		local repo_root   = driver_root:gsub("[/\\]?static[/\\]ergopti_plus[/\\]macos[/\\]?$", "")

		local path = repo_root .. "/.gitignore"
		local fh   = io.open(path, "r")
		helpers.assert_true(fh ~= nil, ".gitignore must be readable at the repository root: " .. path)
		if not fh then return end
		local src = fh:read("*a")
		fh:close()

		local normalised = src:gsub("\\", "/")
		helpers.assert_true(
			normalised:find(SCRATCH_PATH, 1, true) ~= nil
			or normalised:find("scratch_test_dir", 1, true) ~= nil,
			".gitignore must ignore " .. SCRATCH_PATH .. " — the macOS suite writes there during a run "
			.. "and test_jsonl_survives_sqlite_open_failure leaves a by_device/ tree behind, so without "
			.. "the entry a plain `lua tests/run.lua` dirties the working tree with untracked artefacts"
		)
	end)
end)
