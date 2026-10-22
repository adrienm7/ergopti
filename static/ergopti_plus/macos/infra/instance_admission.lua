--- infra/instance_admission.lua

--- ==============================================================================
--- MODULE: Driver Instance Admission
--- DESCRIPTION:
--- Decides, before any module can arm a timer, a watcher or a settings write,
--- whether this Hammerspoon process may run the Ergopti driver.
---
--- FEATURES & RATIONALE:
--- 1. One owner: only the embedded runtime started by the ErgoptiPlus launcher
---    runs the driver. The launcher hands it the complete native logger
---    authority; nothing else can.
--- 2. A stray Ergopti runtime is refused quietly. macOS can start the embedded
---    runtime by itself (a session restore after a restart or an update
---    relaunch reopens every app that was running, the nested one included),
---    without the launcher's environment. On 2026-10-21 and 2026-10-22 such an
---    instance started beside the launcher's own, armed its keylogger timers,
---    then sat behind a blocking fatal dialog while those timers kept writing
---    to the shared daily log. It now exits before arming anything, with no
---    dialog: the launcher's instance is the one the user sees.
--- 3. The user's own Hammerspoon is never killed. A Hammerspoon that is not
---    the embedded runtime (a stock install whose configuration points at
---    Ergopti) is told why the driver did not start, and keeps running: an
---    os.exit there would quit the user's application.
--- 4. Pure: the environment mode and the process identity are passed in, so
---    every branch is tested without a live Hammerspoon.
--- ==============================================================================

local M = {}

-- Bundle identifiers written by tools/build/build_macos_app.sh; the Swift
-- launcher and modules/updater carry the same values, pinned together by
-- tools/test/test-launcher-single-instance.cjs.
M.EMBEDDED_RUNTIME_BUNDLE_ID = "com.ergoptiplus.app.hammerspoon"
M.LAUNCHER_BUNDLE_ID = "com.ergoptiplus.app"

M.ADMIT = "admit"
M.STRAY_RUNTIME = "stray_runtime"
M.FOREIGN_HAMMERSPOON = "foreign_hammerspoon"





-- ======================================
-- ======================================
-- ======= 1/ Admission Decision ========
-- ======================================
-- ======================================

--- Decides what this process does with the driver.
--- A partial launcher environment inside the embedded runtime is admitted
--- here on purpose: the launcher is alive to report it, and the logger
--- boundary in init.lua refuses it with its fatal report.
--- @param logger_mode string "managed", "standalone" or "invalid", from Logger.classify_async_sink_boot_environment().
--- @param bundle_id string|nil This process's bundle identifier.
--- @return string decision M.ADMIT, M.STRAY_RUNTIME or M.FOREIGN_HAMMERSPOON.
function M.decide(logger_mode, bundle_id)
	if bundle_id ~= M.EMBEDDED_RUNTIME_BUNDLE_ID then
		-- No launcher ever starts another bundle with its authority: refuse every mode
		if logger_mode == "managed" then return M.ADMIT end
		return M.FOREIGN_HAMMERSPOON
	end
	if logger_mode == "standalone" then return M.STRAY_RUNTIME end
	return M.ADMIT
end

--- Reports whether a refusal may end the process: only our own runtime's.
--- @param decision string Result of M.decide().
--- @return boolean
function M.may_exit_process(decision)
	return decision == M.STRAY_RUNTIME
end

--- Reports whether a refusal shows the blocking explanation. A stray runtime
--- shows none: its dialog was the one that kept its timers alive.
--- @param decision string Result of M.decide().
--- @return boolean
function M.shows_dialog(decision)
	return decision == M.FOREIGN_HAMMERSPOON
end





-- ======================================
-- ======================================
-- ======= 2/ Diagnostics ===============
-- ======================================
-- ======================================

--- Describes this process for the refusal line, so the next report says who
--- started it. Names and identifiers only; never environment values.
--- @param identity table { pid, bundle_id, bundle_path, launcher_running }.
--- @return string
function M.describe(identity)
	identity = type(identity) == "table" and identity or {}
	return string.format("pid %s, bundle %s at %s, ErgoptiPlus launcher running: %s",
		tostring(identity.pid), tostring(identity.bundle_id), tostring(identity.bundle_path),
		tostring(identity.launcher_running))
end

return M
