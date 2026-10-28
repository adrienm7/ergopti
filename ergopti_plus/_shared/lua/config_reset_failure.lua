--- _shared/lua/config_reset_failure.lua

--- ==============================================================================
--- MODULE: Reset Failure Message
--- DESCRIPTION:
--- Composes the dialog a refused Configuration › « Restore recommended values »
--- or « Clear all » shows on macOS and Linux: the Windows reset failure text
--- (`dialog.reset_defaults.failed`) with the reason of the typed failure point
--- the shared scope composition named in its report.
---
--- FEATURES & RATIONALE:
--- 1. One Reason Per Point: acquire (another transaction still owns the
---    configuration), commit (a category refused and every committed one was
---    reverted), rollback (the revert itself was refused) and finalize (the
---    values were applied but the composition could not forget its backups).
---    The generic « could not be saved, it has been reverted » text claimed a
---    revert for the last two, where none took place.
--- 2. No Reload Point: the Windows reset reloads the driver, so it also has
---    `reload_refused`. The macOS and Linux restore and clear apply every
---    category live through its own owner and reload nothing, so that point
---    cannot arise there and has no entry here.
--- 3. Stable Identifiers: the reason names the refusing category (or the
---    composite scope) and the report's stable kind, as the Windows text names
---    the transition's status and kind, so the dialog matches the log.
--- 4. Fail Fast: a refused report without a known point is a composition
---    defect and raises instead of showing a guessed reason.
--- ==============================================================================

local M = {}

--- The reason key of each typed failure point of a composed reset.
M.REASON_KEYS = {
	acquire  = "dialog.reset_defaults.reason.acquire",
	commit   = "dialog.reset_defaults.reason.commit",
	rollback = "dialog.reset_defaults.reason.rollback",
	finalize = "dialog.reset_defaults.reason.finalize",
}

M.TITLE_KEY = "dialog.reset_defaults.failed_title"
M.MESSAGE_KEY = "dialog.reset_defaults.failed"

--- Replaces the first literal placeholder, leaving a template without it as is.
--- @param template string Localized text.
--- @param placeholder string Literal placeholder such as "{1}".
--- @param value string Replacement text, inserted literally.
--- @return string filled
local function fill(template, placeholder, value)
	local at = template:find(placeholder, 1, true)
	if not at then return template end
	return template:sub(1, at - 1) .. value .. template:sub(at + #placeholder)
end

--- Composes the failure dialog of one refused composition report.
--- @param report table Report of a refused request (point, kind, failed, scope).
--- @param translate function Locale lookup: key -> localized text.
--- @return string title Localized dialog title.
--- @return string message Localized dialog body naming the failure point.
function M.message(report, translate)
	assert(type(report) == "table", "a reset failure needs the composition report")
	assert(type(translate) == "function", "a reset failure needs the locale lookup")
	local key = M.REASON_KEYS[report.point]
	assert(key ~= nil, "the refused scope report names no typed failure point: " .. tostring(report.point))
	assert(type(report.kind) == "string" and report.kind ~= "",
		"the refused scope report names no failure kind for point " .. tostring(report.point))
	local subject = report.failed or report.scope
	assert(type(subject) == "string" and subject ~= "", "the refused scope report names no scope")
	local reason = fill(fill(translate(key), "{1}", subject), "{2}", report.kind)
	return translate(M.TITLE_KEY), fill(translate(M.MESSAGE_KEY), "{1}", reason)
end

return M
