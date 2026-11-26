--- _shared/settings/engine/publication/save_failure.lua

--- ==============================================================================
--- MODULE: Configuration Save Failure Notice
--- DESCRIPTION:
--- Shows the generic « could not be saved » notice of a refused menu change on
--- macOS and Linux, unless the TOML writer already named a case twin for that
--- refusal. Windows reaches the same rule through ConfigReportPersistenceFailure.
---
--- FEATURES & RATIONALE:
--- 1. One Notice Per Refusal: the writer shows `dialog.config_save.case_twin`
---    itself, because its callers only learn that the save failed. A caller that
---    then showed the generic text would blame an app holding the file, which
---    names the wrong cause right after the right one.
--- 2. Single Key Owner: menus never read `dialog.bulk_toggle.save_failed`
---    themselves, so no caller can forget the case-twin check.
--- ==============================================================================

local M = {}

M.MESSAGE_KEY = "dialog.bulk_toggle.save_failed"

--- Shows the generic save failure unless a case-twin notice already named it.
--- @param translate function Locale lookup: key -> localized text.
--- @param show function Receives the localized message to show.
--- @return boolean shown True when the generic notice was shown.
function M.present(translate, show)
	assert(type(translate) == "function", "a save failure notice needs the locale lookup")
	assert(type(show) == "function", "a save failure notice needs its presenter")
	-- Resolved per call: the notice lives in the writer instance that refused.
	if require("core.text.engine.toml_codec.writer").take_case_twin_notice() ~= nil then return false end
	show(translate(M.MESSAGE_KEY))
	return true
end

return M
