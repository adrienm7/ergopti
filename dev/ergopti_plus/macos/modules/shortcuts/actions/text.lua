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

-- The four asynchronous text paths share clipboard and document sinks, so a
-- single admission generation owns four named slots.  PAUSE closes that
-- generation before touching any native capability; a refused timer stop or
-- clipboard restore keeps its exact slot and blocks every successor.
local DEFAULT_ACTION_PARENT = "shortcut_bindings"
local _text_scopes = {}
local _next_text_timer_id = 0





-- ==============================================
-- ==============================================
-- ======= 1/ Composite Async Ownership =========
-- ==============================================
-- ==============================================

local settle_text_owner
local maybe_release_text_owner

--- Resolves one parent-scoped text lifecycle without letting a sibling feature
--- close admission or invalidate callback generations it does not own.
--- @param parent string|nil Stable action parent.
--- @return table scope
local function text_scope(parent)
	local scope_id = type(parent) == "string" and parent ~= ""
		and parent or DEFAULT_ACTION_PARENT
	local scope = _text_scopes[scope_id]
	if scope then return scope end
	scope = {
		id = scope_id,
		paused = false,
		generation = 0,
		slots = {
			transform = nil,
			plain = nil,
			wrap = nil,
			surround = nil,
		},
	}
	_text_scopes[scope_id] = scope
	return scope
end

--- Tests whether an owner may still publish user-visible work.
--- @param owner table Text owner.
--- @return boolean authorized
local function text_owner_authorized(owner)
	local scope = owner.scope
	return type(scope) == "table" and scope.paused ~= true
		and owner.business_open == true
		and owner.released ~= true
		and owner.generation == scope.generation
		and scope.slots[owner.kind] == owner
end

--- Tests whether any named text slot still owns work or cleanup debt.
--- @return boolean pending
local function text_owner_pending(scope)
	for _, owner in pairs(scope.slots) do
		if owner ~= nil then return true end
	end
	return false
end

--- Tests whether any parent currently owns the shared clipboard/document sink.
--- A sibling parent may observe the owner but must never settle or revoke it.
--- @return boolean pending
local function any_text_owner_pending()
	for _, scope in pairs(_text_scopes) do
		if text_owner_pending(scope) then return true end
	end
	return false
end

--- Removes one timer entry only after the scheduler proves native settlement.
--- A due one-shot whose native stop refused is delivered after onSettled, never
--- over the still-live repeating primitive used by Hammerspoon.
--- @param owner table Text owner.
--- @param entry table Timer entry.
--- @return boolean settled
local function drain_text_timer(owner, entry)
	if entry.delivered == true then return true end
	if owner.timers[entry.id] ~= entry then return true end
	if type(entry.handle) == "table" and entry.handle.timer ~= nil then return false end
	owner.timers[entry.id] = nil
	entry.delivered = true
	if type(owner.on_timer_settled) == "function" then
		pcall(owner.on_timer_settled, owner, entry)
	end

	local may_complete_partial = entry.completion == true
		and owner.completion_only == true
		and owner.released ~= true
		and owner.scope.slots[owner.kind] == owner
	if entry.discard ~= true and (text_owner_authorized(owner) or may_complete_partial) then
		local callback_ok, callback_error = xpcall(entry.callback, debug.traceback)
		if not callback_ok then
			owner.business_open = false
			Logger.error(LOG, "%s timer callback failed: %s.",
				tostring(entry.label), tostring(callback_error))
			settle_text_owner(owner)
		end
	end
	maybe_release_text_owner(owner)
	return true
end

--- Observes settlement of one exact scheduler handle once.
--- @param owner table Text owner.
--- @param entry table Timer entry.
local function observe_text_timer(owner, entry)
	if entry.observing == true or type(entry.handle) ~= "table" then return end
	entry.observing = true
	local observed_ok, observed = pcall(TimerScheduler.onSettled, entry.handle, function()
		-- On an ordinary due delivery, TimerScheduler settles before invoking its
		-- user callback.  Let that callback mark `due`; cancellation/debt paths are
		-- already discarded and may drain immediately from this observer.
		if entry.due == true or entry.discard == true
			or owner.business_open ~= true then
			drain_text_timer(owner, entry)
		end
	end)
	if not observed_ok or observed ~= true then
		entry.observing = false
		Logger.error(LOG, "%s timer settlement observer was refused: %s.",
			tostring(entry.label), tostring(observed))
	end
end

--- Cancels one timer without consuming false/nil/throw cleanup debt.
--- @param owner table Text owner.
--- @param entry table Timer entry.
--- @return boolean settled
local function cancel_text_timer(owner, entry)
	if owner.timers[entry.id] ~= entry then return true end
	entry.discard = true
	local cancel_ok, cancelled = pcall(TimerScheduler.cancel, entry.handle)
	if cancel_ok and cancelled == true then
		-- The real scheduler invokes onSettled synchronously before returning.
		-- Keep an explicit fallback for faithful doubles that settle without it.
		if owner.timers[entry.id] == entry then
			owner.timers[entry.id] = nil
			entry.delivered = true
			if type(owner.on_timer_settled) == "function" then
				pcall(owner.on_timer_settled, owner, entry)
			end
		end
		maybe_release_text_owner(owner)
		return true
	end
	observe_text_timer(owner, entry)
	Logger.error(LOG, "%s timer cleanup remains pending: %s.",
		tostring(entry.label), tostring(cancel_ok and cancelled or cancelled))
	return false
end

--- Cancels every exact timer currently owned by a text transaction.
--- @param owner table Text owner.
--- @return boolean settled
local function cancel_text_timers(owner)
	local snapshot = {}
	for _, entry in pairs(owner.timers) do snapshot[#snapshot + 1] = entry end
	local settled = true
	for _, entry in ipairs(snapshot) do
		if cancel_text_timer(owner, entry) ~= true then settled = false end
	end
	return settled
end

--- Schedules one exact one-shot and publishes the handle before accepting it.
--- `timer_acquisitions` makes a re-entrant PAUSE fail closed until the caller
--- receives and either commits or rolls back the native capability.
--- @param owner table Text owner.
--- @param delay number Delay in seconds.
--- @param label string Stable diagnostic label.
--- @param callback function Terminal continuation.
--- @param completion boolean|nil Allow surround closing while PAUSE is pending.
--- @return boolean committed
--- @return any detail
--- @return table|nil entry
local function schedule_text_timer(owner, delay, label, callback, completion)
	if not text_owner_authorized(owner)
		and not (completion == true and owner.completion_only == true) then
		return false, "text admission is closed", nil
	end
	_next_text_timer_id = _next_text_timer_id + 1
	local entry = {
		id = _next_text_timer_id,
		label = label,
		callback = callback,
		completion = completion == true,
		due = false,
		discard = false,
		delivered = false,
	}
	owner.timer_acquisitions = owner.timer_acquisitions + 1
	local call_ok, handle, committed = pcall(TimerScheduler.after, delay, function()
		entry.due = true
		drain_text_timer(owner, entry)
	end)
	owner.timer_acquisitions = owner.timer_acquisitions - 1
	if call_ok and type(handle) == "table" then
		entry.handle = handle
		if handle.timer ~= nil or committed == true then
			owner.timers[entry.id] = entry
			observe_text_timer(owner, entry)
		end
	end

	local still_admitted = text_owner_authorized(owner)
		or (completion == true and owner.completion_only == true
			and owner.scope.slots[owner.kind] == owner)
	if not call_ok or committed ~= true or type(handle) ~= "table"
		or handle.timer == nil or not still_admitted then
		entry.discard = true
		if owner.timers[entry.id] == entry then cancel_text_timer(owner, entry) end
		maybe_release_text_owner(owner)
		return false, call_ok and committed or handle, entry
	end
	return true, nil, entry
end

--- Restores an exact all-type snapshot. clearContents has no success return in
--- Hammerspoon; a non-throw is its complete contract.
--- @param owner table Text owner.
--- @return boolean restored
--- @return any detail
local function restore_text_clipboard(owner)
	if owner.clipboard_owned ~= true then return true, nil end
	owner.mutations = owner.mutations + 1
	local restore_ok, restore_result
	if type(owner.clipboard_prior) == "table" and next(owner.clipboard_prior) ~= nil then
		restore_ok, restore_result = pcall(pasteboard.writeAllData, owner.clipboard_prior)
		restore_ok = restore_ok and restore_result == true
	else
		restore_ok, restore_result = pcall(pasteboard.clearContents)
	end
	owner.mutations = owner.mutations - 1
	if restore_ok then
		owner.clipboard_owned = false
		return true, nil
	end
	return false, restore_result
end

--- Releases a slot only after every external capability and clipboard snapshot
--- is settled. Active business owners never disappear between pipeline stages.
--- @param owner table Text owner.
--- @return boolean released
maybe_release_text_owner = function(owner)
	if owner.released == true then return true end
	if owner.business_open == true or owner.timer_acquisitions ~= 0
		or owner.mutations ~= 0 or owner.clipboard_owned == true
		or next(owner.timers) ~= nil or owner.synthetic_pending == true then
		return false
	end
	if owner.scope.slots[owner.kind] == owner then owner.scope.slots[owner.kind] = nil end
	owner.released = true
	if type(owner.on_release) == "function" then pcall(owner.on_release, owner) end
	return true
end

--- Settles one fenced owner, retaining every refusal for an exact retry.
--- @param owner table Text owner.
--- @return boolean settled
settle_text_owner = function(owner)
	if owner == nil or owner.released == true then return true end
	owner.business_open = false
	if owner.timer_acquisitions ~= 0 or owner.mutations ~= 0 then return false end
	if type(owner.on_quiesce) == "function" then
		local hook_ok, handled, hook_result = pcall(owner.on_quiesce, owner)
		if not hook_ok then
			Logger.error(LOG, "%s quiesce hook failed: %s.",
				tostring(owner.kind), tostring(handled))
			return false
		end
		if handled == true then return hook_result == true end
	end

	local timers_settled = cancel_text_timers(owner)
	local clipboard_settled, restore_error = restore_text_clipboard(owner)
	if not clipboard_settled then
		Logger.error(LOG, "%s clipboard restore remains pending: %s.",
			tostring(owner.kind), tostring(restore_error))
	end
	local synthetic_settled = true
	if owner.synthetic_pending == true then
		local cancel_ok, cancelled = pcall(SyntheticInput.cancel, owner.synthetic_tx)
		if cancel_ok and cancelled == true
			and owner.synthetic_completion_registered ~= true then
			-- cancel() is the exact terminal boundary even when acquisition failed
			-- before on_complete could be installed.  Once a completion observer is
			-- installed, cancellation is only accepted cleanup: handed-off batches
			-- remain owned until that observer proves the transaction terminal.
			owner.synthetic_pending = false
			owner.synthetic_token = nil
		end
		-- A once-only completion callback is stronger terminal evidence than a
		-- concurrent/redundant cancel() refusal.
		synthetic_settled = owner.synthetic_pending ~= true
	end
	local released = maybe_release_text_owner(owner)
	return timers_settled == true and clipboard_settled == true
		and synthetic_settled == true and released == true
end

--- Acquires one named slot after retrying prior fenced debt.
--- @param kind string transform|plain|wrap|surround.
--- @return table|nil owner
local function acquire_text_owner(kind, parent)
	local scope = text_scope(parent)
	if scope.paused == true then return nil end
	for _, existing in pairs(scope.slots) do
		if existing and existing.business_open ~= true then settle_text_owner(existing) end
	end
	if text_owner_pending(scope) then return nil end
	-- Clipboard and document mutations are process-global even though PAUSE is
	-- parent-scoped. Refuse a sibling owner without consuming its lifecycle debt.
	for _, sibling_scope in pairs(_text_scopes) do
		if sibling_scope ~= scope and text_owner_pending(sibling_scope) then return nil end
	end
	local owner = {
		kind = kind,
		scope = scope,
		parent = scope.id,
		generation = scope.generation,
		business_open = true,
		released = false,
		timers = {},
		timer_acquisitions = 0,
		mutations = 0,
		clipboard_owned = false,
		synthetic_pending = false,
	}
	scope.slots[kind] = owner
	return owner
end

--- Crosses one fallible producer boundary while making re-entrant PAUSE wait.
--- A boundary that triggered PAUSE may finish its native call, but its result is
--- rejected before any successor mutation can be published.
--- @param owner table Text owner.
--- @param fn function Boundary function.
--- @param ... any Arguments.
--- @return boolean ok
--- @return any result
local function call_text_boundary(owner, fn, ...)
	if not text_owner_authorized(owner) then return false, "text admission is closed" end
	owner.mutations = owner.mutations + 1
	local results = table.pack(pcall(fn, ...))
	owner.mutations = owner.mutations - 1
	if not text_owner_authorized(owner) then return false, "text admission was revoked" end
	return table.unpack(results, 1, results.n)
end

--- Fences and joins every text owner for the Bindings lifecycle.
--- @return boolean settled
function M.pause_text_actions(parent)
	local scope = text_scope(parent)
	if scope.paused ~= true then
		scope.generation = scope.generation + 1
		scope.paused = true
	end
	local snapshot = {}
	for _, owner in pairs(scope.slots) do
		if owner then snapshot[#snapshot + 1] = owner end
	end
	local settled = true
	for _, owner in ipairs(snapshot) do
		if settle_text_owner(owner) ~= true then settled = false end
	end
	return settled == true and not text_owner_pending(scope)
end

--- Reopens admission only after every prior capability has settled; interrupted
--- user actions are never replayed.
--- @return boolean settled
function M.resume_text_actions(parent)
	local scope = text_scope(parent)
	-- RESUME is an idempotent lifecycle edge. Re-running quiesce while admission
	-- is already open would cancel an unrelated action that started after the
	-- original resume committed.
	if scope.paused ~= true then return true end
	local snapshot = {}
	for _, owner in pairs(scope.slots) do
		if owner then snapshot[#snapshot + 1] = owner end
	end
	for _, owner in ipairs(snapshot) do
		if settle_text_owner(owner) ~= true then
			scope.paused = true
			return false
		end
	end
	scope.generation = scope.generation + 1
	scope.paused = false
	return true
end

--- Stops text work for Bindings.stop(); start may later call resume_text_actions.
--- @return boolean settled
function M.stop_text_actions(parent)
	return M.pause_text_actions(parent)
end

--- @return boolean paused
function M.is_text_actions_paused(parent)
	return text_scope(parent).paused == true
end

--- @return boolean pending
function M.has_pending_text_action(parent)
	return text_owner_pending(text_scope(parent))
end





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
local SURROUND_CLOSE_DELAY_SEC = 0.04 -- Preserve the original delayed caret move after the opening batch lands
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
--- @param owner table Transform owner.
--- @return boolean dispatched
local function reselect_previous_text(count, owner)
	if type(count) ~= "number" or count < 1 then return true end
	if not text_owner_authorized(owner) then return false end
	local tx = nil
	owner.mutations = owner.mutations + 1
	local ok, err = xpcall(function()
		tx = SyntheticInput.begin("shortcuts.text.reselect", "action")
		local batch = SyntheticInput.begin_batch(tx)
		for _ = 1, count do
			assert(SyntheticInput.keyStroke(batch, {}, "left") == true,
				"synthetic left reselection stroke was refused")
		end
		for _ = 1, count do
			assert(SyntheticInput.keyStroke(batch, { "shift" }, "right") == true,
				"synthetic right reselection stroke was refused")
		end
		assert(text_owner_authorized(owner),
			"text admission was revoked during reselection build")
		assert(SyntheticInput.dispatch(batch) == true,
			"synthetic reselection batch could not be dispatched")
		assert(SyntheticInput.seal(tx) == true,
			"synthetic reselection transaction could not be sealed")
	end, debug.traceback)
	owner.mutations = owner.mutations - 1
	if ok and text_owner_authorized(owner) then return true end
	if tx then pcall(SyntheticInput.cancel, tx) end
	Logger.error(LOG, "Text reselection could not be dispatched - %s.", tostring(err))
	return false
end

local function do_transform(transform_func, parent)
	local scope = text_scope(parent)
	if scope.paused == true then return false end
	if _transform_in_flight then
		Logger.debug(LOG, "Text transform ignored — a previous one still owns the clipboard.")
		return false
	end
	local owner = acquire_text_owner("transform", scope.id)
	if not owner then return false end
	_transform_in_flight = true
	_transform_generation = _transform_generation + 1
	local my_generation = _transform_generation
	local active = true
	local owns_clipboard = false
	local restore_retry_armed = false
	local deferred_retry_armed = false

	local function stop_all_timers()
		return cancel_text_timers(owner)
	end

	local function release()
		if not active or my_generation ~= _transform_generation then return false end
		active = false
		owner.business_open = false
		local timers_settled = stop_all_timers()
		local clipboard_settled = select(1, restore_text_clipboard(owner))
		if clipboard_settled then owns_clipboard = false end
		local released = maybe_release_text_owner(owner)
		return timers_settled == true and clipboard_settled == true and released == true
	end
	owner.on_release = function()
		active = false
		owns_clipboard = false
		_transform_in_flight = false
		if my_generation == _transform_generation then
			_transform_generation = _transform_generation + 1
		end
	end

	Logger.trace(LOG, "Text transformation started…")
	local ok_snapshot, prior = call_text_boundary(owner, pasteboard.readAllData)
	if not ok_snapshot or (prior ~= nil and type(prior) ~= "table") then
		release()
		Logger.error(LOG, "Text transform clipboard snapshot failed: %s.", tostring(prior))
		return false
	end
	owns_clipboard = true
	owner.clipboard_prior = prior or {}
	owner.clipboard_owned = true

	local restore_prior
	local queue_restore_retry
	local abort_transform
	owner.on_timer_settled = function()
		if owner.cleanup_waiting == true and owner.cleanup_settling ~= true
			and owner.cleanup_only == true and owns_clipboard
			and scope.paused ~= true and scope.slots.transform == owner then
			owner.cleanup_waiting = false
			queue_restore_retry()
		end
	end

	restore_prior = function()
		if not owns_clipboard then return true end
		local ok_restore, restore_result = restore_text_clipboard(owner)
		if ok_restore == true then
			owns_clipboard = false
			return true, nil
		end
		return false, restore_result
	end

	local function schedule_transform_timer(delay, label, callback, cleanup)
		return schedule_text_timer(owner, delay, "Text transform " .. label, function()
			if not active or my_generation ~= _transform_generation then return end
			if owner.cleanup_only == true and cleanup ~= true then return end
			local ok_callback, callback_error = xpcall(callback, debug.traceback)
			if not ok_callback then
				Logger.error(LOG, "Text transform %s callback failed: %s.",
					label, tostring(callback_error))
				if abort_transform then abort_transform(label .. " callback", callback_error) end
			end
		end)
	end

	queue_restore_retry = function()
		if restore_retry_armed or deferred_retry_armed or not owns_clipboard then return true end
		owner.cleanup_only = true
		owner.cleanup_settling = true
		local prior_timers_settled = cancel_text_timers(owner)
		owner.cleanup_settling = false
		if prior_timers_settled ~= true then
			owner.cleanup_waiting = true
			return false
		end
		owner.cleanup_waiting = false
		local function attempt_restore()
			if scope.paused == true or scope.slots.transform ~= owner then return end
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
		local armed, timer_error, retry_entry = schedule_transform_timer(
			RESTORE_DELAY_SEC, "clipboard restore retry", attempt_restore, true)
		if armed then
			restore_retry_armed = true
			return true
		end
		if retry_entry and owner.timers[retry_entry.id] == retry_entry then
			owner.cleanup_waiting = true
			return false
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
		local ok_selection, selection = call_text_boundary(owner, pasteboard.getContents)
		if not ok_selection or type(selection) ~= "string" or selection == "" then
			abort_transform("selection copy", selection)
			return
		end
		local ok_transform, transformed = call_text_boundary(owner, transform_func, selection)
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
				if count > 0 and not reselect_previous_text(count, owner) then
					abort_transform("text reselection", "synthetic dispatch refused")
				end
			end
			local reselect_armed, reselect_timer_error = schedule_transform_timer(
				RESELECT_DELAY_SEC, "reselection", reselect_stage)
			if not reselect_armed then
				abort_transform("reselection timer", reselect_timer_error)
				return
			end
			local ok_paste, pasted = call_text_boundary(owner,
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
		local ok_write, write_result = call_text_boundary(
			owner, pasteboard.setContents, transformed)
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

	local ok_clear, clear_error = call_text_boundary(owner, pasteboard.clearContents)
	if not ok_clear then
		abort_transform("clipboard clear", clear_error)
		return false
	end
	local ok_copy, copied = call_text_boundary(owner,
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
function M.paste_as_plain_text(parent)
	local scope = text_scope(parent)
	if scope.paused == true then return false end
	if _plain_paste_in_flight then
		Logger.debug(LOG, "Plain-text paste ignored — a previous action still owns the clipboard.")
		return false
	end
	local owner = acquire_text_owner("plain", scope.id)
	if not owner then return false end
	local ok_snapshot, prior = call_text_boundary(owner, pasteboard.readAllData)
	if not ok_snapshot or (prior ~= nil and type(prior) ~= "table") then
		owner.business_open = false
		maybe_release_text_owner(owner)
		Logger.error(LOG, "Plain-text paste clipboard snapshot failed.")
		return false
	end
	local ok_plain, plain = call_text_boundary(owner, pasteboard.getContents)
	if not ok_plain then
		owner.business_open = false
		maybe_release_text_owner(owner)
		Logger.error(LOG, "Plain-text paste clipboard snapshot failed.")
		return false
	end
	_plain_paste_in_flight = true
	_plain_paste_generation = _plain_paste_generation + 1
	local generation = _plain_paste_generation
	local owns_clipboard = true
	local active = true
	local retry_armed = false
	local deferred_retry_armed = false
	local restore_prior
	local queue_restore_retry
	local abort_plain_paste
	owner.clipboard_prior = prior or {}
	owner.clipboard_owned = true
	owner.on_timer_settled = function()
		if owner.cleanup_waiting == true and owner.cleanup_settling ~= true
			and owner.cleanup_only == true and owns_clipboard
			and scope.paused ~= true and scope.slots.plain == owner then
			owner.cleanup_waiting = false
			queue_restore_retry()
		end
	end

	local function stop_all_timers()
		return cancel_text_timers(owner)
	end

	local function release()
		if not active or generation ~= _plain_paste_generation then return false end
		active = false
		owner.business_open = false
		local timers_settled = stop_all_timers()
		local clipboard_settled = select(1, restore_text_clipboard(owner))
		if clipboard_settled then owns_clipboard = false end
		local released = maybe_release_text_owner(owner)
		return timers_settled == true and clipboard_settled == true and released == true
	end
	owner.on_release = function()
		active = false
		owns_clipboard = false
		_plain_paste_in_flight = false
		if generation == _plain_paste_generation then
			_plain_paste_generation = _plain_paste_generation + 1
		end
	end

	restore_prior = function()
		if not owns_clipboard then return true end
		local ok_restore, restore_result = restore_text_clipboard(owner)
		if ok_restore == true then owns_clipboard = false; return true, nil end
		return false, restore_result
	end

	local function schedule_plain_timer(delay, label, callback, cleanup)
		return schedule_text_timer(owner, delay, "Plain-text paste " .. label, function()
			if not active or generation ~= _plain_paste_generation then return end
			if owner.cleanup_only == true and cleanup ~= true then return end
			local ok_callback, callback_error = xpcall(callback, debug.traceback)
			if not ok_callback then
				Logger.error(LOG, "Plain-text paste %s callback failed: %s.",
					label, tostring(callback_error))
				if abort_plain_paste then abort_plain_paste(label .. " callback", callback_error) end
			end
		end)
	end

	queue_restore_retry = function()
		if retry_armed or deferred_retry_armed or not owns_clipboard then return true end
		owner.cleanup_only = true
		owner.cleanup_settling = true
		local prior_timers_settled = cancel_text_timers(owner)
		owner.cleanup_settling = false
		if prior_timers_settled ~= true then
			owner.cleanup_waiting = true
			return false
		end
		owner.cleanup_waiting = false
		local function attempt_restore()
			if scope.paused == true or scope.slots.plain ~= owner then return end
			retry_armed = false
			deferred_retry_armed = false
			local restored, restore_error = restore_prior()
			if restored then release(); return end
			Logger.error(LOG, "Plain-text paste clipboard restore retry refused: %s.",
				tostring(restore_error))
			queue_restore_retry()
		end
		local armed, timer_error, retry_entry = schedule_plain_timer(
			RESTORE_DELAY_SEC, "clipboard restore retry", attempt_restore, true)
		if armed then retry_armed = true; return true end
		if retry_entry and owner.timers[retry_entry.id] == retry_entry then
			owner.cleanup_waiting = true
			return false
		end
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
			local ok_emit, emitted = call_text_boundary(owner,
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

	local ok_write, write_result = call_text_boundary(
		owner, pasteboard.setContents, plain or "")
	if not ok_write or write_result ~= true then
		abort_plain_paste("clipboard write", write_result)
		return false
	end
	return true
end

--- Selects the entire current line (Cmd+Left, then Cmd+Shift+Right).
function M.select_line(parent)
	local scope = text_scope(parent)
	if scope.paused == true or any_text_owner_pending() then return false end
	if SyntheticInput.emit_key_stroke(
		{"cmd"}, "left", KEYSTROKE_NO_DELAY_US) ~= true then return false end
	if scope.paused == true or any_text_owner_pending() then return false end
	return SyntheticInput.emit_key_stroke(
		{"cmd", "shift"}, "right", KEYSTROKE_NO_DELAY_US) == true
end

--- Wraps the current line in parentheses.
function M.surround_with_parens(parent)
	local scope = text_scope(parent)
	if scope.paused == true then return false end
	local owner = acquire_text_owner("surround", scope.id)
	if not owner then return false end
	local close_surround
	local queue_surround_close_retry
	local process_opening_terminal
	local process_closing_terminal

	-- Publish drain-visible transaction ownership before any document mutation.
	-- The retain token permits exactly one closing sibling after the opening
	-- transaction is sealed, and remains owned until that sibling is terminal.
	owner.synthetic_pending = true
	local tx, token
	local tx_ok, tx_error = xpcall(function()
		tx = SyntheticInput.begin("shortcuts.text.surround", "action")
		assert(tx ~= nil, "surround transaction was not created")
		owner.synthetic_tx = tx
		token = SyntheticInput.retain(tx)
		assert(type(token) == "table", "surround retain token was not created")
		owner.synthetic_token = token
		SyntheticInput.on_complete(tx, function(completed_tx, status)
			if owner.synthetic_tx ~= completed_tx or owner.synthetic_pending ~= true then return end
			owner.synthetic_status = status
			owner.synthetic_pending = false
			owner.synthetic_token = nil
			owner.business_open = false
			maybe_release_text_owner(owner)
		end)
		owner.synthetic_completion_registered = true
	end, debug.traceback)
	if not tx_ok or not tx or not token then
		owner.business_open = false
		if tx then
			local cancel_ok, cancelled = pcall(SyntheticInput.cancel, tx)
			if cancel_ok and cancelled == true
				and owner.synthetic_completion_registered ~= true then
				owner.synthetic_pending = false
				owner.synthetic_token = nil
			end
		else
			owner.synthetic_pending = false
		end
		if owner.synthetic_pending == true then settle_text_owner(owner)
		else maybe_release_text_owner(owner) end
		Logger.error(LOG, "Parenthesis surround transaction acquisition failed: %s.",
			tostring(tx_error))
		return false
	end

	--- Tests whether the proven opening may still receive its closing sibling.
	--- @return boolean authorized
	local function surround_completion_allowed()
		return owner.opening_dispatched == true
			and owner.synthetic_pending == true
			and owner.released ~= true
			and scope.slots.surround == owner
	end

	owner.on_timer_settled = function(_, entry)
		local recover_failed_retry = owner.closing_retry_entry == entry
			and entry.discard == true and entry.due ~= true
			and owner.closing_retry_needed == true
		if owner.closing_timer_entry == entry then
			owner.closing_timer_entry = nil
		end
		if owner.closing_retry_entry == entry then
			owner.closing_retry_entry = nil
		end
		if recover_failed_retry and surround_completion_allowed()
			and owner.closing_batch == nil then
			owner.closing_retry_needed = false
			close_surround()
		end
	end
	local function release_surround_retain()
		local retain = owner.synthetic_token
		if not retain or retain.active ~= true then return owner.synthetic_pending ~= true end
		local release_ok, released = pcall(SyntheticInput.release, tx, retain)
		if release_ok and released == true then
			owner.synthetic_token = nil
			return true
		end
		Logger.error(LOG, "Parenthesis surround retain release failed: %s.",
			tostring(release_ok and released or released))
		return false
	end

	--- Ends a transaction that proved no opening output was published.
	--- @param status any Opening terminal status.
	local function cancel_unpublished_surround(status)
		owner.business_open = false
		local cancel_ok, cancelled = pcall(SyntheticInput.cancel, tx)
		if not cancel_ok or (cancelled ~= true and owner.synthetic_pending == true) then
			Logger.error(LOG, "Parenthesis surround cancellation remains pending after %s: %s.",
				tostring(status), tostring(cancel_ok and cancelled or cancelled))
		end
		maybe_release_text_owner(owner)
	end

	--- Completes synthetic ownership only after the closing batch is terminal.
	local function finish_surround()
		owner.business_open = false
		if release_surround_retain() ~= true and owner.synthetic_pending == true then
			-- Both document mutations are already proven dispatched. Cancelling is
			-- now a safe exact fallback for a retain release that refused or threw.
			local cancel_ok, cancelled = pcall(SyntheticInput.cancel, tx)
			if not cancel_ok or (cancelled ~= true and owner.synthetic_pending == true) then
				Logger.error(LOG, "Parenthesis surround terminal cleanup remains pending: %s.",
					tostring(cancel_ok and cancelled or cancelled))
			end
		end
		maybe_release_text_owner(owner)
	end

	--- Arms one autonomous retry after a closing batch proves it published no text.
	--- @return boolean committed
	queue_surround_close_retry = function()
		if owner.closing_dispatched == true or owner.closing_batch ~= nil
			or owner.closing_retry_entry ~= nil
			or not surround_completion_allowed() then
			return false
		end
		owner.closing_retry_needed = true
		local committed, detail, entry = schedule_text_timer(
			owner, SURROUND_CLOSE_DELAY_SEC,
			"Parenthesis surround closing retry", close_surround, true)
		if entry and owner.timers[entry.id] == entry then
			owner.closing_retry_entry = entry
		end
		if committed ~= true then
			Logger.error(LOG, "Parenthesis surround closing retry remains pending: %s.",
				tostring(detail))
			-- A clean timer refusal owns no future callback. Retry the cleanup
			-- synchronously once; a retained native timer instead resumes from its
			-- exact onSettled observer above. Repeated synchronous broker/timer
			-- failures retain the intent instead of recursively exhausting the stack.
			if not entry or owner.timers[entry.id] ~= entry then
				owner.closing_retry_entry = nil
				if owner.direct_close_recovery == true then return false end
				owner.direct_close_recovery = true
				owner.closing_retry_needed = false
				local recovered = close_surround() == true
				owner.direct_close_recovery = false
				return recovered
			end
			return false
		end
		return true
	end

	close_surround = function()
		if owner.closing_dispatched == true or owner.synthetic_pending ~= true then
			return true
		end
		if owner.closing_batch ~= nil or not surround_completion_allowed() then return false end
		owner.closing_retry_needed = false
		owner.mutations = owner.mutations + 1
		local batch = nil
		local build_ok, build_error = xpcall(function()
			batch = SyntheticInput.begin_batch(tx, token)
			assert(type(batch) == "table", "closing batch was not created")
			assert(surround_completion_allowed(),
				"text admission was revoked before closing output")
			assert(SyntheticInput.keyStroke(batch, { "cmd" }, "right") == true,
				"closing cursor movement was refused")
			assert(surround_completion_allowed(),
				"text admission was revoked during closing output")
			assert(SyntheticInput.keyStrokes(batch, ")") == true,
				"closing parenthesis was refused")
		end, debug.traceback)
		owner.mutations = owner.mutations - 1
		if not build_ok then
			Logger.error(LOG, "Parenthesis surround closing batch build failed: %s.",
				tostring(build_error))
			local discard_ok, discarded = pcall(SyntheticInput.discard_batch, batch)
			if not discard_ok or discarded ~= true then
				Logger.error(LOG, "Parenthesis surround partial closing batch remains pending: %s.",
					tostring(discard_ok and discarded or discarded))
				return false
			end
			if queue_surround_close_retry() ~= true then
				Logger.error(LOG, "Parenthesis surround closing recovery remains pending.")
			end
			return false
		end

		owner.closing_batch = batch
		owner.closing_terminal_seen = false
		owner.closing_dispatch_in_progress = true
		owner.mutations = owner.mutations + 1
		local dispatch_ok, dispatched = xpcall(function()
			return SyntheticInput.dispatch(batch)
		end, debug.traceback)
		owner.mutations = owner.mutations - 1
		owner.closing_dispatch_in_progress = false
		local buffered_status = owner.closing_terminal_buffer
		owner.closing_terminal_buffer = nil
		if buffered_status ~= nil then process_closing_terminal(batch, buffered_status) end
		if not dispatch_ok or dispatched ~= true then
			Logger.error(LOG, "Parenthesis surround closing dispatch was not accepted: %s.",
				tostring(dispatch_ok and dispatched or dispatched))
			-- The exact batch remains authoritative until on_dispatched proves it
			-- failed. Retrying merely from a false/throw return could duplicate `)`.
			return owner.closing_dispatched == true
		end
		return true
	end

	--- Consumes the exact terminal of the opening batch once.
	--- @param status string dispatched|failed|cancelled.
	process_opening_terminal = function(status)
		if owner.opening_terminal_processed == true then return end
		owner.opening_terminal_processed = true
		owner.opening_awaiting_terminal = false
		owner.opening_status = status
		if status ~= "dispatched" then
			cancel_unpublished_surround(status)
			return
		end

		-- Only this adapter terminal proves that `(` left the FIFO. From here on,
		-- the matching close is cleanup and remains authorized across PAUSE.
		owner.opening_dispatched = true
		owner.completion_only = true
		local timer_committed, timer_error, timer_entry = schedule_text_timer(
			owner, SURROUND_CLOSE_DELAY_SEC,
			"Parenthesis surround closing", close_surround, true)
		if timer_entry and owner.timers[timer_entry.id] == timer_entry then
			owner.closing_timer_entry = timer_entry
		end
		if timer_committed ~= true then
			Logger.error(LOG, "Parenthesis surround closing timer was refused: %s.",
				tostring(timer_error))
			-- The opening is already terminally visible. Complete immediately rather
			-- than strand it merely because the cosmetic delay was unavailable.
			close_surround()
		end
	end

	--- Consumes one exact closing attempt terminal and retries only proven failure.
	--- @param batch table Exact closing batch.
	--- @param status string dispatched|failed|cancelled.
	process_closing_terminal = function(batch, status)
		if owner.closing_batch ~= batch or owner.closing_terminal_seen == true then return end
		owner.closing_terminal_seen = true
		owner.closing_batch = nil
		owner.closing_status = status
		if status == "dispatched" then
			owner.closing_dispatched = true
			finish_surround()
			return
		end
		Logger.error(LOG, "Parenthesis surround closing batch ended as %s; retrying.",
			tostring(status))
		if queue_surround_close_retry() ~= true then
			Logger.error(LOG, "Parenthesis surround closing recovery remains pending.")
		end
	end

	owner.on_quiesce = function()
		if owner.opening_awaiting_terminal == true then
			-- A false/throw return cannot prove whether dispatch mutated first. Wait
			-- for the registered exact terminal instead of guessing and duplicating.
			owner.completion_only = true
			return true, false
		end
		if owner.opening_dispatched == true and owner.synthetic_pending == true then
			owner.completion_only = true
			if owner.closing_dispatched == true then
				finish_surround()
			elseif owner.closing_batch == nil
				and owner.closing_timer_entry == nil
				and owner.closing_retry_entry == nil then
				if queue_surround_close_retry() ~= true then close_surround() end
			end
			return true, false
		end
		return false, false
	end

	local opening_batch = nil
	owner.mutations = owner.mutations + 1
	local opening_ok, opening_error = xpcall(function()
		opening_batch = SyntheticInput.begin_batch(tx)
		assert(type(opening_batch) == "table", "opening batch was not created")
		owner.opening_batch = opening_batch
		assert(text_owner_authorized(owner),
			"text admission was revoked before opening output")
		assert(SyntheticInput.keyStroke(opening_batch, { "cmd" }, "left") == true,
			"opening cursor movement was refused")
		assert(text_owner_authorized(owner),
			"text admission was revoked during opening output")
		assert(SyntheticInput.keyStrokes(opening_batch, "(") == true,
			"opening parenthesis was refused")
		assert(text_owner_authorized(owner),
			"text admission was revoked before opening callback registration")
	end, debug.traceback)
	owner.mutations = owner.mutations - 1
	if not opening_ok then
		owner.business_open = false
		settle_text_owner(owner)
		Logger.error(LOG, "Parenthesis surround opening build failed: %s.",
			tostring(opening_error))
		return false
	end

	owner.mutations = owner.mutations + 1
	local observer_ok, observer_error = xpcall(function()
		SyntheticInput.on_dispatched(tx, function(dispatched_tx, batch, status)
			if dispatched_tx ~= tx or owner.released == true then return end
			if batch == owner.opening_batch then
				if owner.opening_dispatch_started ~= true
					or owner.opening_terminal_processed == true then return end
				if owner.opening_dispatch_in_progress == true then
					if owner.opening_terminal_buffer == nil then
						owner.opening_terminal_buffer = status
					end
					return
				end
				process_opening_terminal(status)
			elseif batch == owner.closing_batch then
				if owner.closing_terminal_seen == true then return end
				if owner.closing_dispatch_in_progress == true then
					if owner.closing_terminal_buffer == nil then
						owner.closing_terminal_buffer = status
					end
					return
				end
				process_closing_terminal(batch, status)
			end
		end)
	end, debug.traceback)
	owner.mutations = owner.mutations - 1
	if not observer_ok or not text_owner_authorized(owner) then
		owner.business_open = false
		settle_text_owner(owner)
		Logger.error(LOG, "Parenthesis surround dispatch observer failed: %s.",
			tostring(observer_error))
		return false
	end

	owner.opening_awaiting_terminal = true
	owner.opening_dispatch_started = true
	owner.opening_dispatch_in_progress = true
	owner.mutations = owner.mutations + 1
	local dispatch_ok, dispatched = xpcall(function()
		return SyntheticInput.dispatch(opening_batch)
	end, debug.traceback)
	owner.mutations = owner.mutations - 1
	owner.opening_dispatch_in_progress = false

	owner.mutations = owner.mutations + 1
	local seal_ok, seal_result = xpcall(function()
		return SyntheticInput.seal(tx)
	end, debug.traceback)
	owner.mutations = owner.mutations - 1
	if not seal_ok or (seal_result ~= true and seal_result ~= false) then
		Logger.error(LOG, "Parenthesis surround seal remains uncertain: %s.",
			tostring(seal_ok and seal_result or seal_result))
	end

	local buffered_status = owner.opening_terminal_buffer
	owner.opening_terminal_buffer = nil
	if buffered_status ~= nil then process_opening_terminal(buffered_status) end
	if owner.opening_status == "dispatched" then return true end
	if owner.opening_terminal_processed == true then return false end
	if not dispatch_ok or dispatched ~= true then
		owner.business_open = false
		Logger.error(LOG, "Parenthesis surround opening dispatch remains uncertain: %s.",
			tostring(dispatch_ok and dispatched or dispatched))
		return false
	end
	return true
end

--- Toggles the current selection between Title Case and lowercase.
function M.toggle_titlecase(parent)
	return do_transform(function(sel)
		local t = titlecase(sel)
		-- If already title-cased, drop to lowercase; otherwise apply title case
		return (sel == t) and sel:lower() or t
	end, parent)
end

--- Toggles the current selection between UPPERCASE and lowercase.
function M.toggle_uppercase(parent)
	return do_transform(function(sel)
		-- Promote if any lowercase exists; demote otherwise
		return sel:match("%l") and sel:upper() or sel:lower()
	end, parent)
end

--- Selects the current word under the cursor (Alt+Right, then Alt+Shift+Left).
function M.select_word(parent)
	local scope = text_scope(parent)
	if scope.paused == true or any_text_owner_pending() then return false end
	if SyntheticInput.emit_key_stroke(
		{"alt"}, "right", KEYSTROKE_NO_DELAY_US) ~= true then return false end
	if scope.paused == true or any_text_owner_pending() then return false end
	return SyntheticInput.emit_key_stroke(
		{"alt", "shift"}, "left", KEYSTROKE_NO_DELAY_US) == true
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
function M.wrap_selection(sel, left, right, parent)
	local scope = text_scope(parent)
	if scope.paused == true then return false end
	if _wrap_in_flight then
		defer_wrap_diagnostic("debug", "Wrap declined: another clipboard transaction is active.")
		return false
	end
	if type(sel) ~= "string" or sel == ""
		or type(left) ~= "string" or type(right) ~= "string" then
		defer_wrap_diagnostic("error", "Wrap declined: invalid selection or delimiter arguments.")
		return false
	end
	local owner = acquire_text_owner("wrap", scope.id)
	if not owner then return false end

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
		timer_entry = nil,
	}
	_wrap_in_flight = true
	local schedule_restore
	local attempt_restore

	local function restore_prior()
		local restored, result = restore_text_clipboard(owner)
		if restored == true then transaction.mutated = false end
		return restored, result
	end

	local function release()
		transaction.active = false
		owner.business_open = false
		local timers_settled = cancel_text_timers(owner)
		local clipboard_settled = select(1, restore_text_clipboard(owner))
		local released = maybe_release_text_owner(owner)
		return timers_settled == true and clipboard_settled == true and released == true
	end
	owner.on_release = function()
		transaction.active = false
		transaction.mutated = false
		if transaction.generation == _wrap_generation then
			_wrap_in_flight = false
			_wrap_generation = _wrap_generation + 1
		end
	end
	owner.on_timer_settled = function(_, entry)
		if transaction.timer_entry == entry then
			transaction.timer_entry = nil
			transaction.timer = nil
			if _wrap_restore_timer == entry.handle then _wrap_restore_timer = nil end
		end
		if transaction.restore_waiting == true
			and transaction.restore_scheduling ~= true
			and transaction.active == true and transaction.committed == true
			and scope.paused ~= true and scope.slots.wrap == owner then
			transaction.restore_waiting = false
			attempt_restore(true)
		end
	end

	local function detach_timer(should_stop)
		local entry = transaction.timer_entry
		if not entry then return true end
		if should_stop then return cancel_text_timer(owner, entry) end
		return entry.delivered == true
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
		if transaction.timer_entry ~= nil then
			transaction.restore_waiting = true
			return false, "prior restore timer cleanup remains pending"
		end
		transaction.restore_scheduling = true
		local timer_ok, timer_error, entry = schedule_text_timer(
			owner, delay, "Wrap clipboard restore", function()
			if not transaction.active or not transaction.committed
				or transaction.generation ~= _wrap_generation
				or transaction.timer_entry ~= nil then
				return
			end
			attempt_restore(true)
		end)
		transaction.restore_scheduling = false
		if entry and owner.timers[entry.id] == entry then
			transaction.timer_entry = entry
			transaction.timer = entry.handle
			_wrap_restore_timer = entry.handle
		end
		if timer_ok ~= true or not entry then
			if transaction.timer_entry ~= nil then transaction.restore_waiting = true end
			return false, timer_error
		end
		return true, nil
	end

	attempt_restore = function(allow_lifecycle_fallback)
		if scope.paused == true or scope.slots.wrap ~= owner then return false end
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
		if transaction.timer_entry ~= nil then
			transaction.restore_waiting = true
			return false
		end
		local retry_scheduled = select(1, schedule_restore(PASTE_SETTLE_SEC))
		if retry_scheduled then return false end
		if transaction.timer_entry ~= nil then return false end

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

	local snapshot_ok, prior_or_error = call_text_boundary(owner, pasteboard.readAllData)
	if not snapshot_ok then
		return rollback("clipboard snapshot", prior_or_error)
	end
	if prior_or_error ~= nil and type(prior_or_error) ~= "table" then
		return rollback("clipboard snapshot", "readAllData returned " .. type(prior_or_error))
	end
	transaction.prior = prior_or_error
	transaction.prior_empty = prior_or_error == nil or next(prior_or_error) == nil
	owner.clipboard_prior = prior_or_error or {}
	owner.clipboard_owned = true

	-- Mark the clipboard conservatively before the call: a throwing pasteboard
	-- implementation may have changed its contents before reporting the error.
	transaction.mutated = true
	local write_ok, write_result = call_text_boundary(
		owner, pasteboard.setContents, left .. sel .. right)
	if not write_ok or write_result ~= true then
		return rollback("clipboard write", write_result)
	end

	-- Arm restoration before publishing Cmd+V. If allocation fails, rolling the
	-- clipboard back and passing the user's physical symbol is still possible.
	local timer_scheduled, timer_error = schedule_restore(RESTORE_DELAY_SEC)
	if not timer_scheduled then
		return rollback("restore timer", timer_error)
	end

	local emit_ok, emitted_or_error = call_text_boundary(owner,
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
function M.surround_selection_if_selected(symbol, left, right, parent)
	local scope = text_scope(parent)
	if scope.paused == true then return false end
	local sel = M.read_ax_selection()
	if sel then
		return M.wrap_selection(sel, left, right, scope.id)
	else
		-- No selection — type the raw symbol so the key behaves normally
		return SyntheticInput.emit_key_strokes(symbol) == true
	end
end

return M
