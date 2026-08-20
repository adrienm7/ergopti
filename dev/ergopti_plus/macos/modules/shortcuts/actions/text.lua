--- modules/shortcuts/actions/text.lua

--- ==============================================================================
--- MODULE: Shortcuts — Text Actions
--- DESCRIPTION:
--- Implements all text-manipulation shortcuts: word and line selection, case
--- transformation (title case, uppercase toggle), plain-text paste, and line
--- wrapping.
---
--- FEATURES & RATIONALE:
--- 1. Async Clipboard Engine: copy → transform → paste → re-select → restore
---    clipboard never leaves the pasteboard permanently modified.
--- 2. Toggle Logic: case transforms alternate between two states on repeated
---    invocations so the user never needs to undo manually.
--- ==============================================================================

local M = {}

local hs         = hs
local timer      = hs.timer
local pasteboard = hs.pasteboard
local Logger     = require("infra.logger")
local Paths      = require("infra.paths")
local Timings    = require("infra.timings")
local SyntheticInput = require("adapters.synthetic_input")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "shortcuts.actions.text"

-- Explicit inter-key delay for simulated keystrokes. hs.eventtap.keyStroke()
-- defaults this argument to 200 000 us and implements it as a BLOCKING usleep on
-- the main run loop, so an omitted delay stalls the loop that services the typing
-- event tap — long enough for macOS to disable it (kCGEventTapDisabledByTimeout).
local KEYSTROKE_NO_DELAY_US = 0

-- Exact owner for the delayed second half of surround_with_parens(). A failed
-- activation can retain a native timer even when the adapter reports no commit;
-- keep that capability until cancellation settles and fence its callback by a
-- generation before allowing a successor action.
local _surround_timer = nil
local _surround_generation = 0





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

-- Clipboard settle delays come from the shared cross-driver registry
-- (_shared/modules/timings/constants.toml [debounce]) so AHK and macOS stay in sync.
local COPY_SETTLE_SEC    = Timings.sec("debounce", "clipboard_copy_settle_ms")  -- Wait after Cmd+C for clipboard to fill
local PASTE_SETTLE_SEC   = Timings.sec("debounce", "clipboard_paste_settle_ms") -- Wait before pasting the transformed text
local RESELECT_DELAY_SEC = Timings.sec("debounce", "clipboard_reselect_ms")     -- Wait after paste before re-selecting
local RESTORE_DELAY_SEC  = Timings.sec("debounce", "clipboard_restore_ms")      -- Wait after re-select before restoring clipboard
local MAX_RESELECT_CHARS = 5000   -- Safety cap: avoid freezing on huge pastes

-- Symbols that should wrap the selection rather than replace it.
-- The canonical catalogue AND its grouping live in the SHARED single source of
-- truth: ``static/ergopti_plus/_shared/wrap_symbols.json`` (the same file the AHK
-- driver reads). It is loaded once below — NEVER hardcode the list or its order
-- here. WRAP_GROUPS preserves the ordered groups (each {i18n=<label key>, pairs=…};
-- the menu renders each as a named nested sub-submenu); WRAP_PAIRS is the
-- flattened {[char]={left,right}} lookup with both the opening and closing char
-- of each pair registered as keys.

-- Emergency-only fallback used when the shared JSON cannot be read/parsed. Kept
-- intentionally minimal (ASCII brackets + straight quotes) so a transient I/O
-- failure still leaves basic wrapping usable; the real catalogue is the JSON.
local FALLBACK_GROUPS = {
	{ i18n = "menu.shortcuts.wrap_group_brackets", pairs = {
		{ left = "(", right = ")" }, { left = "[", right = "]" },
		{ left = "{", right = "}" }, { left = "<", right = ">" } } },
	{ i18n = "menu.shortcuts.wrap_group_quotes", pairs = {
		{ left = '"', right = '"' }, { left = "'", right = "'" } } },
}

--- Reads the shared catalogue and returns its ordered groups, or nil on failure.
--- The path is resolved through the single shared-tree resolver (Paths.shared),
--- which performs the dual-root upward walk — robust to packaged .app builds and
--- symlinked ~/.hammerspoon setups alike.
--- @return table|nil Array of groups (each {i18n=<label key>, pairs={{left,right},…}}).
local function load_shared_groups()
	local path = Paths.shared("modules/wrap_symbols/wrap_symbols.json")
	if type(path) ~= "string" or path == "" then return nil end
	local fh = io.open(path, "r")
	if not fh then return nil end
	local content = fh:read("*a")
	fh:close()
	if type(content) == "string" and content ~= "" then
		-- Strip a leading UTF-8 BOM — hs.json.decode rejects it.
		if content:sub(1, 3) == "\239\187\191" then content = content:sub(4) end
		local ok, data = pcall(hs.json.decode, content)
		if ok and type(data) == "table" and type(data.groups) == "table" and #data.groups > 0 then
			return data.groups
		end
	end
	return nil
end

-- Normalize a raw groups array to the canonical {i18n, pairs} shape. Tolerates
-- the older bare-array-of-pairs shape so a shape mismatch (e.g. a stale on-disk
-- catalogue) can never silently empty the lookup and stop ALL wrapping.
local function normalize_groups(raw)
	local out = {}
	for _, g in ipairs(raw or {}) do
		if type(g) == "table" then
			if type(g.pairs) == "table" then
				out[#out + 1] = { i18n = g.i18n, pairs = g.pairs }
			elseif type(g[1]) == "table" then
				-- Bare array of {left,right} pairs (legacy / hand-edited shape).
				out[#out + 1] = { i18n = nil, pairs = g }
			end
		end
	end
	return out
end

-- Build WRAP_GROUPS (ordered, each {i18n, pairs}) and WRAP_PAIRS (flattened
-- lookup) from the shared catalogue, falling back to the minimal emergency set
-- on any failure.
local WRAP_GROUPS = normalize_groups(load_shared_groups())
if #WRAP_GROUPS == 0 then
	Logger.warn(LOG, "Shared wrap-symbols catalogue unreadable — using emergency fallback.")
	WRAP_GROUPS = FALLBACK_GROUPS
end

local WRAP_PAIRS = {}
for _, group in ipairs(WRAP_GROUPS) do
	for _, pair in ipairs(group.pairs or {}) do
		if type(pair) == "table" and type(pair.left) == "string" and pair.left ~= ""
				and type(pair.right) == "string" and pair.right ~= "" then
			WRAP_PAIRS[pair.left] = { left = pair.left, right = pair.right }
			if pair.right ~= pair.left then
				WRAP_PAIRS[pair.right] = { left = pair.left, right = pair.right }
			end
		end
	end
end

-- Surface the catalogue size at load. An empty catalogue (a path/parse failure)
-- would silently break ALL wrapping, so it is logged loudly as an ERROR; the
-- healthy case is a one-shot INFO that confirms the source the catalogue came
-- from. Kept permanently — cheap (fires once) and invaluable when wrapping
-- mysteriously stops in a given deployment.
do
	local key_count = 0
	for _ in pairs(WRAP_PAIRS) do key_count = key_count + 1 end
	if key_count == 0 then
		Logger.error(LOG, "Wrap catalogue is EMPTY — selection wrapping is disabled. Catalogue path/parse failed.")
	else
		Logger.info(LOG, "Wrap catalogue ready: %d group(s), %d lookup key(s).", #WRAP_GROUPS, key_count)
	end
end





-- ==========================================
-- ==========================================
-- ======= 2/ Internal String Helpers =======
-- ==========================================
-- ==========================================

--- Trims leading and trailing whitespace from a string.
--- @param s string The input string.
--- @return string The trimmed string.
local function trim(s)
	if type(s) ~= "string" then return "" end
	return (s:gsub("^%s*(.-)%s*$", "%1"))
end

--- Converts a string to Title Case.
--- @param s string The input string.
--- @return string The Title Case string.
local function titlecase(s)
	if type(s) ~= "string" then return "" end
	return (s:lower():gsub("(%S+)", function(w)
		return w:sub(1, 1):upper() .. w:sub(2)
	end))
end

--- Asynchronous text-transform engine.
--- Copies the current selection, applies the callback, pastes the result, then
--- re-selects the pasted text so repeated transforms work without re-selecting,
--- and finally restores the original clipboard content.
--- @param transform_func function Receives the selected text; returns the transformed string.
-- The transform pipeline owns the clipboard for roughly half a second (copy →
-- transform → paste → re-select → restore). A second press inside that window
-- snapshots a clipboard the first run had already overwritten with its own
-- intermediate value, and then "restores" that instead of the user's real
-- clipboard — silently destroying it. Guarded with the in-flight-flag pattern
-- already used by infra/ui_restore and api_mlx, including their hard timeout: a
-- flag that could stick would block every later transform for the session.
local _transform_in_flight = false
local _plain_paste_in_flight = false
local _plain_paste_generation = 0
-- Same guard for the wrap path, declared beside its sibling so the pair stays visible.
local _wrap_in_flight      = false
-- The restore timer is retained explicitly. A one-shot native timer that is only
-- referenced by a local in wrap_selection may be collected before it restores the
-- user's clipboard, and a late callback from an older wrap must never release the
-- ownership bit of a newer one.
local _wrap_restore_timer  = nil
local _wrap_generation     = 0
local TRANSFORM_LOCK_TIMEOUT_SEC = 2.0

-- Identity of the transform that currently owns the clipboard. The failsafe
-- below fires on a fixed delay, so without this it released whichever transform
-- was in flight when it happened to expire — including a newer one that had
-- barely started.
local _transform_generation = 0

--- Re-selects the preceding characters as one ordered synthetic action.
--- Building one batch avoids one broker trigger/action epoch per cursor key.
--- Preserve the original Left then Shift+Right sequence: besides selecting the
--- same text, it leaves the active end of the selection on the right so a
--- repeated transform replaces the same range in the same direction.
--- @param count integer Number of preceding characters to select.
--- @return boolean dispatched
local function reselect_previous_text(count)
	if type(count) ~= "number" or count < 1 then return true end
	local tx = nil
	local ok, err = xpcall(function()
		tx = SyntheticInput.begin("shortcuts.text.reselect", "action")
		local batch = SyntheticInput.begin_batch(tx)
		for _ = 1, count do
			SyntheticInput.keyStroke(batch, {}, "left")
		end
		for _ = 1, count do
			SyntheticInput.keyStroke(batch, { "shift" }, "right")
		end
		assert(SyntheticInput.dispatch(batch),
			"synthetic reselection batch could not be dispatched")
		SyntheticInput.seal(tx)
	end, debug.traceback)
	if ok then return true end
	if tx then pcall(SyntheticInput.cancel, tx) end
	Logger.error(LOG, "Text reselection could not be dispatched - %s.", tostring(err))
	return false
end

local function do_transform(transform_func)
	if _transform_in_flight then
		Logger.debug(LOG, "Text transform ignored — a previous one still owns the clipboard.")
		return false
	end
	_transform_in_flight = true
	_transform_generation = _transform_generation + 1
	local my_generation = _transform_generation
	local active = true
	local owns_clipboard = false
	local timers = {}
	local next_timer_id = 0
	local restore_retry_armed = false
	local deferred_retry_armed = false

	local function stop_all_timers()
		for id, handle in pairs(timers) do
			if handle and type(handle.stop) == "function" then pcall(handle.stop, handle) end
			timers[id] = nil
		end
	end

	local function release()
		if not active or my_generation ~= _transform_generation then return end
		active = false
		stop_all_timers()
		_transform_in_flight = false
		_transform_generation = _transform_generation + 1
	end

	Logger.trace(LOG, "Text transformation started…")
	local ok_snapshot, prior = pcall(pasteboard.readAllData)
	if not ok_snapshot or type(prior) ~= "table" then
		release()
		Logger.error(LOG, "Text transform clipboard snapshot failed: %s.", tostring(prior))
		return false
	end
	owns_clipboard = true

	local restore_prior
	local queue_restore_retry
	local abort_transform

	restore_prior = function()
		if not owns_clipboard then return true end
		local ok_restore, restore_result
		if next(prior) ~= nil then
			ok_restore, restore_result = pcall(pasteboard.writeAllData, prior)
			ok_restore = ok_restore and restore_result == true
		else
			ok_restore, restore_result = pcall(pasteboard.clearContents)
		end
		if ok_restore then
			owns_clipboard = false
			return true, nil
		end
		return false, restore_result
	end

	local function schedule_transform_timer(delay, label, callback)
		next_timer_id = next_timer_id + 1
		local id = next_timer_id
		local handle = nil
		local installing = true
		local callback_ran = false
		local ok_timer, timer_or_error = pcall(timer.doAfter, delay, function()
			callback_ran = true
			if installing then return end
			timers[id] = nil
			if not active or my_generation ~= _transform_generation then return end
			local ok_callback, callback_error = xpcall(callback, debug.traceback)
			if not ok_callback then
				Logger.error(LOG, "Text transform %s callback failed: %s.",
					label, tostring(callback_error))
				if abort_transform then abort_transform(label .. " callback", callback_error) end
			end
		end)
		installing = false
		if not ok_timer or timer_or_error == nil or timer_or_error == false or callback_ran then
			if timer_or_error and type(timer_or_error.stop) == "function" then
				pcall(timer_or_error.stop, timer_or_error)
			end
			return false, ok_timer and (callback_ran and "timer fired during installation"
				or "hs.timer.doAfter returned no handle") or timer_or_error
		end
		handle = timer_or_error
		timers[id] = handle
		return true, nil
	end

	queue_restore_retry = function()
		if restore_retry_armed or deferred_retry_armed or not owns_clipboard then return true end
		local function attempt_restore()
			restore_retry_armed = false
			deferred_retry_armed = false
			local restored, restore_error = restore_prior()
			if restored then
				release()
				Logger.done(LOG, "Text transformation completed after clipboard retry.")
				return
			end
			Logger.error(LOG, "Text transform clipboard restore retry refused: %s.",
				tostring(restore_error))
			queue_restore_retry()
		end
		local armed, timer_error = schedule_transform_timer(
			RESTORE_DELAY_SEC, "clipboard restore retry", attempt_restore)
		if armed then
			restore_retry_armed = true
			return true
		end
		if type(SyntheticInput.defer_after_callback) == "function" then
			local installing = true
			local callback_ran = false
			local ok_defer, deferred = pcall(SyntheticInput.defer_after_callback,
				"text transform clipboard restore recovery", function()
					callback_ran = true
					if installing then return end
					local ok_callback, callback_error = xpcall(attempt_restore, debug.traceback)
					if not ok_callback then
						Logger.error(LOG, "Text transform deferred restore callback failed: %s.",
							tostring(callback_error))
					end
				end)
			installing = false
			if ok_defer and deferred == true and not callback_ran then
				deferred_retry_armed = true
				return true
			end
		end
		Logger.error(LOG, "Text transform clipboard restore retry could not be armed: %s.",
			tostring(timer_error))
		return false
	end

	abort_transform = function(reason, detail)
		if not active or my_generation ~= _transform_generation then return false end
		local restored, restore_error = restore_prior()
		if restored then release() else queue_restore_retry() end
		Logger.error(LOG, "Text transform aborted at %s: %s (restore=%s).",
			reason, tostring(detail), tostring(restore_error))
		return false
	end

	local copy_stage
	copy_stage = function()
		local ok_selection, selection = pcall(pasteboard.getContents)
		if not ok_selection or type(selection) ~= "string" or selection == "" then
			abort_transform("selection copy", selection)
			return
		end
		local ok_transform, transformed = pcall(transform_func, selection)
		if not ok_transform or type(transformed) ~= "string" then
			abort_transform("transform callback", transformed)
			return
		end

		local paste_stage
		paste_stage = function()
			local reselect_stage
			reselect_stage = function()
				local restore_armed, restore_timer_error = schedule_transform_timer(
					RESTORE_DELAY_SEC, "clipboard restore", function()
						local restored, restore_error = restore_prior()
						if restored then
							release()
							Logger.done(LOG, "Text transformation completed.")
						else
							Logger.error(LOG, "Text transform clipboard restore refused: %s.",
								tostring(restore_error))
							queue_restore_retry()
						end
					end)
				if not restore_armed then
					abort_transform("restore timer", restore_timer_error)
					return
				end
				local len_ok, ulen = pcall(utf8.len, transformed)
				local count = (len_ok and ulen and ulen > 0) and ulen or #transformed
				if count > MAX_RESELECT_CHARS then count = MAX_RESELECT_CHARS end
				if count > 0 and not reselect_previous_text(count) then
					abort_transform("text reselection", "synthetic dispatch refused")
				end
			end
			local reselect_armed, reselect_timer_error = schedule_transform_timer(
				RESELECT_DELAY_SEC, "reselection", reselect_stage)
			if not reselect_armed then
				abort_transform("reselection timer", reselect_timer_error)
				return
			end
			local ok_paste, pasted = pcall(
				SyntheticInput.emit_key_stroke, { "cmd" }, "v", 0.02)
			if not ok_paste or pasted ~= true then
				abort_transform("paste shortcut", pasted)
			end
		end

		local paste_armed, paste_timer_error = schedule_transform_timer(
			PASTE_SETTLE_SEC, "paste", paste_stage)
		if not paste_armed then
			abort_transform("paste timer", paste_timer_error)
			return
		end
		local ok_write, write_result = pcall(pasteboard.setContents, transformed)
		if not ok_write or write_result ~= true then
			abort_transform("clipboard write", write_result)
		end
	end

	local failsafe_armed, failsafe_error = schedule_transform_timer(
		TRANSFORM_LOCK_TIMEOUT_SEC, "ownership failsafe", function()
			abort_transform("ownership timeout", "pipeline did not complete")
		end)
	if not failsafe_armed then
		release()
		Logger.error(LOG, "Text transform failsafe timer was refused: %s.", tostring(failsafe_error))
		return false
	end
	local copy_armed, copy_timer_error = schedule_transform_timer(
		COPY_SETTLE_SEC, "selection copy", copy_stage)
	if not copy_armed then
		abort_transform("copy timer", copy_timer_error)
		return false
	end

	local ok_clear, clear_error = pcall(pasteboard.clearContents)
	if not ok_clear then
		abort_transform("clipboard clear", clear_error)
		return false
	end
	local ok_copy, copied = pcall(
		SyntheticInput.emit_key_stroke, { "cmd" }, "c", KEYSTROKE_NO_DELAY_US)
	if not ok_copy or copied ~= true then
		abort_transform("copy shortcut", copied)
		return false
	end
	return true
end





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- Pastes the current clipboard content stripped of any rich-text formatting.
function M.paste_as_plain_text()
	if _plain_paste_in_flight then
		Logger.debug(LOG, "Plain-text paste ignored — a previous action still owns the clipboard.")
		return false
	end
	local ok_snapshot, prior = pcall(pasteboard.readAllData)
	local ok_plain, plain = pcall(pasteboard.getContents)
	if not ok_snapshot or type(prior) ~= "table" or not ok_plain then
		Logger.error(LOG, "Plain-text paste clipboard snapshot failed.")
		return false
	end
	_plain_paste_in_flight = true
	_plain_paste_generation = _plain_paste_generation + 1
	local generation = _plain_paste_generation
	local owns_clipboard = true
	local active = true
	local timers = {}
	local next_timer_id = 0
	local retry_armed = false
	local deferred_retry_armed = false
	local restore_prior
	local queue_restore_retry
	local abort_plain_paste

	local function stop_all_timers()
		for id, handle in pairs(timers) do
			if handle and type(handle.stop) == "function" then pcall(handle.stop, handle) end
			timers[id] = nil
		end
	end

	local function release()
		if not active or generation ~= _plain_paste_generation then return end
		active = false
		stop_all_timers()
		_plain_paste_in_flight = false
		owns_clipboard = false
		_plain_paste_generation = _plain_paste_generation + 1
	end

	restore_prior = function()
		if not owns_clipboard then return true end
		local ok_restore, restore_result
		if next(prior) ~= nil then
			ok_restore, restore_result = pcall(pasteboard.writeAllData, prior)
			ok_restore = ok_restore and restore_result == true
		else
			ok_restore, restore_result = pcall(pasteboard.clearContents)
		end
		if ok_restore then owns_clipboard = false; return true, nil end
		return false, restore_result
	end

	local function schedule_plain_timer(delay, label, callback)
		next_timer_id = next_timer_id + 1
		local id = next_timer_id
		local handle = nil
		local installing = true
		local callback_ran = false
		local ok_timer, timer_or_error = pcall(timer.doAfter, delay, function()
			callback_ran = true
			if installing then return end
			timers[id] = nil
			if not active or generation ~= _plain_paste_generation then return end
			local ok_callback, callback_error = xpcall(callback, debug.traceback)
			if not ok_callback then
				Logger.error(LOG, "Plain-text paste %s callback failed: %s.",
					label, tostring(callback_error))
				if abort_plain_paste then abort_plain_paste(label .. " callback", callback_error) end
			end
		end)
		installing = false
		if not ok_timer or timer_or_error == nil or timer_or_error == false or callback_ran then
			if timer_or_error and type(timer_or_error.stop) == "function" then
				pcall(timer_or_error.stop, timer_or_error)
			end
			return false, ok_timer and (callback_ran and "timer fired during installation"
				or "hs.timer.doAfter returned no handle") or timer_or_error
		end
		handle = timer_or_error
		timers[id] = handle
		return true, nil
	end

	queue_restore_retry = function()
		if retry_armed or deferred_retry_armed or not owns_clipboard then return true end
		local function attempt_restore()
			retry_armed = false
			deferred_retry_armed = false
			local restored, restore_error = restore_prior()
			if restored then release(); return end
			Logger.error(LOG, "Plain-text paste clipboard restore retry refused: %s.",
				tostring(restore_error))
			queue_restore_retry()
		end
		local armed, timer_error = schedule_plain_timer(
			RESTORE_DELAY_SEC, "clipboard restore retry", attempt_restore)
		if armed then retry_armed = true; return true end
		if type(SyntheticInput.defer_after_callback) == "function" then
			local installing = true
			local callback_ran = false
			local ok_defer, deferred = pcall(SyntheticInput.defer_after_callback,
				"plain-text paste clipboard restore recovery", function()
					callback_ran = true
					if installing then return end
					local ok_callback, callback_error = xpcall(attempt_restore, debug.traceback)
					if not ok_callback then
						Logger.error(LOG, "Plain-text paste deferred restore callback failed: %s.",
							tostring(callback_error))
					end
				end)
			installing = false
			if ok_defer and deferred == true and not callback_ran then
				deferred_retry_armed = true
				return true
			end
		end
		Logger.error(LOG, "Plain-text paste clipboard restore retry could not be armed: %s.",
			tostring(timer_error))
		return false
	end

	abort_plain_paste = function(reason, detail)
		if not active or generation ~= _plain_paste_generation then return false end
		local restored, restore_error = restore_prior()
		if restored then release() else queue_restore_retry() end
		Logger.error(LOG, "Plain-text paste aborted at %s: %s (restore=%s).",
			reason, tostring(detail), tostring(restore_error))
		return false
	end

	local paste_armed, paste_timer_error = schedule_plain_timer(
		PASTE_SETTLE_SEC, "paste", function()
			local restore_armed, restore_timer_error = schedule_plain_timer(
				RESTORE_DELAY_SEC, "clipboard restore", function()
					local restored, restore_error = restore_prior()
					if restored then release()
					else
						Logger.error(LOG, "Plain-text paste clipboard restore refused: %s.",
							tostring(restore_error))
						queue_restore_retry()
					end
				end)
			if not restore_armed then
				abort_plain_paste("restore timer", restore_timer_error)
				return
			end
			local ok_emit, emitted = pcall(
				SyntheticInput.emit_key_stroke, { "cmd" }, "v", 0.02)
			if not ok_emit or emitted ~= true then
				abort_plain_paste("paste shortcut", emitted)
			end
		end)
	if not paste_armed then
		release()
		Logger.error(LOG, "Plain-text paste timer was refused: %s.", tostring(paste_timer_error))
		return false
	end

	local ok_write, write_result = pcall(pasteboard.setContents, plain or "")
	if not ok_write or write_result ~= true then
		abort_plain_paste("clipboard write", write_result)
		return false
	end
	return true
end

--- Selects the entire current line (Cmd+Left, then Cmd+Shift+Right).
function M.select_line()
	SyntheticInput.emit_key_stroke({"cmd"}, "left", KEYSTROKE_NO_DELAY_US)
	SyntheticInput.emit_key_stroke({"cmd", "shift"}, "right", KEYSTROKE_NO_DELAY_US)
end

--- Wraps the current line in parentheses.
function M.surround_with_parens()
	local prior = _surround_timer
	if prior then
		if prior.committed == true then return false end
		if TimerScheduler.cancel(prior) ~= true then
			Logger.error(LOG, "Parenthesis surround timer cleanup remains pending.")
			return false
		end
		if _surround_timer == prior then _surround_timer = nil end
	end

	_surround_generation = _surround_generation + 1
	local generation = _surround_generation
	local closing_timer
	local committed
	closing_timer, committed = TimerScheduler.after(0.04, function()
		if generation ~= _surround_generation or _surround_timer ~= closing_timer then return end
		if closing_timer.timer == nil then _surround_timer = nil end
		local ok, emitted_or_err = xpcall(function()
			assert(SyntheticInput.emit_key_stroke(
				{"cmd"}, "right", KEYSTROKE_NO_DELAY_US) == true,
				"closing cursor movement was refused")
			assert(SyntheticInput.emit_key_strokes(")") == true,
				"closing parenthesis was refused")
		end, debug.traceback)
		if not ok then
			Logger.error(LOG, "Parenthesis surround completion failed: %s.",
				tostring(emitted_or_err))
		end
	end)
	if closing_timer and closing_timer.timer ~= nil then _surround_timer = closing_timer end
	if committed ~= true then
		if not closing_timer or closing_timer.timer == nil then _surround_timer = nil end
		Logger.error(LOG, "Parenthesis surround timer was refused before text mutation.")
		return false
	end
	_surround_timer = closing_timer

	local ok, emitted_or_err = xpcall(function()
		assert(SyntheticInput.emit_key_stroke(
			{"cmd"}, "left", KEYSTROKE_NO_DELAY_US) == true,
			"opening cursor movement was refused")
		assert(SyntheticInput.emit_key_strokes("(") == true,
			"opening parenthesis was refused")
	end, debug.traceback)
	if not ok then
		_surround_generation = _surround_generation + 1
		TimerScheduler.cancel(closing_timer)
		Logger.error(LOG, "Parenthesis surround opening failed: %s.", tostring(emitted_or_err))
		return false
	end
	return true
end

--- Toggles the current selection between Title Case and lowercase.
function M.toggle_titlecase()
	do_transform(function(sel)
		local t = titlecase(sel)
		-- If already title-cased, drop to lowercase; otherwise apply title case
		return (sel == t) and sel:lower() or t
	end)
end

--- Toggles the current selection between UPPERCASE and lowercase.
function M.toggle_uppercase()
	do_transform(function(sel)
		-- Promote if any lowercase exists; demote otherwise
		return sel:match("%l") and sel:upper() or sel:lower()
	end)
end

--- Selects the current word under the cursor (Alt+Right, then Alt+Shift+Left).
function M.select_word()
	SyntheticInput.emit_key_stroke({"alt"}, "right", KEYSTROKE_NO_DELAY_US)
	SyntheticInput.emit_key_stroke({"alt", "shift"}, "left", KEYSTROKE_NO_DELAY_US)
end

--- Returns the AXSelectedText of the focused UI element, or nil if unavailable.
--- Uses the Accessibility API so no clipboard manipulation is needed. Returns nil
--- BOTH when nothing is selected AND when the focused app does not expose
--- AXSelectedText (notably Electron apps such as VS Code). Callers MUST treat nil
--- as "cannot wrap" and let the raw symbol type through, never swallow it.
--- @return string|nil The selected text, or nil when unavailable.
function M.read_ax_selection()
	local ok_ax, ax = pcall(require, "hs.axuielement")
	if not ok_ax or not ax then return nil end

	local ok_el, el = pcall(function() return ax.systemWideElement():attributeValue("AXFocusedUIElement") end)
	if not ok_el or not el then return nil end

	local ok_sel, sel = pcall(function() return el:attributeValue("AXSelectedText") end)
	if not ok_sel then return nil end
	return (type(sel) == "string" and sel ~= "") and sel or nil
end

--- The full built-in WRAP_PAIRS catalogue exposed for external inspection.
--- Callers that need a filtered or user-extended table should use build_active_wrap_pairs().
M.WRAP_PAIRS = WRAP_PAIRS

--- The ordered built-in groups from the shared catalogue. Each entry is
--- {i18n=<label key>, pairs={{left,right},…}}; the menu renders each group as a
--- named nested sub-submenu. Exposed so the menu mirrors the shared grouping and
--- labels without duplicating the order or the catalogue.
M.WRAP_GROUPS = WRAP_GROUPS

--- Builds the active wrapping-pairs table from the built-in catalogue and user state.
--- @param symbol_states table Map of symbol key → boolean (true = enabled).
---   The key is the opening character, e.g. "(" or the asymmetric "« ".
--- @param custom_symbols table Array of {key, left, right} for user-added pairs.
--- @return table {[char]={left,right}} ready for the eventtap filter.
function M.build_active_wrap_pairs(symbol_states, custom_symbols)
	local result = {}
	for char, pair in pairs(WRAP_PAIRS) do
		-- Use the opening symbol as the canonical key for state lookup
		local state_key = pair.left
		local enabled = (type(symbol_states) ~= "table") or (symbol_states[state_key] ~= false)
		if enabled then
			result[char] = pair
		end
	end
	if type(custom_symbols) == "table" then
		for _, cs in ipairs(custom_symbols) do
			if type(cs) == "table" and type(cs.left) == "string" and cs.left ~= "" then
				local right = (type(cs.right) == "string" and cs.right ~= "") and cs.right or cs.left
				-- Register under both opening and closing chars (mirrors WRAP_PAIRS pattern)
				result[cs.left]  = { left = cs.left, right = right }
				if right ~= cs.left then
					result[right] = { left = cs.left, right = right }
				end
			end
		end
	end
	return result
end

--- Defers wrap diagnostics so a pasteboard/timer failure never opens and flushes
--- the file logger from the keyDown eventtap that called wrap_selection.
--- @param level string Logger method name.
--- @param message string Format string.
--- @param ... any Format arguments.
--- @return boolean scheduled
local function defer_wrap_diagnostic(level, message, ...)
	local args = table.pack(...)
	if type(SyntheticInput.defer_after_callback) ~= "function" then return false end
	local ok, scheduled = pcall(SyntheticInput.defer_after_callback,
		"wrap selection diagnostic", function()
			local sink = Logger[level]
			if type(sink) == "function" then
				pcall(sink, LOG, message, table.unpack(args, 1, args.n))
			end
		end)
	return ok and scheduled == true
end


--- Replaces an already-read, non-empty selection with ``left .. sel .. right``
--- via one atomic clipboard transaction. True means the Cmd+V action and the
--- exact all-type clipboard restore are both armed, so the caller may consume
--- the physical wrap symbol. False means no paste was committed and the caller
--- must let that symbol pass through.
--- @param sel string The current selection text (non-empty).
--- @param left string Opening symbol to prepend.
--- @param right string Closing symbol to append.
--- @return boolean committed
function M.wrap_selection(sel, left, right)
	if _wrap_in_flight then
		defer_wrap_diagnostic("debug", "Wrap declined: another clipboard transaction is active.")
		return false
	end
	if type(sel) ~= "string" or sel == ""
		or type(left) ~= "string" or type(right) ~= "string" then
		defer_wrap_diagnostic("error", "Wrap declined: invalid selection or delimiter arguments.")
		return false
	end

	_wrap_generation = _wrap_generation + 1
	local transaction = {
		generation = _wrap_generation,
		active = true,
		committed = false,
		paste_dispatched = false,
		mutated = false,
		prior = nil,
		prior_empty = true,
		timer = nil,
	}
	_wrap_in_flight = true
	local schedule_restore
	local attempt_restore

	local function restore_prior()
		local ok, result
		if transaction.prior_empty then
			ok, result = pcall(pasteboard.clearContents)
			if not ok then return false, tostring(result) end
		else
			ok, result = pcall(pasteboard.writeAllData, transaction.prior)
			if not ok or result ~= true then return false, tostring(result) end
		end
		return true
	end

	local function release()
		transaction.active = false
		if transaction.generation == _wrap_generation then
			_wrap_in_flight = false
		end
	end

	local function detach_timer(should_stop)
		local handle = transaction.timer
		transaction.timer = nil
		if _wrap_restore_timer == handle then _wrap_restore_timer = nil end
		if should_stop and handle and type(handle.stop) == "function" then
			pcall(handle.stop, handle)
		end
	end

	local function rollback(reason, detail)
		detach_timer(true)
		local restored, restore_error = true, nil
		if transaction.mutated then
			restored, restore_error = restore_prior()
			if restored then transaction.mutated = false end
		end
		defer_wrap_diagnostic("error", "Wrap transaction aborted at %s: %s.",
			reason, tostring(detail or "operation failed"))
		if not restored then
			defer_wrap_diagnostic("error",
				"Wrap rollback could not restore the original clipboard: %s.",
				tostring(restore_error))
			-- The clipboard still belongs to this transaction. Keep the ownership
			-- latch closed and reuse the same autonomous recovery path as a failed
			-- post-paste restore; otherwise a second wrap can snapshot corrupted data.
			transaction.committed = true
			attempt_restore(true)
			return false
		end
		release()
		return false
	end

	local function finish_restore()
		transaction.mutated = false
		release()
		if transaction.paste_dispatched then
			pcall(Logger.debug, LOG, "Selection wrapped and clipboard restored.")
		end
	end

	schedule_restore = function(delay)
		local handle = nil
		local callback_ran = false
		local timer_ok, timer_or_error = pcall(timer.doAfter, delay, function()
			callback_ran = true
			if not transaction.active or not transaction.committed
				or transaction.generation ~= _wrap_generation
				or _wrap_restore_timer ~= handle then
				return
			end
			transaction.timer = nil
			_wrap_restore_timer = nil
			attempt_restore(true)
		end)
		if not timer_ok or timer_or_error == nil or timer_or_error == false then
			return false, timer_or_error
		end
		handle = timer_or_error
		if callback_ran then
			if type(handle.stop) == "function" then pcall(handle.stop, handle) end
			return false, "restore timer fired before transaction commit"
		end
		transaction.timer = handle
		_wrap_restore_timer = handle
		return true
	end

	attempt_restore = function(allow_lifecycle_fallback)
		if not transaction.active or not transaction.committed
			or transaction.generation ~= _wrap_generation then
			return false
		end
		local restored, restore_error = restore_prior()
		if restored then
			finish_restore()
			return true
		end
		defer_wrap_diagnostic("error", "Wrap clipboard restore failed: %s.",
			tostring(restore_error))
		local retry_scheduled = select(1, schedule_restore(PASTE_SETTLE_SEC))
		if retry_scheduled then return false end

		-- A native timer allocation can fail transiently. The shared lifecycle
		-- dispatcher has independent retained primary/backup handles, so use it as
		-- one last autonomous restore route without releasing clipboard ownership.
		if allow_lifecycle_fallback
			and type(SyntheticInput.defer_after_callback) == "function" then
			local defer_ok, deferred = pcall(SyntheticInput.defer_after_callback,
				"wrap clipboard restore retry", function()
					attempt_restore(false)
				end)
			if defer_ok and deferred == true then return false end
		end
		defer_wrap_diagnostic("error",
			"Wrap clipboard restore remains pending; no retry dispatcher was available.")
		return false
	end

	local snapshot_ok, prior_or_error = pcall(pasteboard.readAllData)
	if not snapshot_ok then
		return rollback("clipboard snapshot", prior_or_error)
	end
	if prior_or_error ~= nil and type(prior_or_error) ~= "table" then
		return rollback("clipboard snapshot", "readAllData returned " .. type(prior_or_error))
	end
	transaction.prior = prior_or_error
	transaction.prior_empty = prior_or_error == nil or next(prior_or_error) == nil

	-- Mark the clipboard conservatively before the call: a throwing pasteboard
	-- implementation may have changed its contents before reporting the error.
	transaction.mutated = true
	local write_ok, write_result = pcall(pasteboard.setContents, left .. sel .. right)
	if not write_ok or write_result ~= true then
		return rollback("clipboard write", write_result)
	end

	-- Arm restoration before publishing Cmd+V. If allocation fails, rolling the
	-- clipboard back and passing the user's physical symbol is still possible.
	local timer_scheduled, timer_error = schedule_restore(RESTORE_DELAY_SEC)
	if not timer_scheduled then
		return rollback("restore timer", timer_error)
	end

	local emit_ok, emitted_or_error = pcall(
		SyntheticInput.emit_key_stroke, { "cmd" }, "v", KEYSTROKE_NO_DELAY_US)
	if not emit_ok or emitted_or_error ~= true then
		return rollback("paste dispatch", emitted_or_error)
	end

	transaction.paste_dispatched = true
	transaction.committed = true
	return true
end

--- Wraps the current selection with left/right symbols, or types the symbol if
--- nothing is selected. Retained for compatibility; the eventtap path now reads
--- the selection itself (read_ax_selection) so it can pass the key through
--- untouched when no selection is available — that path never reaches here.
--- @param symbol string The raw character typed by the user.
--- @param left string Opening symbol to prepend.
--- @param right string Closing symbol to append.
function M.surround_selection_if_selected(symbol, left, right)
	local sel = M.read_ax_selection()
	if sel then
		M.wrap_selection(sel, left, right)
	else
		-- No selection — type the raw symbol so the key behaves normally
		SyntheticInput.emit_key_strokes(symbol)
	end
end

return M
