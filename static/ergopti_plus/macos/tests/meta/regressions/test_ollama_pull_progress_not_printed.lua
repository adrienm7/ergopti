--- tests/meta/regressions/test_ollama_pull_progress_not_printed.lua

--- ==============================================================================
--- MODULE: Ollama Pull Progress Is Not Printed
--- DESCRIPTION:
--- The managed pull's stream callback printed every output chunk, and the
--- runtime's console tee wrote each one to the day log: about one line each
--- 60 ms, 1508 of the 4736 lines of the 2026-10-31 field log. The progress
--- window shows it and the end-of-pull line names the last output
--- (ollama-pull-progress-not-printed).
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("Ollama pull progress (ollama-pull-progress-not-printed)", function()
	helpers.it("never prints the pull's stream chunks", function()
		local source, err = helpers.read_driver_unit("local function last_pull_bytes")
		helpers.assert_true(type(source) == "string", "the Ollama models manager must be found: " .. tostring(err))
		helpers.assert_true(source:find("update_progress_ui(owner, pct, last_line, done, total)", 1, true) ~= nil,
			"the stream callback still feeds the progress window")
		helpers.assert_nil(source:find("%f[%w_]print%s*%("),
			"a print in the models manager is tee'd into the day log")
	end)
end)
