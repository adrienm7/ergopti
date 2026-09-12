--- tests/unit/lib/test_ui_restore_storage_transaction.lua

--- ==============================================================================
--- MODULE: UI Restore Storage Transaction Tests
--- DESCRIPTION:
--- Requires a successful snapshot read and consumption before any window reopens.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.ui_restore_fixture")
local STATE_KEY = "ergopti.ui_restore_state"

helpers.describe("UI restore storage boundaries (ui-restore-storage-commit)", function()
	for _, failure in ipairs({ "read throw", "clear false", "clear throw", "clear uncommitted" }) do
		helpers.it("retains the snapshot and schedules nothing after " .. failure, function()
			local snapshot = { "hotstring_editor" }
			local settings = { [STATE_KEY] = snapshot }
			Fixture.with_fixture({ settings = settings }, function(subject, scheduler, window)
				local read, clear = hs.settings.get, hs.settings.clear
				if failure == "read throw" then
					hs.settings.get = function() error("snapshot read refused") end
				elseif failure == "clear false" then
					hs.settings.clear = function() return false end
				elseif failure == "clear throw" then
					hs.settings.clear = function() error("snapshot clear refused") end
				else
					hs.settings.clear = function() return true end
				end
				helpers.assert_eq(subject.restore(), false, "storage refusal must remain visible")
				helpers.assert_eq(#scheduler.after_handles, 0, "an unconsumed snapshot cannot authorize reopening")
				helpers.assert_eq(window.reopen_calls, 0)
				helpers.assert_eq(settings[STATE_KEY], snapshot, "the refused snapshot must remain available")
				helpers.assert_true(#window.errors > 0, "the adapter must report the failed boundary")

				hs.settings.get, hs.settings.clear = read, clear
				helpers.assert_eq(subject.restore(), true, "a later committed attempt must recover")
				helpers.assert_nil(settings[STATE_KEY])
				helpers.assert_eq(#scheduler.after_handles, 1)
				scheduler.after_handles[1].callback()
				helpers.assert_eq(window.reopen_calls, 1)
				helpers.assert_eq(subject.restore(), true)
				helpers.assert_eq(#scheduler.after_handles, 1, "the consumed snapshot must not reopen twice")
			end)
		end)
	end

	helpers.it("treats a successfully read absent snapshot as an idle success", function()
		Fixture.with_fixture({}, function(subject, scheduler, window)
			helpers.assert_eq(subject.restore(), true)
			helpers.assert_eq(#scheduler.after_handles, 0)
			helpers.assert_eq(window.reopen_calls, 0)
			helpers.assert_eq(#window.errors, 0)
		end)
	end)
end)
