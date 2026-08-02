--- infra/dialog_util.lua

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

local Logger         = require("infra.logger")
local ShellRunner    = require("adapters.shell_runner")
local TimerScheduler = require("adapters.timer_scheduler")

-- Absolute path: this process does not inherit the login shell's PATH.
local OPEN_BIN = "/usr/bin/open"
local LOG    = "dialog_util"

local M = {}





-- ==========================================
-- ==========================================
-- ======= 1/ Focused Dialog Wrappers =======
-- ==========================================
-- ==========================================

--- Brings Hammerspoon to the front so the next modal dialog receives keyboard
--- focus. Wrapped in pcall because hs.focus can briefly fail during app
--- transitions and we never want that to stop the caller from opening its
--- dialog.
---
--- @param defer_open boolean|nil True only for the NON-BLOCKING wrapper. The
---   deferred `open` below cannot run before a modal dialog is dismissed — the
---   dialog owns the runloop — so for the blocking wrappers it is dead with
---   respect to its purpose while keeping its side effect: it fires after the
---   user has dismissed the dialog and moved on, and raises Hammerspoon over
---   whatever they switched to. Two synchronous do_focus() calls are what
---   actually focuses the dialog; this third mechanism only helps the case where
---   the runloop keeps turning.
local function focus_hammerspoon(defer_open)
	local function do_focus()
		local ok, err = pcall(function() return hs.focus(true) end)
		if not ok then
			Logger.debug(LOG, "hs.focus raised before dialog: %s.", tostring(err))
		end
		pcall(function()
			local app = hs.application.get("Hammerspoon")
			if app then app:activate(true) end
		end)
	end

	do_focus()
	do_focus()
	-- Third mechanism: raise the app again a tenth of a second later, for the case
	-- where the dialog was opened from a menubar click and the click itself steals
	-- focus back after the two calls above.
	--
	-- It only reaches a dialog whose runloop keeps turning. hs.dialog.blockAlert
	-- and hs.dialog.textPrompt park the main thread and its default runloop until
	-- the user dismisses them, so a timer armed here cannot fire until after
	-- dismissal — at which point there is no dialog left to focus and the raise
	-- lands on whatever the user switched to instead. That is why only the
	-- non-blocking wrapper asks for it.
	if not defer_open then return end
	pcall(function()
		local bundlePath = hs.processInfo.bundlePath
		if bundlePath then
			-- Asynchronous, and argv rather than a shell string. `open` waits on
			-- Launch Services, so the blocking form parked the single runloop for that
			-- whole window immediately before putting up a modal dialog — the one
			-- moment the driver can least afford to stop servicing the keyboard tap.
			-- The argv form also retires the hand-rolled single-quote escaping, which
			-- duplicated text_utils.shell_quote and covered only the quote.
			--
			-- The GC pitfall the old comment worried about is handled by the spawner:
			-- it pins the task in its own long-lived table before starting it and
			-- releases it in the completion callback.
			TimerScheduler.after(0.1, function()
				local handle = ShellRunner.spawn(OPEN_BIN, { bundlePath })
				if handle then handle.start() end
			end)
		end
	end)
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
	-- The only wrapper whose dialog does not park the runloop, so the only one
	-- the deferred raise can reach in time to do what it is for.
	focus_hammerspoon(true)
	return hs.dialog.alert(...)
end

return M
