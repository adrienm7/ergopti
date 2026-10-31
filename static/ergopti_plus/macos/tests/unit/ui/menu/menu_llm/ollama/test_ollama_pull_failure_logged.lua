--- tests/unit/ui/menu/menu_llm/ollama/test_ollama_pull_failure_logged.lua

--- =============================================================================
--- MODULE: Ollama Pull Failure Logging Regression
--- DESCRIPTION:
--- A model pull that failed after its progress reached 100% (a digest or
--- manifest error printed last) showed an error to the user and left no line
--- in the log (field session 2026-10-27). Every failed pull now logs an ERROR
--- with its exit code and the last line the pull printed. A digest mismatch
--- (Ollama has already deleted the bad layer) is pulled once more, then fails
--- with its own named reason (field run 2026-10-31).
--- =============================================================================

local helpers = require("tests.helpers")

local with_fixture = require("tests.support.ollama_pull_fixture").with_fixture

local function joined_errors(fixture)
	return table.concat(fixture.error_records, " | ")
end

--- Delivers the newest scheduled one-shot timer as TimerScheduler would.
--- @param f table Fixture.
local function deliver_last_timer(f)
	local handle = f.timers[#f.timers]
	helpers.assert_not_nil(handle, "a retry timer was scheduled")
	handle.timer = nil
	return handle.callback()
end

local DIGEST_FAILURE = "OLLAMA_PULL_STATUS verifying_digest\nOLLAMA_PULL_ERROR digest_mismatch\nOLLAMA_PULL_OUTCOME error_row\n"

helpers.describe("Ollama pull failure logging", function()
	helpers.it("pulls once more after a digest mismatch, then names the mismatch (ollama-digest-mismatch-retry)", function()
		with_fixture({}, function(f)
			local successes, cancels = 0, 0
			helpers.assert_true(f.manager.pull_model("granite4:350m-h", "granite4:350m-h",
				function() successes = successes + 1; return true end,
				function() cancels = cancels + 1; return true end,
				{ is_current = function() return true end }))
			f.pulls[1].on_done(1, DIGEST_FAILURE, "")
			helpers.assert_eq(cancels, 0, "the first mismatch is retried, not settled as a failure")
			helpers.assert_true(deliver_last_timer(f), "the retry starts")
			helpers.assert_eq(#f.pulls, 2, "Ollama removed the bad layer: a second pull downloads it afresh")
			helpers.assert_eq(f.notifications(), 0, "no failure is announced before the retry ends")

			f.pulls[2].on_done(1, DIGEST_FAILURE, "")
			helpers.assert_eq(#f.pulls, 2, "a second mismatch is not retried again")
			helpers.assert_eq(cancels, 1, "the second mismatch settles the pull as failed")
			local record = f.notification_records[#f.notification_records]
			helpers.assert_not_nil(record, "the failure is announced")
			helpers.assert_eq(record[2], "ollama.digest_mismatch", "the notice names the mismatch")
			helpers.assert_eq(successes, 0)
		end)
	end)

	helpers.it("logs the exit code and the last printed line of a pull failing after 100%", function()
		with_fixture({}, function(f)
			helpers.assert_true(f.manager.pull_model("model-A", "model-A",
				function() return true end, function() return true end,
				{ is_current = function() return true end }))
			local task = f.pulls[1]
			task.on_done(1, "pulling manifest\nverifying sha256 digest 100%\n",
				"Error: digest mismatch, file must be downloaded again\n")
			local errors = joined_errors(f)
			helpers.assert_true(errors:find("code 1", 1, true) ~= nil,
				"the failed pull must log its exit code: " .. errors)
			helpers.assert_true(errors:find("digest mismatch", 1, true) ~= nil,
				"the failed pull must log the cause it printed last: " .. errors)
		end)
	end)
end)
