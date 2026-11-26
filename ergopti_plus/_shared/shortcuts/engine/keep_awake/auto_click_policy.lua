--- _shared/shortcuts/engine/keep_awake/auto_click_policy.lua

--- ==============================================================================
--- MODULE: Auto-Click Policy — Shared Lua Implementation
--- DESCRIPTION:
--- Decides whether one tick of the anti-sleep auto-clicker may capture the
--- foreground window, and whether a match found there may be clicked. The
--- matcher (auto_click_matcher.lua) finds pixels; this module owns every
--- refusal, so no driver can click outside its scope through a path of its own.
---
--- FEATURES & RATIONALE:
--- 1. Allowed apps only: the foreground app must be in the configured list
---    (VS Code and VS Code Insiders by default, by bundle id on macOS, by
---    executable on Windows, by WM class on Linux), compared without case.
---    A system « Allow » dialog belongs to another app and is never clicked.
--- 2. Never while the screen is locked, Ergopti is paused or a secure field
---    has the focus: a password prompt must never receive a synthetic click.
--- 3. Inside the window only: the whole match must lie within the captured
---    window bounds.
--- 4. One click per prompt: an image clicked less than its cooldown ago is
---    not clicked again, so a button that stays drawn for a frame or two after
---    the click is not pressed twice.
---
--- The reasons are a closed vocabulary (M.REASONS) that the drivers log through
--- the central logger. Pinned by
--- _shared/tests/corpus/keep_awake/auto_click_policy_vectors.json.
--- ==============================================================================

local M = {}




-- =============================================
-- =============================================
-- ======= 1/ Vocabulary =======================
-- =============================================
-- =============================================

-- Every outcome of a decision; a driver logs exactly one of them.
M.REASONS = {
	click = "click",
	app_not_allowed = "app_not_allowed",
	no_foreground_window = "no_foreground_window",
	screen_locked = "screen_locked",
	paused = "paused",
	secure_field = "secure_field",
	outside_window = "outside_window",
	cooldown = "cooldown",
}




-- =============================================
-- =============================================
-- ======= 2/ Public API =======================
-- =============================================
-- =============================================

--- Whether an app identity is in the allowed list.
--- @param app_id string|nil Bundle id, executable name or WM class.
--- @param allowed table Array of identities.
--- @return boolean
function M.app_allowed(app_id, allowed)
	assert(type(allowed) == "table", "the allowed apps are a list")
	if type(app_id) ~= "string" or app_id == "" then return false end
	local wanted = app_id:lower()
	for _, entry in ipairs(allowed) do
		if type(entry) == "string" and entry:lower() == wanted then return true end
	end
	return false
end

--- Whether a tick may capture the foreground window at all.
--- @param state table { app_id, allowed_apps, has_window, locked, paused, secure_field }
--- @return boolean allowed, string reason One of M.REASONS ("click" when allowed).
function M.may_capture(state)
	assert(type(state) == "table", "the policy needs the session state")
	if state.locked then return false, M.REASONS.screen_locked end
	if state.paused then return false, M.REASONS.paused end
	if state.secure_field then return false, M.REASONS.secure_field end
	if not state.has_window then return false, M.REASONS.no_foreground_window end
	if not M.app_allowed(state.app_id, state.allowed_apps) then return false, M.REASONS.app_not_allowed end
	return true, M.REASONS.click
end

--- Whether a match may be clicked now.
--- @param state table As M.may_capture, plus:
---   window      { width, height } capture size in pixels;
---   match       { x, y, width, height } as the matcher returns it;
---   image_id    string library image identity;
---   last_clicks table image_id -> time of its last click, in ms;
---   now_ms      number monotonic time;
---   cooldown_ms number least time between two clicks of one image.
--- @return boolean click, string reason One of M.REASONS.
function M.may_click(state)
	local ok, reason = M.may_capture(state)
	if not ok then return false, reason end
	local w, m = state.window, state.match
	assert(type(w) == "table" and type(m) == "table", "a click decision needs the window and the match")
	if m.x < 0 or m.y < 0 or m.x + m.width > w.width or m.y + m.height > w.height then
		return false, M.REASONS.outside_window
	end
	assert(type(state.image_id) == "string", "a click decision needs the image id")
	assert(type(state.now_ms) == "number" and type(state.cooldown_ms) == "number",
		"a click decision needs the time and the cooldown")
	local last = (state.last_clicks or {})[state.image_id]
	if last and state.now_ms - last < state.cooldown_ms then return false, M.REASONS.cooldown end
	return true, M.REASONS.click
end

return M
