--- tests/unit/ui/test_onboarding_write_failure_surfaced.lua

--- ==============================================================================
--- MODULE: Regression — a failed onboarding write must not report success
--- DESCRIPTION:
--- The first-run wizard silently discarded the user's answers when the write
--- failed.
---
--- ROOT CAUSE ENCODED:
--- commit() wrapped the write in a pcall whose closure had no `return`:
---
---   local ok, err = pcall(function()
---       toml_writer.batch_write(_config_path, updates)
---   end)
---   if not ok then ... end
---
--- toml_codec's batch_write NEVER raises on I/O failure — it RETURNS false plus a
--- reason (writer.lua returns `false, "rename failed"` on the rename path, and
--- false on every open failure). Dropping the return value meant `ok` was true for
--- a write that had not happened, so the wizard logged success, set the
--- "onboarding completed" flag in hs.settings, and called hs.reload() with nothing
--- on disk. The user's answers were gone AND the wizard never offered itself again.
---
--- WHY AN EXTRACTION:
--- commit() is reachable only through the webview usercontent callback and ends in
--- hs.reload(), so the outcome cannot be observed in the harness. M._commit_write
--- follows the precedent M._resolve_commit_path already set in this file — "pure
--- apart from the injected resolver, so the retarget is testable without a
--- webview".
--- ==============================================================================

local helpers = require("tests.helpers")





-- ==============================================
-- ==============================================
-- ======= 1/ Writer Doubles ====================
-- ==============================================
-- ==============================================

--- Loads the onboarding module.
--- @return table The onboarding module.
local function load_onboarding(file_system)
	package.loaded["adapters.file_system"] = file_system or {
		read_with_status = function() return nil, "absent" end,
	}
	package.loaded["ui.onboarding"] = nil
	return helpers.load_with_stubs("ui.onboarding")
end

-- A writer that reports failure the way the real one does: by RETURNING false.
local RETURNS_FALSE = { batch_write = function() return false, "rename failed" end }

-- A writer that returns nothing at all — must also count as "not confirmed".
local RETURNS_NIL = { batch_write = function() return nil end }

-- A writer that raises, the only failure the original code could see.
local RAISES = { batch_write = function() error("disk on fire") end }

-- The success contract.
local SUCCEEDS = { batch_write = function() return true end }





-- ===============================================
-- ===============================================
-- ======= 2/ Every Failure Mode Surfaces ========
-- ===============================================
-- ===============================================

helpers.describe("onboarding surfaces a write that failed without raising", function()
	helpers.it("reports failure when batch_write RETURNS false", function()
		local Onb = load_onboarding()

		local ok, err = Onb._commit_write(RETURNS_FALSE, "/tmp/config.toml", {})

		helpers.assert_true(ok == false,
			"a batch_write that returns false must be reported as a failure — it never raises "
			.. "on I/O error, so a pcall that only catches a throw marks the wizard complete "
			.. "and reloads with the user's answers unwritten")
		helpers.assert_true(type(err) == "string" and err:find("rename", 1, true) ~= nil,
			"the writer's own reason must be surfaced to the error dialog, got: " .. tostring(err))
	end)

	helpers.it("reports failure when batch_write returns nil", function()
		local Onb = load_onboarding()

		local ok = Onb._commit_write(RETURNS_NIL, "/tmp/config.toml", {})

		helpers.assert_true(ok == false,
			"a writer that confirms nothing must not be treated as success — nil is not true")
	end)

	helpers.it("still reports failure when batch_write raises", function()
		-- Non-regression: the original code caught this case and must keep doing so.
		local Onb = load_onboarding()

		local ok, err = Onb._commit_write(RAISES, "/tmp/config.toml", {})

		helpers.assert_true(ok == false, "a raising writer must still be reported as a failure")
		helpers.assert_true(type(err) == "string" and err:find("disk on fire", 1, true) ~= nil,
			"the raised message must be surfaced, got: " .. tostring(err))
	end)

	helpers.it("reports success only when the write is confirmed", function()
		-- The opposite failure: a fix that reported everything as failed would block
		-- every legitimate first run behind an error dialog.
		local Onb = load_onboarding()

		local ok = Onb._commit_write(SUCCEEDS, "/tmp/config.toml", {})

		helpers.assert_true(ok == true,
			"a writer returning true must be reported as success, otherwise no first run can complete")
	end)

	helpers.it("refuses a dangling destination before invoking batch_write", function()
		local writes = 0
		local Onb = load_onboarding({
			read_with_status = function()
				return nil, "error", "dangling final symlink"
			end,
		})
		local ok, err = Onb._commit_write({
			batch_write = function() writes = writes + 1; return true end,
		}, "/tmp/dangling-config.toml", {})

		helpers.assert_eq(ok, false)
		helpers.assert_eq(writes, 0,
			"onboarding must not let a lower writer replace a dangling symlink")
		helpers.assert_true(type(err) == "string" and err:find("dangling", 1, true) ~= nil)
	end)
end)
