--- tests/unit/modules/llm/ollama/test_ollama_bootstrap_exit_causes.lua

--- ==============================================================================
--- MODULE: Ollama Bootstrap Exit Causes
--- DESCRIPTION:
--- Issue #104 showed "Ollama bootstrap failed (exit=64) — Erreur inconnue".
--- Exit 64 (EX_USAGE) is the launcher's managed PTY worker, or the managed
--- runtime receiver, refusing the installer request Ergopti built itself; exit
--- 78 (EX_CONFIG) is the pinned runtime's catalogue or admission refusing it.
--- Neither prints a marker, so the user saw no cause. Each now has its own
--- localized words; any other code keeps the script's own tail
--- (ollama-bootstrap-exit-causes).
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.modules.llm.backends.ai_runtime_selection_install_fixture")

--- Runs one bootstrap that exits with `code` and no marker.
--- @param code integer Exit code.
--- @param stdout string|nil Final stdout.
--- @param key string|nil Expected locale key, resolved inside the fixture scope.
--- @return string message The published failure message.
--- @return string|nil expected The localized words for `key`.
local function failure_for(code, stdout, key)
	local message, expected
	Fixture.scoped(function()
		local state = Fixture.new_state()
		local checker = Fixture.load_ollama_checker(state)
		helpers.assert_true(checker.install_for_selection(function() end))
		state.tasks[1].done(code, stdout or "", "")
		message = checker.get_failure_message()
		if key then expected = require("infra.i18n").get(key) end
	end)()
	return message, expected
end

helpers.describe("Ollama bootstrap exit causes (ollama-bootstrap-exit-causes)", function()
	helpers.it("names a refused installer request (exit 64)", function()
		local message, expected = failure_for(64, nil, "ollama.error_installer_refused")
		helpers.assert_eq(message, expected)
	end)

	helpers.it("names a refused pinned runtime (exit 78)", function()
		local message, expected = failure_for(78, nil, "ollama.error_runtime_refused")
		helpers.assert_eq(message, expected)
	end)

	helpers.it("keeps the script tail for any other exit", function()
		helpers.assert_contains(failure_for(1, "curl: (6) Could not resolve host\n"), "Could not resolve host")
	end)
end)

--- Runs one bootstrap that streams `streamed` on stderr and exits with `code`,
--- capturing every ERROR line the checker logs.
--- @param code integer Exit code.
--- @param streamed string|nil Stderr chunk streamed before the terminal.
--- @return string message The published failure message.
--- @return string expected The SIGKILL sentence as the locale port formats it.
--- @return table errors Formatted ERROR lines.
local function signalled_failure(code, streamed)
	local message, expected
	local errors = {}
	helpers.with_stub_scope({ "infra.logger" }, function()
		local logger = helpers.make_logger_stub()
		logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
		package.loaded["infra.logger"] = logger
		Fixture.scoped(function()
			local state = Fixture.new_state()
			local checker = Fixture.load_ollama_checker(state)
			-- The suite's locale stub answers keys; keep the substituted value visible.
			require("infra.i18n").format = function(key, ...) return key .. "(" .. table.concat({ ... }, ",") .. ")" end
			helpers.assert_true(checker.install_for_selection(function() end))
			local task = state.tasks[1]
			if streamed then helpers.assert_true(task.stream(task, "", streamed)) end
			task.done(code, "", "")
			message = checker.get_failure_message()
			expected = require("infra.i18n").format("ollama.error_killed", "SIGKILL")
		end)()
	end)
	return message, expected, errors
end

-- Field run 2026-10-27 22:32: "Ollama bootstrap failed (exit=137) — Erreur
-- inconnue", with no output line, no signal and no stage in the log.
helpers.describe("Ollama bootstrap killed by a signal (ollama-bootstrap-exit-signal)", function()
	helpers.it("names SIGKILL to the user instead of an unknown error", function()
		local message, expected = signalled_failure(137)
		helpers.assert_eq(message, expected)
		helpers.assert_contains(message, "SIGKILL")
	end)

	helpers.it("logs the signal and that no output reached the driver", function()
		local _, _, errors = signalled_failure(137)
		local evidence = table.concat(errors, "\n")
		helpers.assert_contains(evidence, "exit=137 (signal SIGKILL")
		helpers.assert_contains(evidence, "streamed stdout=0 stderr=0 bytes")
		helpers.assert_contains(evidence, "last 0 line(s): none")
	end)

	helpers.it("logs the installer's last lines, which name the stage and the killed child", function()
		local line = "[OLLAMA-DEPS] ERROR: stage python_install: uv ended by signal SIGKILL (exit 137)."
		local _, _, errors = signalled_failure(137, "[OLLAMA-DEPS] stage: python_install\n" .. line .. "\n")
		local evidence = table.concat(errors, "\n")
		helpers.assert_contains(evidence, "streamed stdout=0 stderr=")
		helpers.assert_contains(evidence, line)
	end)
end)
