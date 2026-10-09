--- modules/shortcuts/actions/screen_capture_flow.lua

--- ==============================================================================
--- MODULE: Screen Capture Flow
--- DESCRIPTION:
--- Shared admission and verdict rules for every screencapture entry point of
--- the macOS driver: the Ctrl+H interactive screenshot, the pixel color reader,
--- and the configurable shortcut and gesture screenshots.
---
--- FEATURES & RATIONALE:
--- 1. Permission first: the packaged runtime has its own identity, so a Screen
---    Recording grant held by another Hammerspoon does not apply. A capture
---    without the grant used to show the selection and then leave nothing on
---    the clipboard, with only a warning in the log. The permission is now
---    checked before launch. This gate is the one owner of that refusal.
--- 2. Stale entry reset: the packaged app is signed ad hoc, so each build or
---    update has a new code identity. System Settings keeps the previous switch
---    checked while macOS refuses the new binary, and captures failed until the
---    user deleted the entry by hand. The first refusal of a session resets
---    this app's own entry with tccutil, then asks macOS for its prompt, opens
---    the exact pane, and names the entry to turn on. Once per session only:
---    repeating it would loop over a user who is still deciding, so later
---    refusals only explain, with a click that opens the pane.
--- 3. Files, not `-c`: every capture writes to a file the caller owns. The
---    clipboard is then filled from that file and read back, so success is
---    never claimed without an image on the pasteboard.
--- 4. Held Control: in interactive mode, holding Control sends the capture to
---    the clipboard instead of the file. Ctrl+H is still held when the selector
---    opens, so an advanced pasteboard change count with an image counts as a
---    copy rather than as a missing file.
--- 5. Cancel is silent: an interactive capture that exits non-zero with no
---    output, no error text and no clipboard change is the user pressing
---    Escape. Every other empty result is a visible failure with its exit code.
--- 6. Dependencies are resolved at call time, so a cached instance never keeps
---    another caller's adapters.
--- ==============================================================================

local M = {}

local LOG = "shortcuts.actions.screen_capture"

M.OUTCOME_COPIED = "copied"
M.OUTCOME_SAVED = "saved"
M.OUTCOME_CANCELLED = "cancelled"
M.OUTCOME_FAILED = "failed"

-- One stale-entry reset and prompt per session: macOS only shows its prompt
-- the first time an application asks, and resetting again while the user is
-- still deciding would remove the switch they are about to turn on.
local _permission_prompt_requested = false





-- ===================================
-- ===================================
-- ======= 1/ Dependencies ===========
-- ===================================
-- ===================================

local function capture_adapter() return require("adapters.screen_capture") end
local function file_system() return require("adapters.file_system") end
local function logger() return require("infra.logger") end

--- Sends one notification; a notifier failure is logged, never raised.
--- @param title string Notification title or message.
--- @param body string|nil Optional body.
--- @param kind string Notification kind.
--- @param on_click function|nil What a click on the notification does.
local function notify(title, body, kind, on_click)
	local ok, err = pcall(function()
		return require("infra.notifications").notify(title, body, kind, on_click)
	end)
	if not ok then
		logger().error(LOG, "Screen capture notification failed: %s.", tostring(err))
	end
end

--- Resolves one translated string.
--- @param key string Locale key.
--- @return string text
local function text(key)
	return require("infra.i18n").get(key)
end





-- ===================================
-- ===================================
-- ======= 2/ Permission Gate ========
-- ===================================
-- ===================================

--- Opens the Screen Recording pane, from the gate or from a clicked notice.
local function open_settings()
	local opened, open_err = capture_adapter().open_permission_settings()
	if not opened then
		logger().error(LOG, "Screen Recording settings could not be opened: %s.", tostring(open_err))
	end
end

--- Explains the refusal; a click on the notice opens the Screen Recording pane.
--- @param body_key string Locale key of the explanation.
local function notify_refusal(body_key)
	notify(text("shortcuts.screen_recording_required_title"), text(body_key), "error", open_settings)
end

--- Asks macOS for its prompt, opens the pane and names the entry to turn on.
--- @param Adapter table Screen capture adapter.
--- @param body_key string Locale key of the explanation.
local function prompt_user(Adapter, body_key)
	local requested, request_err = Adapter.request_permission()
	if not requested then
		logger().error(LOG, "Screen Recording prompt could not be requested: %s.", tostring(request_err))
	end
	notify_refusal(body_key)
	open_settings()
end

--- Clears this app's stale entry, then prompts once tccutil has settled. The
--- notice says the old switch was removed only when the reset succeeded.
--- @param Adapter table Screen capture adapter.
local function reset_then_prompt(Adapter)
	local Logger = logger()
	local bundle_id, bundle_err = Adapter.bundle_id()
	if bundle_id == nil then
		Logger.warn(LOG, "Stale Screen Recording entry not reset: %s.", tostring(bundle_err))
		prompt_user(Adapter, "shortcuts.screen_recording_required")
		return
	end
	Logger.start(LOG, "Resetting the Screen Recording entry of %s…", bundle_id)
	local started = Adapter.reset_permission(bundle_id, function(ok, detail)
		if ok then
			Logger.success(LOG, "Screen Recording entry of %s reset.", bundle_id)
			prompt_user(Adapter, "shortcuts.screen_recording_reset")
			return
		end
		Logger.warn(LOG, "Screen Recording entry of %s not reset: %s.", bundle_id, tostring(detail))
		prompt_user(Adapter, "shortcuts.screen_recording_required")
	end)
	if started ~= true then
		Logger.warn(LOG, "tccutil could not be started; prompting without resetting %s.", bundle_id)
		prompt_user(Adapter, "shortcuts.screen_recording_required")
	end
end

--- Admits a capture only when Screen Recording is granted. The first refusal
--- of the session resets this app's stale entry, asks macOS for its prompt,
--- opens System Settings and names the entry to turn on; later refusals only
--- explain, with a click that opens the pane.
--- @param context string Diagnostic label of the entry point.
--- @return boolean admitted
function M.ensure_permission(context)
	local Adapter = capture_adapter()
	local Logger = logger()
	local granted, detail = Adapter.permission_state()
	if granted == true then return true end

	if granted == nil then
		Logger.error(LOG, "%s refused: the Screen Recording state query failed: %s.",
			tostring(context), tostring(detail))
	else
		Logger.warn(LOG, "%s refused: Screen Recording is not granted to the ErgoptiPlus runtime.",
			tostring(context))
	end

	if _permission_prompt_requested then
		notify_refusal("shortcuts.screen_recording_required")
		return false
	end
	_permission_prompt_requested = true
	-- A failed query proves nothing about the entry, so only a refusal resets it.
	if granted == false then
		reset_then_prompt(Adapter)
	else
		prompt_user(Adapter, "shortcuts.screen_recording_required")
	end
	return false
end





-- ===================================
-- ===================================
-- ======= 3/ Capture Verdict ========
-- ===================================
-- ===================================

--- Tells whether a screencapture argument vector lets the user cancel.
--- @param flags table screencapture flags.
--- @return boolean interactive
function M.is_interactive(flags)
	if type(flags) ~= "table" then return false end
	for _, flag in ipairs(flags) do
		local letters = tostring(flag):match("^%-(%a+)$")
		if letters and (letters:find("i", 1, true) or letters:find("w", 1, true)
			or letters:find("W", 1, true)) then
			return true
		end
	end
	return false
end

--- Tells whether a screencapture argument vector targets the clipboard itself.
--- @param flags table screencapture flags.
--- @return boolean targets_clipboard
function M.targets_clipboard(flags)
	if type(flags) ~= "table" then return false end
	for _, flag in ipairs(flags) do
		local letters = tostring(flag):match("^%-(%a+)$")
		if letters and letters:find("c", 1, true) then return true end
	end
	return false
end

--- Snapshots the pasteboard change count before a capture starts.
--- @return number|nil count Nil when the count is unreadable.
function M.clipboard_mark()
	local count, detail = capture_adapter().clipboard_change_count()
	if count == nil then
		logger().error(LOG, "Pasteboard change count is unreadable before capture: %s.",
			tostring(detail))
	end
	return count
end

--- Reports whether a capture file holds data.
--- @param path string Capture file.
--- @return string state `image`, `none`, or `error`.
--- @return string|nil detail Failure detail.
local function capture_file_state(path)
	if type(path) ~= "string" or path == "" then return "error", "capture path is missing" end
	local ok, attributes, status, detail = pcall(file_system().classify_no_follow, path)
	if not ok then return "error", tostring(attributes) end
	if status == "absent" then return "none" end
	if status ~= "ok" or type(attributes) ~= "table" then
		return "error", tostring(detail or status)
	end
	if attributes.mode ~= "file" then return "error", "capture path is not a regular file" end
	if (tonumber(attributes.size) or 0) > 0 then return "image" end
	return "none"
end

--- Reports whether screencapture itself put an image on the clipboard.
--- @param mark number|nil Change count taken before the capture.
--- @return boolean redirected
local function clipboard_received_capture(mark)
	if mark == nil then return false end
	local Adapter = capture_adapter()
	local now = Adapter.clipboard_change_count()
	if now == nil or now == mark then return false end
	return Adapter.clipboard_has_image() == true
end

--- Decides what one finished screencapture produced, and completes a
--- clipboard destination by copying the file and verifying the pasteboard.
--- @param capture table Fields: path, mark, exit_code, stderr, interactive,
---        destination (`clipboard` or `file`).
--- @return string outcome One of the OUTCOME_* values.
--- @return string|nil detail Failure detail for OUTCOME_FAILED.
function M.settle(capture)
	local exit_code = capture.exit_code
	local stderr = type(capture.stderr) == "string" and capture.stderr:gsub("%s+$", "") or ""
	local state, state_err = capture_file_state(capture.path)
	if state == "error" then
		return M.OUTCOME_FAILED, "capture file is unreadable: " .. tostring(state_err)
	end

	if exit_code ~= 0 then
		-- A partial file after a failed exit is not a trusted image.
		if state == "none" and capture.interactive == true and stderr == ""
			and not clipboard_received_capture(capture.mark) then
			return M.OUTCOME_CANCELLED
		end
		return M.OUTCOME_FAILED, string.format("screencapture exited with code %s: %s",
			tostring(exit_code), stderr ~= "" and stderr or "no error output")
	end

	if state == "image" then
		if capture.destination ~= "clipboard" then return M.OUTCOME_SAVED end
		local copied, copy_err = capture_adapter().copy_image_file_to_clipboard(capture.path)
		if copied then return M.OUTCOME_COPIED end
		return M.OUTCOME_FAILED, "clipboard write not verified: " .. tostring(copy_err)
	end

	if clipboard_received_capture(capture.mark) then
		logger().info(LOG, "screencapture sent the image to the clipboard (Control held).")
		return M.OUTCOME_COPIED
	end
	return M.OUTCOME_FAILED, "screencapture exited with code 0 but produced no image"
end

return M
