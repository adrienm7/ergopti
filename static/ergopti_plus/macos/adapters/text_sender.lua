--- adapters/text_sender.lua

--- ==============================================================================
--- MODULE: TextSender Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the TextSender port contract defined in
--- static/ergopti_plus/_shared/core/ports/TextSender.spec.js. Bridges domain-level text
--- insertion requests to the synthetic-input and Clipboard port adapters
--- without coupling domain modules to any hs event-construction API.
---
--- FEATURES & RATIONALE:
--- 1. Auto mode: when opts.mode == "auto" (default), payloads longer than
---    CLIPBOARD_THRESHOLD characters use the clipboard path (paste) to avoid
---    the overhead of simulating keystrokes for large insertions.
--- 2. Direct mode: the tagged synthetic-input adapter drives character-by-character
---    injection — required when clipboard is inaccessible (e.g., password fields).
--- 3. Clipboard port: the clipboard path delegates to the Clipboard adapter
---    (adapters/clipboard.lua) via save/write/restore instead of touching
---    hs.pasteboard directly — keeps the interaction testable and centralises
---    all clipboard I/O in a single adapter.
--- 4. Callback semantics: the callback is always invoked synchronously after the
---    tagged request is accepted for dispatch, matching the contract's "called
---    inline" note even though Quartz delivery itself remains asynchronous.
--- ==============================================================================

local M = {}

local hs       = hs
local Logger   = require("infra.logger")
local Timings  = require("infra.timings")
local Clipboard = require("adapters.clipboard")
local SyntheticInput = require("adapters.synthetic_input")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "adapters.text_sender"


-- =========================================
-- =========================================
-- ======= 1/ Constants ====================
-- =========================================
-- =========================================

-- Payload length above which "auto" mode switches to clipboard injection.
-- Mirrors TextSender.spec.js CLIPBOARD_THRESHOLD = 1000.
local CLIPBOARD_THRESHOLD = 1000

-- Delay in seconds before the clipboard is restored after a paste injection.
-- Long enough for the receiving application to process Cmd+V before we overwrite.
-- Shared cross-driver value ([debounce] clipboard_restore_ms).
local CLIPBOARD_RESTORE_DELAY_S = Timings.sec("debounce", "clipboard_restore_ms")

-- Paste keystroke on macOS.
local PASTE_KEY      = "v"
local PASTE_MODIFIER = { "cmd" }

-- Explicit inter-key delay for the paste keystroke, matching the 0 default that
-- M.eraseChars/M.pressKey already apply. Omitting the argument makes
-- hs.eventtap.keyStroke() fall back to 200 000 us implemented as a BLOCKING usleep,
-- stalling the run loop that services the typing event tap mid-injection.
local PASTE_KEY_DELAY_US = 0

-- Terminal hosts whose prompt controls may batch a zero-delay Backspace run
-- against one stale render. Bundle IDs are normalized before lookup; app-name
-- fallbacks cover unsigned/custom builds that expose no stable bundle ID.
local TERMINAL_BUNDLE_IDS = {
	["com.apple.terminal"] = true,
	["com.googlecode.iterm2"] = true,
	["com.github.wez.wezterm"] = true,
	["org.alacritty"] = true,
	["net.kovidgoyal.kitty"] = true,
	["com.mitchellh.ghostty"] = true,
	["co.zeit.hyper"] = true,
	["org.tabby"] = true,
	["dev.warp.warp-stable"] = true,
}

local TERMINAL_APP_NAMES = {
	["terminal"] = true,
	["iterm2"] = true,
	["wezterm"] = true,
	["alacritty"] = true,
	["kitty"] = true,
	["ghostty"] = true,
	["hyper"] = true,
	["tabby"] = true,
	["warp"] = true,
}

-- Serialised clipboard save/restore state. Two clipboard sends within
-- CLIPBOARD_RESTORE_DELAY_S of each other must NOT each save() — the second would
-- capture the first's still-injected payload as "the user's clipboard" and both
-- restores would then clobber the real original. On an overlapping send we cancel
-- the pending restore but KEEP the first-captured original (mirrors the
-- keymap/utils.lua paste discipline). Declared ABOVE M.send so the restore closures
-- capture them correctly (F-L8).
local _paste_saved_original = nil
local _paste_pending_timer = nil
local _paste_timer_cleanup = nil
local _paste_owns_clipboard = false
local _paste_recovery_only = false
local _paste_generation = 0

--- Reports whether one application identity is a terminal input host.
--- @param bundle_id string|nil macOS bundle identifier.
--- @param app_name string|nil Application display name.
--- @return boolean is_terminal
function M.isTerminalInputHost(bundle_id, app_name)
	local bundle = type(bundle_id) == "string" and bundle_id:lower() or ""
	local name = type(app_name) == "string" and app_name:lower() or ""
	return TERMINAL_BUNDLE_IDS[bundle] == true or TERMINAL_APP_NAMES[name] == true
end

--- Returns the focused terminal application to use for targeted paced output.
--- A nil result keeps the ordinary callback-return batch path.
--- @return userdata|table|nil app
function M.terminalInputTarget()
	local app = nil
	local ok_window, window = pcall(function()
		return hs.window and hs.window.focusedWindow and hs.window.focusedWindow()
	end)
	if ok_window and window then
		local ok_app, focused_app = pcall(function() return window:application() end)
		if ok_app then app = focused_app end
	end
	if app == nil then
		local ok_front, front = pcall(function()
			return hs.application and hs.application.frontmostApplication
				and hs.application.frontmostApplication()
		end)
		if ok_front then app = front end
	end
	if app == nil then return nil end

	local ok_bundle, bundle = pcall(function() return app:bundleID() end)
	local ok_name, name = pcall(function() return app:name() end)
	if M.isTerminalInputHost(ok_bundle and bundle or "", ok_name and name or "") then
		return app
	end
	return nil
end

local function cancel_restore_timer(timer)
	if type(timer) ~= "table" or timer.timer == nil then return true end
	local ok_cancel, settled_or_error = pcall(TimerScheduler.cancel, timer)
	if ok_cancel and settled_or_error == true then return true end
	_paste_timer_cleanup = timer
	Logger.error(LOG, "Clipboard restore timer cleanup remains pending: %s",
		tostring(settled_or_error))
	return false
end

local function retry_restore_timer_cleanup()
	local cleanup = _paste_timer_cleanup
	if cleanup == nil then return true end
	if cancel_restore_timer(cleanup) ~= true then return false end
	if _paste_timer_cleanup == cleanup then _paste_timer_cleanup = nil end
	return true
end

local function stop_restore_timer()
	local pending = _paste_pending_timer
	_paste_pending_timer = nil
	if pending and cancel_restore_timer(pending) ~= true then return false end
	return retry_restore_timer_cleanup()
end

local function release_clipboard()
	stop_restore_timer()
	_paste_saved_original = nil
	_paste_owns_clipboard = false
	_paste_recovery_only = false
	_paste_generation = _paste_generation + 1
end

local function restore_clipboard()
	if not _paste_owns_clipboard then return true end
	local ok_restore, restored = pcall(Clipboard.restore, _paste_saved_original)
	if not ok_restore or restored ~= true then
		return false, ok_restore and "Clipboard.restore returned " .. tostring(restored) or restored
	end
	release_clipboard()
	return true
end

local queue_restore_retry

local function schedule_restore()
	if _paste_pending_timer then return true end
	if retry_restore_timer_cleanup() ~= true then
		return false, "prior restore timer cleanup remains unsettled"
	end
	local generation = _paste_generation
	local callback_ran = false
	-- Never run recovery before TimerScheduler has committed its handle. A synchronous
	-- callback would otherwise recurse through queue_restore_retry() while
	-- _paste_pending_timer is still nil.
	local installing = true
	local timer_handle = nil
	local ok_timer, timer_or_error, timer_committed = pcall(
		TimerScheduler.after, CLIPBOARD_RESTORE_DELAY_S, function()
			callback_ran = true
			if installing then return end
			if timer_handle and timer_handle.timer ~= nil then
				_paste_timer_cleanup = timer_handle
			end
			_paste_pending_timer = nil
			if generation ~= _paste_generation or not _paste_owns_clipboard then return end
			local restored, restore_error = restore_clipboard()
			if restored then return end
			_paste_recovery_only = true
			Logger.error(LOG, "Clipboard restore refused; ownership retained — %s", tostring(restore_error))
			queue_restore_retry()
		end)
	timer_handle = timer_or_error
	installing = false
	if not ok_timer or timer_committed ~= true
		or type(timer_or_error) ~= "table" or timer_or_error.timer == nil or callback_ran then
		if type(timer_or_error) == "table" then cancel_restore_timer(timer_or_error) end
		return false, ok_timer and "TimerScheduler.after returned no committed handle" or timer_or_error
	end
	_paste_pending_timer = timer_or_error
	return true
end

queue_restore_retry = function()
	if not _paste_owns_clipboard then return true end
	local scheduled, timer_error = schedule_restore()
	if scheduled then return true end
	if type(SyntheticInput.defer_after_callback) == "function" then
		local generation = _paste_generation
		local callback_ran = false
		local installing = true
		local ok_defer, deferred = pcall(SyntheticInput.defer_after_callback,
			"text sender clipboard restore recovery", function()
				callback_ran = true
				if installing then return end
				if generation ~= _paste_generation or not _paste_owns_clipboard then return end
				local restored, restore_error = restore_clipboard()
				if restored then return end
				_paste_recovery_only = true
				Logger.error(LOG, "Deferred clipboard restore refused; ownership retained — %s",
					tostring(restore_error))
				queue_restore_retry()
			end)
		installing = false
		if ok_defer and deferred == true and not callback_ran then return true end
	end
	Logger.error(LOG, "Clipboard restore retry could not be armed — %s", tostring(timer_error))
	return false
end


-- =========================================
-- =========================================
-- ======= 2/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Inserts text at the current insertion point.
--- Uses the Clipboard port (Clipboard.save / Clipboard.write / Clipboard.restore)
--- for the clipboard path so the interaction is mockable and the driver has one
--- canonical clipboard code path.
--- @param text     string       The Unicode text to insert.
--- @param opts     table|nil    { mode?: "direct"|"clipboard"|"auto" }
--- @param callback function|nil Called with no arguments on completion.
function M.send(text, opts, callback)
	if type(text) ~= "string" then
		Logger.error(LOG, "M.send() requires a string, got %s — ignoring call.", type(text))
		return false
	end
	local options = type(opts) == "table" and opts or {}
	local mode    = type(options.mode) == "string" and options.mode or "auto"

	-- Resolve "auto" to a concrete strategy based on payload length.
	if mode == "auto" then
		mode = #text > CLIPBOARD_THRESHOLD and "clipboard" or "direct"
	end

	local ok, err
	if mode == "clipboard" then
		ok, err = pcall(function()
			if _paste_recovery_only then
				local restored, restore_error = restore_clipboard()
				if not restored then
					queue_restore_retry()
					error("previous clipboard recovery remains pending: " .. tostring(restore_error), 0)
				end
			end
			-- If a restore is still pending from a previous clipboard send, cancel it
			-- but KEEP the first-captured original; only capture the user's clipboard
			-- when no send is in flight (otherwise we'd save our own injected payload).
			if _paste_owns_clipboard then
				if stop_restore_timer() ~= true then
					local restored, restore_error = restore_clipboard()
					if not restored then queue_restore_retry() end
					error("prior clipboard timer cleanup remains pending: "
						.. tostring(restore_error), 0)
				end
			else
				local snapshot, snapshot_ok = Clipboard.save()
				assert(snapshot_ok == true, "clipboard snapshot failed")
				_paste_saved_original = snapshot
			end

			_paste_generation = _paste_generation + 1
			_paste_owns_clipboard = true
			_paste_recovery_only = true
			local ok_write, written = pcall(function() return Clipboard.write(text) end)
			if not ok_write or written ~= true then
				local restored, restore_error = restore_clipboard()
				if not restored then queue_restore_retry() end
				error("clipboard payload refused (restore=" .. tostring(restore_error) .. ")", 0)
			end

			local restore_armed, timer_error = schedule_restore()
			if not restore_armed then
				local restored, restore_error = restore_clipboard()
				if not restored then queue_restore_retry() end
				error("clipboard restore timer refused: " .. tostring(timer_error)
					.. " (restore=" .. tostring(restore_error) .. ")", 0)
			end

			local ok_emit, emitted = pcall(
				SyntheticInput.emit_key_stroke, PASTE_MODIFIER, PASTE_KEY, PASTE_KEY_DELAY_US)
			if not ok_emit or emitted ~= true then
				stop_restore_timer()
				local restored, restore_error = restore_clipboard()
				if not restored then queue_restore_retry() end
				error("synthetic paste keystroke refused (restore="
					.. tostring(restore_error) .. ")", 0)
			end
			_paste_recovery_only = false
		end)
	else
		ok, err = pcall(function()
			assert(SyntheticInput.emit_key_strokes(text),
				"synthetic text could not be dispatched")
		end)
	end

	if not ok then
		Logger.error(LOG, "send(): injection failed (mode=%s) — %s", mode, tostring(err))
	end

	if type(callback) == "function" then
		pcall(callback)
	end
	return ok == true
end

--- Emits count Backspace keystrokes synchronously.
--- @param count integer Number of Backspace keystrokes to emit.
--- @param delay number|nil Legacy Hammerspoon delay in microseconds (defaults to 0;
---   the provenance adapter accepts only the native no-delay range [0, 1)).
function M.eraseChars(count, ...)
	if type(count) ~= "number" or count < 1 then return true end
	local delay = select(1, ...)
	local key_delay = tonumber(delay) or 0
	local ok, err = pcall(function()
		for _ = 1, count do
			assert(SyntheticInput.emit_key_stroke({}, "delete", key_delay),
				"synthetic Backspace could not be dispatched")
		end
	end)
	if not ok then
		Logger.error(LOG, "eraseChars(%d): failed — %s", count, tostring(err))
	end
	return ok == true
end

--- Emits a single keystroke with optional modifiers.
--- @param key       string   Key name (e.g. "return", "escape", "f1").
--- @param modifiers table    Array of modifier names: "ctrl"|"shift"|"alt"|"cmd".
--- @param delay     number|nil Legacy Hammerspoon delay in microseconds (defaults
---   to 0; the provenance adapter accepts only the native no-delay range [0, 1)).
function M.pressKey(key, modifiers, ...)
	local mods = type(modifiers) == "table" and modifiers or {}
	local delay = select(1, ...)
	local key_delay = tonumber(delay) or 0
	local ok, err = pcall(function()
		assert(SyntheticInput.emit_key_stroke(mods, key, key_delay),
			"synthetic keystroke could not be dispatched")
	end)
	if not ok then
		Logger.error(LOG, "pressKey('%s'): failed — %s", tostring(key), tostring(err))
	end
	return ok == true
end

return M
