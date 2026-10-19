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
-- restores would then clobber the real original. Native handoff and host grace
-- refuse overlaps. If grace has elapsed but restoration is still queued, a new
-- send keeps the first-captured original. Declared ABOVE M.send so the restore closures
-- capture them correctly (F-L8).
local _paste_saved_original = nil
local _paste_pending_timer = nil
local _paste_timer_cleanup = nil
local _paste_owns_clipboard = false
local _paste_recovery_only = false
local _paste_generation = 0
local _paste_transaction = nil
local _paste_native_pending = false
local _paste_restore_after = nil
local _paste_owned_count = nil
local _paste_unproven_count = nil
local _paste_mutations = 0

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
	_paste_owned_count = nil
	_paste_unproven_count = nil
	_paste_owns_clipboard = false
	_paste_recovery_only = false
	_paste_transaction = nil
	_paste_native_pending = false
	_paste_restore_after = nil
	_paste_generation = _paste_generation + 1
end

local function paste_settling()
	return _paste_mutations > 0 or _paste_native_pending or (_paste_restore_after ~= nil
		and TimerScheduler.awake_time() < _paste_restore_after)
end

--- Verifies retained native identity; a new owner keeps its current clipboard.
local function reconcile_clipboard_owner()
	if not _paste_owns_clipboard then return true end
	local ok, count, detail = pcall(Clipboard._change_count)
	if not ok or count == nil then return false, detail or "native clipboard ownership cannot be read" end
	if _paste_owned_count == nil then
		-- A later read cannot retroactively prove an unobserved native mutation.
		-- Wait for another observed owner change instead of adopting this count.
		if _paste_unproven_count == nil or count == _paste_unproven_count then
			_paste_unproven_count = count
			return false, "native clipboard ownership was not captured"
		end
	end
	if count ~= _paste_owned_count then
		_paste_mutations = _paste_mutations + 1
		local released, release_error = pcall(function()
			release_clipboard()
			Logger.info(LOG, "Clipboard changed owner; preserving the newer clipboard without restoration.")
		end)
		_paste_mutations = _paste_mutations - 1
		if not released then return false, release_error end
	end
	return true
end

local function restore_clipboard()
	if not _paste_owns_clipboard then return true end
	if paste_settling() then return false, "native paste is still settling", true end
	local current, ownership_error = reconcile_clipboard_owner()
	if not current then return false, ownership_error end
	if not _paste_owns_clipboard then return true end
	local generation = _paste_generation
	local receipt = { expected_count = _paste_owned_count }
	_paste_mutations = _paste_mutations + 1
	local ok_restore, restored = pcall(Clipboard.restore, _paste_saved_original, receipt)
	_paste_mutations = _paste_mutations - 1
	if generation ~= _paste_generation or not _paste_owns_clipboard then return true end
	if not ok_restore or restored ~= true then
		if receipt.attempted ~= false then
			_paste_owned_count = receipt.count_ok == true and receipt.count or nil
			_paste_unproven_count = nil
		end
		local reconciled, count_error = reconcile_clipboard_owner()
		if reconciled and not _paste_owns_clipboard then return true end
		return false, count_error or (ok_restore and "Clipboard.restore returned " .. tostring(restored) or restored)
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
			local restored, restore_error, waiting = restore_clipboard()
			if restored then return end
			if not waiting then
				_paste_recovery_only = true
				Logger.error(LOG, "Clipboard restore refused; ownership retained — %s", tostring(restore_error))
			end
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
	-- A zero-delay fallback cannot replace the host's remaining paste interval.
	-- Keep the exact snapshot until the terminal callback or a later send retries.
	if paste_settling() then
		Logger.error(LOG, "Clipboard paste settlement timer could not be armed — %s", tostring(timer_error))
		return false
	end
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
	local producer
	local completion_owned = false
	local terminal_received = false
	if mode == "clipboard" then
		ok, err = pcall(function()
			assert(not paste_settling(), "previous native clipboard paste is still settling")
			if _paste_recovery_only then
				local restored, restore_error = restore_clipboard()
				if not restored then
					queue_restore_retry()
					error("previous clipboard recovery remains pending: " .. tostring(restore_error), 0)
				end
			end
			local current, ownership_error = reconcile_clipboard_owner()
			assert(current, ownership_error)
			-- If a restore is still pending after the previous paste's grace, cancel it
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
				assert(retry_restore_timer_cleanup() == true, "prior clipboard timer cleanup remains pending")
				_paste_mutations = _paste_mutations + 1
				local captured, snapshot, count = pcall(function()
					local before, count_error = Clipboard._change_count()
					assert(before ~= nil, count_error)
					local saved, snapshot_ok = Clipboard.save()
					assert(snapshot_ok == true, "clipboard snapshot failed")
					local after = Clipboard._change_count()
					assert(after == before, "clipboard changed during snapshot capture")
					return saved, after
				end)
				_paste_mutations = _paste_mutations - 1
				assert(captured, snapshot)
				_paste_saved_original, _paste_owned_count = snapshot, count
			end

			_paste_generation = _paste_generation + 1
			_paste_owns_clipboard = true
			_paste_recovery_only = true
			local receipt = { expected_count = _paste_owned_count }
			local write_generation = _paste_generation
			_paste_mutations = _paste_mutations + 1
			local ok_write, written = pcall(function()
				local accepted = Clipboard.write(text, receipt)
				if receipt.attempted ~= false then
					_paste_owned_count = receipt.count_ok == true and receipt.count or nil
				end
				assert(accepted == true and receipt.attempted == true and receipt.count_ok == true,
					"clipboard payload ownership was not acknowledged")
				local current, count_error = reconcile_clipboard_owner()
				assert(current and _paste_owns_clipboard, count_error or "clipboard ownership changed after writing")
			end)
			_paste_mutations = _paste_mutations - 1
			if not ok_write then
				if write_generation == _paste_generation and _paste_owns_clipboard
					and receipt.attempted ~= false then
					_paste_owned_count = receipt.count_ok == true and receipt.count or nil
				end
				error("clipboard payload refused: " .. tostring(written), 0)
			end

			local restore_armed, timer_error = schedule_restore()
			if not restore_armed then
				error("clipboard restore timer refused: " .. tostring(timer_error), 0)
			end

			_paste_recovery_only = false
			local generation, owned_count = _paste_generation, _paste_owned_count
			local function cached()
				return _paste_generation == generation and _paste_owns_clipboard
					and _paste_transaction == producer and _paste_owned_count == owned_count
			end
			producer = SyntheticInput.begin("text_sender.clipboard", "action", {
				cached = cached,
				current = function()
					if not cached() then return false end
					local count = Clipboard._change_count()
					return count ~= nil and count == owned_count and cached()
				end,
			})
			_paste_transaction = producer
			_paste_native_pending = true
			local dispatched = false
			SyntheticInput.on_dispatched(producer, function(_, batch, status)
				-- A native Down that raised may still have pasted. Failed terminal
				-- status remains honest while its recipient retains conservative grace.
				if status == "dispatched" or batch.native_down_attempted == true then dispatched = true end
			end)
			SyntheticInput.on_complete(producer, function(_, status)
				if _paste_transaction ~= producer or generation ~= _paste_generation then return end
				terminal_received = true
				_paste_transaction = nil
				_paste_native_pending = false
				if dispatched or status == "complete" then
					_paste_restore_after = TimerScheduler.awake_time() + CLIPBOARD_RESTORE_DELAY_S
					queue_restore_retry()
				else
					local restored, restore_error = restore_clipboard()
					if not restored then
						_paste_recovery_only = true
						Logger.error(LOG, "Cancelled clipboard paste restore refused — %s", tostring(restore_error))
						queue_restore_retry()
					end
				end
			end)
			completion_owned = true
			local ok_emit, emitted = pcall(
				SyntheticInput.emit_guarded_key_stroke, PASTE_MODIFIER, PASTE_KEY, producer)
			if not ok_emit or emitted ~= true then
				error("synthetic paste keystroke refused: " .. tostring(emitted), 0)
			end
			assert(SyntheticInput.seal(producer) == true, "synthetic paste seal refused")
		end)
		if not ok then
			if producer ~= nil then
				local cancelled, cancel_error = pcall(SyntheticInput.cancel, producer)
				if not cancelled then
					Logger.error(LOG, "Clipboard paste cancellation failed — %s", tostring(cancel_error))
				end
				-- Before callback registration, no native batch has been emitted.
				if not completion_owned then
					_paste_transaction = nil
					_paste_native_pending = false
				end
			end
			-- A synchronous terminal callback already owns its one rollback/retry.
			if not terminal_received then
				local restored, restore_error, waiting = restore_clipboard()
				if not restored then
					if not waiting then
						_paste_recovery_only = true
						Logger.error(LOG, "Clipboard paste rollback refused — %s", tostring(restore_error))
					end
					queue_restore_retry()
				end
			end
		end
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
		Logger.callback(LOG, "Text sender completion", callback)
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
