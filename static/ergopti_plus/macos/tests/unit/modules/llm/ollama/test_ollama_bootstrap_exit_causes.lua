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
