--- core/lifecycle/engine/boot_guard.lua

--- ==============================================================================
--- MODULE: Boot Guard (macOS)
--- DESCRIPTION:
--- Runs init.lua under xpcall so that a boot failing above its own guarded
--- section is reported like every other fatal start. init.lua guards the boot
--- after onboarding, but its top part (module loads, path resolution, the logger)
--- ran unguarded: an error there, such as a module that will not load from a
--- half-updated tree after hs.reload(), went to Hammerspoon's console only. The
--- reloaded driver was then dead, with nothing in its log before the runtime
--- error capture was installed and no launcher alert at all.
---
--- FEATURES & RATIONALE:
--- 1. Loaded by path from init.lua's first lines, before package.path holds the
---    shared tree, so it needs nothing at load; the reporters it uses are read
---    when a failure happens, after init.lua has set the search path.
--- 2. Same report as a pre-runtime abort: diagnostics/adapters/boot_fatal.lua
---    writes the durable boot log, launcher.log and the launcher's report, then
---    the process exits 1 so the launcher shows its modal alert. Hammerspoon
---    itself never shows a modal here, so nothing blocks the run loop.
--- 3. No silent exit: when no launcher received the report (a plain Hammerspoon
---    run, a harness), the error is raised again for Hammerspoon to show, as it
---    did before; the durable boot log still holds it.
--- ==============================================================================

local M = {}

-- The table init.lua receives as its first argument when the guard runs it.
local MARKER = "ergopti_boot_guard"





-- ===================================
-- ===================================
-- ======= 1/ Reporting ==============
-- ===================================
-- ===================================

--- Reports a boot failure through the fatal reporter, when it can load.
--- @param failure any The raised error.
--- @param traceback string|nil Stack captured before the unwind.
--- @return boolean launcher_notified True when the launcher received the report.
function M.report(failure, traceback)
	local detail = tostring(traceback or failure)
	local found, BootFatal = pcall(require, "diagnostics.adapters.boot_fatal")
	if not found or type(BootFatal) ~= "table" then return false end
	local stage = "init"
	local Boot = package.loaded["core.logger.engine.boot_profiler"]
	if type(Boot) == "table" and type(Boot.current_stage) == "function" then
		local read, current = pcall(Boot.current_stage)
		if read and type(current) == "string" and current ~= "" then stage = current end
	end
	local message = nil
	local i18n = package.loaded["core.i18n.engine.i18n"]
	if type(i18n) == "table" and type(i18n.get) == "function" then
		local translated, text = pcall(i18n.get, "dialog.fatal_error.cannot_start")
		if translated and type(text) == "string" then message = text end
	end
	local reported, notified = pcall(BootFatal.report, stage, detail, message)
	return reported and notified == true
end





-- ===================================
-- ===================================
-- ======= 2/ Guarded Run ============
-- ===================================
-- ===================================

--- Whether init.lua was started by run() rather than by Hammerspoon.
--- @param first any init.lua's first chunk argument.
--- @return boolean
function M.is_guarded(first)
	return type(first) == "table" and first[MARKER] == true
end

--- Runs the entry point once more, inside xpcall, and handles its failure.
--- @param entry string Absolute path of init.lua.
--- @param deps table|nil Test seams: loadfile, report(failure, traceback), exit(code).
--- @return boolean booted True when the entry point returned normally.
function M.run(entry, deps)
	assert(type(entry) == "string" and entry ~= "", "the boot guard needs the entry point path")
	deps = type(deps) == "table" and deps or {}
	local load = deps.loadfile or loadfile
	local report = deps.report or M.report
	local exit = deps.exit or os.exit
	local chunk = assert(load(entry))
	local traceback = nil
	local booted, failure = xpcall(chunk, function(err)
		traceback = debug.traceback(tostring(err), 2)
		return err
	end, { [MARKER] = true })
	if booted then return true end
	local notified_ok, notified = pcall(report, failure, traceback)
	if notified_ok and notified == true then
		exit(1)
		return false
	end
	error(traceback or failure, 0)
end

return M
