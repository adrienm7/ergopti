--- tests/support/runtime_checker_stub.lua

--- ==============================================================================
--- MODULE: AI Runtime Checker Test Double
--- DESCRIPTION:
--- Completes a partial mlx_deps_checker/ollama_deps_checker double with the
--- selection API the menu calls. The fixture's check_and_install_deps stays the
--- one observed bootstrap: install_for_selection delegates to it, and the
--- runtime reads as installed unless the fixture says otherwise, so menu tests
--- that predate the selection gate keep exercising the same effect.
--- ==============================================================================

--- Fills in the selection API around one bootstrap function.
--- @param checker table Partial checker double with check_and_install_deps.
--- @param installed boolean|nil False to model a runtime that is absent.
--- @return table checker The same table, completed.
return function(checker, installed)
	assert(type(checker) == "table", "runtime checker double must be a table")
	assert(type(checker.check_and_install_deps) == "function",
		"runtime checker double needs its observed check_and_install_deps")
	local present = installed ~= false
	checker.install_for_selection = checker.install_for_selection
		or function(...) return checker.check_and_install_deps(...) end
	checker.runtime_installed = checker.runtime_installed or function() return present end
	checker.runtime_available = checker.runtime_available or function() return present end
	checker.is_task_running = checker.is_task_running or function() return false end
	return checker
end
