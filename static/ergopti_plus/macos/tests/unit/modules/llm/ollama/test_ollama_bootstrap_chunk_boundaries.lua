--- tests/unit/modules/llm/ollama/test_ollama_bootstrap_chunk_boundaries.lua

--- ==============================================================================
--- MODULE: Ollama Bootstrap Chunk Boundaries
--- DESCRIPTION:
--- Native task reads have arbitrary boundaries. Exercise the real checker with
--- split protocol lines so progress and localized failures do not depend on
--- the operating system delivering one complete line per callback.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.modules.llm.backends.ai_runtime_selection_install_fixture")

helpers.describe("Ollama bootstrap framing (ollama-bootstrap-chunks)", function()
	helpers.it("recognizes a failure marker at every byte boundary", function()
		local marker = "OLLAMA_ERROR_CHECKSUM"
		for boundary = 1, #marker - 1 do
			Fixture.scoped(function()
				local state = Fixture.new_state()
				local checker = Fixture.load_ollama_checker(state)
				local result
				helpers.assert_true(checker.install_for_selection(function(ok) result = ok end))
				local task = state.tasks[1]
				helpers.assert_true(task.stream(task, marker:sub(1, boundary), ""))
				helpers.assert_true(task.stream(task, marker:sub(boundary + 1) .. "\r\n", ""))
				task.done(1, "", "")
				helpers.assert_eq(result, false)
				helpers.assert_eq(checker.get_failure_message(), require("infra.i18n").get("ollama.error_checksum"),
					"checksum cause must survive split at byte " .. boundary)
			end)()
		end
	end)

	helpers.it("keeps stream fragments separate and flushes a final unterminated marker", Fixture.scoped(function()
		local state = Fixture.new_state()
		local checker = Fixture.load_ollama_checker(state)
		helpers.assert_true(checker.install_for_selection())
		local task = state.tasks[1]
		helpers.assert_true(task.stream(task, "OLLAMA_ERROR_CHECK", "stderr diagnostic\n"))
		task.done(1, "SUM", "")
		helpers.assert_eq(checker.get_failure_message(), require("infra.i18n").get("ollama.error_checksum"))
	end))

	helpers.it("assembles progress markers and diagnostic lines before presentation", Fixture.scoped(function()
		local state = Fixture.new_state()
		local active, shows = false, 0
		local progress, logs = {}, {}
		state.window = {}
		for key, value in pairs(Fixture.WINDOW_STUB) do state.window[key] = value end
		state.window.is_active = function() return active end
		state.window.show = function() active = true; shows = shows + 1 end
		state.window.set_progress = function(value) progress[#progress + 1] = value end
		state.window.append_log = function(line) logs[#logs + 1] = line end
		local checker = Fixture.load_ollama_checker(state)
		helpers.assert_true(checker.install_for_selection())
		local task = state.tasks[1]
		local output = "OLLAMA_INSTALLING\r\nOLLAMA_DOWNLOAD_PROGRESS 37\r\nDownloading archive\r\n"
		for index = 1, #output do
			helpers.assert_true(task.stream(task, output:sub(index, index), ""))
		end
		helpers.assert_eq(shows, 1, "split install marker must open the progress window exactly once")
		helpers.assert_eq(#progress, 1)
		helpers.assert_eq(progress[1], 37)
		helpers.assert_eq(#logs, 1, "protocol fragments must not appear as diagnostic lines")
		helpers.assert_eq(logs[1], "Downloading archive")
		task.done(1, "OLLAMA_ERROR_CHECKSUM\n", "")
	end))
end)
