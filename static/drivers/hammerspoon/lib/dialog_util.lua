--- lib/dialog_util.lua

--- ==============================================================================
--- MODULE: Dialog Util
--- DESCRIPTION:
--- Thin wrappers around hs.dialog.* that always bring Hammerspoon to the front
--- before showing a modal. macOS only routes Return/Escape to the dialog's
--- default/cancel button when the owning app is frontmost — without an explicit
--- focus step, dialogs opened from a menubar click appear behind the current
--- app and Enter is captured by whatever the user was typing in instead.
---
--- FEATURES & RATIONALE:
--- 1. Single Source of Truth: Every dialog in the codebase goes through one
---    helper, so the "focus before open" rule cannot drift from site to site.
--- 2. Transparent API: Wrappers forward all arguments to hs.dialog.* unchanged
---    and return whatever the underlying call returns — drop-in replacement.
--- 3. Safe Focus: hs.focus is wrapped in pcall so a transient focus failure
---    (rare but possible during app-switch races) never prevents the dialog
---    from opening.
--- ==============================================================================

local hs = hs

local Logger = require("lib.logger")
local LOG    = "dialog_util"

local M = {}




-- ============================================
-- ============================================
-- ======= 1/ Focused Dialog Wrappers =======
-- ============================================
-- ============================================

--- Brings Hammerspoon to the front so the next modal dialog receives keyboard
--- focus. Wrapped in pcall because hs.focus can briefly fail during app
--- transitions and we never want that to stop the caller from opening its
--- dialog.
local function focus_hammerspoon()
	local ok, err = pcall(hs.focus)
	if not ok then
		Logger.debug(LOG, "hs.focus raised before dialog: %s.", tostring(err))
	end
end

--- Focus-aware wrapper around hs.dialog.blockAlert.
--- Returns whatever hs.dialog.blockAlert returns (clicked button name).
--- @return string The text of the button that was clicked.
function M.block_alert(...)
	focus_hammerspoon()
	return hs.dialog.blockAlert(...)
end

--- Focus-aware wrapper around hs.dialog.textPrompt.
--- Returns whatever hs.dialog.textPrompt returns (clicked button + text).
--- @return string The text of the button that was clicked.
--- @return string The text entered by the user.
function M.text_prompt(...)
	focus_hammerspoon()
	return hs.dialog.textPrompt(...)
end

--- Focus-aware wrapper around hs.dialog.alert (the non-blocking variant).
--- Focusing is still useful so the alert renders on top of the user's current
--- app and its auto-dismiss / button-click behaviour is predictable.
function M.alert(...)
	focus_hammerspoon()
	return hs.dialog.alert(...)
end

return M
