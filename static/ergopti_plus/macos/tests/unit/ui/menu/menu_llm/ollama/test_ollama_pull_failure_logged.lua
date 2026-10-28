--- tests/unit/ui/menu/menu_llm/ollama/test_ollama_pull_failure_logged.lua

--- =============================================================================
--- MODULE: Ollama Pull Failure Logging Regression
--- DESCRIPTION:
--- A model pull that failed after its progress reached 100% (a digest or
--- manifest error printed last) showed an error to the user and left no line
--- in the log (field session 2026-10-27). Every failed pull now logs an ERROR
--- with its exit code and the last line the pull printed.
--- =============================================================================

local helpers = require("tests.helpers")

local with_fixture = require("tests.support.ollama_pull_fixture").with_fixture

local function joined_errors(fixture)
	return table.concat(fixture.error_records, " | ")
end

helpers.describe("Ollama pull failure logging", function()
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
