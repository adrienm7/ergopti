--- tests/unit/ai/engine/ollama/test_install_errors.lua

--- ==============================================================================
--- MODULE: macOS Managed Ollama Install Error Tests
--- DESCRIPTION:
--- OLL-05 of the 2026-11-20 managed Ollama campaign: every failed install exited
--- 78 and showed « send the diagnostics report », a network outage included,
--- since no production script printed the network and checksum markers. The
--- installer now prints one evidence line (OLLAMA_INSTALL_FAILURE) that the
--- shared classes of _shared/ai/data/ollama_install_errors.json name. Replays
--- the shared corpus and drives the real checker with fake task output; nothing
--- is downloaded (ollama-install-errors).
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.modules.llm.backends.ai_runtime_selection_install_fixture")
local InstallErrors = require("ai.engine.ollama.install_errors")

local function corpus()
	local path = assert(require("core.fs.engine.paths").shared("tests/corpus/llm/ollama_install_error_vectors.json"))
	local handle = assert(io.open(path, "rb"))
	local raw = handle:read("*a")
	handle:close()
	return require("core.text.engine.json").decode(raw)
end

--- Runs one install that prints `stdout` and exits `code`.
--- @param code integer Exit code.
--- @param stdout string Final stdout.
--- @param key string Expected locale key, resolved inside the fixture scope.
--- @return string message The published failure message.
--- @return string expected The localized words for `key`.
--- @return string refused The refused pinned runtime's words, every failure's before OLL-05.
local function failure_for(code, stdout, key)
	local message, expected, refused
	Fixture.scoped(function()
		local state = Fixture.new_state()
		local checker = Fixture.load_ollama_checker(state)
		helpers.assert_true(Fixture.start_verification(state, checker, function() end))
		state.tasks[1].done(code, stdout, "Managed Ollama runtime admission refused.\n")
		message = checker.get_failure_message()
		expected = require("core.i18n.engine.i18n").get(key)
		refused = require("core.i18n.engine.i18n").get("ollama.error_runtime_refused")
	end)()
	return message, expected, refused
end

helpers.describe("Managed Ollama install errors (ollama-install-errors)", function()
	helpers.it("ollama-install-error-vectors: classes every shared vector as Windows and Linux do", function()
		local classifier = require("ai.engine.ollama.install_error_messages").classifier()
		local vectors = corpus()
		helpers.assert_true(#vectors.cases > 0, "the corpus names its cases")
		for _, case in ipairs(vectors.cases) do
			local class = classifier.classify(case.evidence)
			helpers.assert_eq(class, case.class, case.id)
			helpers.assert_eq(classifier.message_key(class), "ollama.install_error." .. class, case.id)
		end
		for _, case in ipairs(vectors.free_space) do
			helpers.assert_eq(InstallErrors.fits(case.asset_bytes, case.margin_bytes, case.free_bytes), case.fits, case.id)
		end
	end)

	helpers.it("a network outage names the network, not the diagnostics report", function()
		local message, expected, refused = failure_for(78,
			"OLLAMA_INSTALLING\nOLLAMA_INSTALL_FAILURE phase=download reason=connect\n", "ollama.install_error.network")
		helpers.assert_eq(message, expected)
		helpers.assert_true(message ~= refused, "the network words are not the refused runtime's")
	end)

	helpers.it("a full disk names the disk", function()
		local message, expected = failure_for(78,
			"OLLAMA_INSTALLING\nOLLAMA_INSTALL_FAILURE phase=install reason=install_disk_full\n",
			"ollama.install_error.disk_full")
		helpers.assert_eq(message, expected)
	end)

	helpers.it("a corrupted download names the checksum", function()
		local message, expected = failure_for(78,
			"OLLAMA_INSTALLING\nOLLAMA_INSTALL_FAILURE phase=download reason=integrity\n", "ollama.install_error.checksum")
		helpers.assert_eq(message, expected)
	end)

	helpers.it("an unrecognised refusal names the unknown class", function()
		local message, expected = failure_for(78,
			"OLLAMA_INSTALLING\nOLLAMA_INSTALL_FAILURE phase=install reason=signature\n", "ollama.install_error.unknown")
		helpers.assert_eq(message, expected)
	end)

	helpers.it("the evidence line is never shown as a script line", Fixture.scoped(function()
		local state = Fixture.new_state()
		local logs = {}
		state.window = {}
		for key, value in pairs(Fixture.WINDOW_STUB) do state.window[key] = value end
		state.window.is_active = function() return true end
		state.window.append_log = function(line) logs[#logs + 1] = line end
		local checker = Fixture.load_ollama_checker(state)
		helpers.assert_true(Fixture.start_verification(state, checker))
		local task = state.tasks[1]
		helpers.assert_true(task.stream(task, "OLLAMA_INSTALL_FAILURE phase=download reason=connect\n", ""))
		for _, line in ipairs(logs) do
			helpers.assert_true(not line:find("OLLAMA_INSTALL_FAILURE", 1, true), "protocol line shown: " .. line)
		end
		task.done(78, "", "")
		helpers.assert_eq(checker.get_failure_message(), require("core.i18n.engine.i18n").get("ollama.install_error.network"))
	end))
end)
