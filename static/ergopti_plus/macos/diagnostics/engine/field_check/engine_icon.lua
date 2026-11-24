--- diagnostics/engine/field_check/engine_icon.lua

--- ==============================================================================
--- MODULE: Field Check, Engine Icon
--- DESCRIPTION:
--- The field run's read of the icon the embedded engine declares (TODO, To
--- confirm on the Mac, « Engine dialog icon »). Hammerspoon sets no icon at
--- run time and hs.dialog.blockAlert gives its NSAlert none, so every engine
--- dialog shows the icon of the bundle's Info.plist: the build must have
--- left CFBundleIconFile on ErgoptiPlus, removed CFBundleIconName (which
--- would send macOS to Hammerspoon's asset catalogue and its hammer) and
--- copied the icns beside it.
---
--- FEATURES & RATIONALE:
--- 1. Read from the running engine's own bundle, so a pass proves what the
---    installed app ships, not what the build script meant to write.
--- 2. A pass with the hammer still on screen leaves only a stale Launch
---    Services entry, which no file read can see: the field point says so.
--- 3. An engine outside ErgoptiPlus.app (a stock Hammerspoon) is a skip by
---    name, never a failure.
--- ==============================================================================

local Report = require("diagnostics.engine.field_check.report")

local M = {}

local PASS, FAIL, INFO, SKIP = Report.STATE_PASS, Report.STATE_FAIL, Report.STATE_INFO, Report.STATE_SKIP

-- The icon name the build gives the embedded engine (tools/build/build_macos_app.sh, build_icon)
M.ICON_FILE = "ErgoptiPlus"

--- Runs the check.
--- ports.engine_icon_facts() → { embedded, readable, icon_file, icon_name, icns_present }.
--- @param ports table
--- @param report table field_check_report report.
--- @param finish function
function M.engine_icon(ports, report, finish)
	local facts = ports.engine_icon_facts()
	if not facts.embedded then
		report.step("engine_embedded", SKIP, "not_embedded")
		return finish()
	end
	report.step("engine_embedded", INFO, "yes")
	if not facts.readable then
		report.step("engine_icon_file", FAIL, "info_plist_unreadable")
		return finish()
	end
	local file = tostring(facts.icon_file or ""):gsub("%.icns$", "")
	report.step("engine_icon_file", file == M.ICON_FILE and PASS or FAIL,
		file ~= "" and file or "absent")
	report.step("engine_icon_name", facts.icon_name == nil and PASS or FAIL,
		facts.icon_name == nil and "absent" or tostring(facts.icon_name))
	report.step("engine_icns", facts.icns_present and PASS or FAIL, facts.icns_present and "present" or "missing")
	finish()
end

return M
