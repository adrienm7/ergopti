--- modules/keymap/utils.lua

--- ==============================================================================
--- MODULE: Keymap Utilities (Hammerspoon adapter)
--- DESCRIPTION:
--- Hammerspoon-specific keymap helpers layered on top of the shared pure-Lua
--- core from _shared/lua/keymap/utils.lua. Adds OS-level text emission
--- (simulated keystrokes and clipboard paste) and ignored-window detection,
--- which depend on hs.eventtap, hs.pasteboard, hs.timer, and hs.window.
---
--- FEATURES & RATIONALE:
--- 1. Safe Emission: Chooses between direct keystrokes or fast clipboard-paste
---    based on text length and unicode complexity, to handle any content reliably.
--- 2. Seamless LLM Integration: The overlap solver (re-exported from shared)
---    aligns the in-flight buffer with the AI completion to prevent ghost-text
---    duplication.
--- 3. Window Caching: The ignored-window result is cached for 0.5s to avoid
---    hitting the OS on every single keystroke.
--- ==============================================================================

local hs = hs
local M  = {}

local text_utils  = require("lib.text_utils")
local shared_utils = require("keymap.utils")
local keyStrokes  = hs.eventtap.keyStrokes
local keyStroke   = hs.eventtap.keyStroke
local Logger      = require("lib.logger")
local Timings     = require("lib.timings")

local LOG = "keymap.utils"

-- Re-export pure-Lua functions from the shared module so callers that require
-- this HS adapter keep working unchanged without needing to know about the split.
M.tokens_from_repl          = shared_utils.tokens_from_repl
M.plain_text                = shared_utils.plain_text
M.resolve_prediction_overlap = shared_utils.resolve_prediction_overlap





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

-- Threshold (in UTF-8 characters) above which clipboard-paste is used instead of
-- simulated keystrokes. Pasting is faster and avoids issues with long strings.
local PASTE_THRESHOLD = 50

-- How long the clipboard is left with the pasted value before restoring the
-- user's previous contents. Large enough to let the target app receive the paste.
-- Shared cross-driver value ([debounce] clipboard_restore_ms).
local CLIPBOARD_RESTORE_SEC = Timings.sec("debounce", "clipboard_restore_ms")

-- Minimum gap enforced between two consecutive clipboard pastes emitted from the
-- same emit_tokens() call. CGEventPost is asynchronous, so issuing a second
-- setContents+Cmd+V pair back-to-back can overwrite the clipboard before the OS
-- has delivered the first paste to the target app, corrupting that first segment
-- (multi-segment-paste-race). Reuses the existing paste-settle value rather than
-- introducing a new duplicate constant ([debounce] clipboard_paste_settle_ms).
local CLIPBOARD_PASTE_GAP_SEC = Timings.sec("debounce", "clipboard_paste_settle_ms")

-- Safety TTL (seconds) for the ignored-window cache. The cache is normally
-- invalidated on focus-change events (hs.application.watcher + hs.window.filter),
-- so this long TTL only acts as a net in the unlikely case the watcher misses an
-- event. Keeping it large means near-zero syscalls per keystroke in steady state.
local IGNORED_WIN_TTL_SEC = 5.0





-- ==========================================
-- ==========================================
-- ======= 2/ Text Emission Utilities =======
-- ==========================================
-- ==========================================

-- Clipboard serialisation state for the paste path.
-- When two paste expansions overlap within CLIPBOARD_RESTORE_SEC of each other,
-- naively reading readAllData() on the second paste yields the first expansion's
-- data rather than the user's real clipboard. This trio guarantees that only one
-- "original" value is ever saved and that the final doAfter always restores it.
local _paste_saved_original = nil   -- user's full clipboard data (table from readAllData) at first paste
local _paste_pending_timer  = nil   -- the active restore timer, if any
local _paste_ops_pending    = 0     -- count of Cmd+V echos yet to arrive (consumed by expander)

--- Returns true when the text is long enough or unicode-heavy enough that
--- clipboard-paste should be preferred over simulated keystrokes.
--- @param text string The text to evaluate.
--- @return boolean
function M.should_paste(text)
	if type(text) ~= "string" then return false end

	local ok_len, len = pcall(text_utils.utf8_len, text)
	if ok_len and len > PASTE_THRESHOLD then return true end

	local ok_high, has_high = pcall(text_utils.contains_high_unicode, text)
	if ok_high and has_high then return true end

	return false
end

--- Atomically reads and resets the pending paste-ops counter.
--- Called by expander.lua immediately after emit_action() to detect whether
--- any token was delivered via clipboard paste rather than keystrokes. The
--- returned count is added to CoreState.expected_synthetic_pastes so the
--- keydown handler can swallow the Cmd+V echoes without wiping the buffer.
--- @return number Paste operations fired since the last call (usually 0 or 1).
function M.take_paste_ops()
	local n = _paste_ops_pending
	_paste_ops_pending = 0
	return n
end

--- Pure predicate: is this exact keystroke the Cmd+V echo of a pending
--- synthetic paste? Mirrors the check keymap/init.lua's onKeyDownRaw already
--- uses to DRAIN expected_synthetic_pastes, but as a read-only peek so a
--- second caller (the keylogger's shortcut-classification branch) can consult
--- the same fact without mutating the counter itself (F-HIGH-17 fix: without
--- this, every long paste-worthy expansion was logged as a genuine user
--- Cmd+V keyboard shortcut, inflating the shortcut-count metric).
--- Takes `is_v_key` as an already-resolved boolean (rather than a raw keycode
--- + keycode-map lookup) so this pure function never needs its own OS call.
--- @param flags table The modifier flags from the key event.
--- @param is_v_key boolean Whether the keystroke's keycode resolves to "v".
--- @param pending_pastes number The current CoreState.expected_synthetic_pastes count.
--- @return boolean True when this keystroke is a pending synthetic paste echo.
function M.is_synthetic_paste_keystroke(flags, is_v_key, pending_pastes)
	return type(flags) == "table" and flags.cmd == true
		and is_v_key == true
		and (tonumber(pending_pastes) or 0) > 0
end

--- Mutates the clipboard with `value` and issues the Cmd+V keystroke, then
--- arms the async restore-to-original timer. Extracted so both emit_text and
--- emit_tokens (which may need to defer this call — see the serialisation
--- comment in emit_tokens) share the exact same paste + restore contract.
--- @param value string The text to paste.
local function perform_paste(value)
	-- Serialise clipboard ownership: if a restore is already pending,
	-- cancel it but keep _paste_saved_original (the user's real
	-- clipboard) — reading readAllData() now would return the first
	-- expansion's data rather than what the user had copied.
	if _paste_pending_timer then
		pcall(function() _paste_pending_timer:stop() end)
		_paste_pending_timer = nil
	else
		-- Preserve all clipboard types (images, RTF, etc.), not just plain text.
		_paste_saved_original = hs.pasteboard.readAllData()
	end
	hs.pasteboard.setContents(value)
	keyStroke({ "cmd" }, "v", 0)
	-- Restore clipboard asynchronously after the target app has received the paste.
	local saved = _paste_saved_original
	_paste_pending_timer = hs.timer.doAfter(CLIPBOARD_RESTORE_SEC, function()
		_paste_pending_timer  = nil
		_paste_saved_original = nil
		if type(saved) == "table" and next(saved) ~= nil then
			pcall(hs.pasteboard.writeAllData, saved)
		else
			pcall(hs.pasteboard.setContents, "")
		end
	end)
end

--- Emits a sequence of tokens by simulating keystrokes or pasting via the clipboard.
---
--- Consecutive paste-worthy tokens (e.g. two long segments separated by a
--- literal newline, as in a signature/address block) are serialised via a
--- named inter-token delay: CGEventPost is asynchronous, so mutating the
--- clipboard again before the OS has delivered the previous Cmd+V would
--- overwrite it mid-flight and corrupt the earlier segment
--- (multi-segment-paste-race). Only the FIRST paste in the loop fires
--- synchronously; every subsequent one is chained onto hs.timer.doAfter so
--- each paste's Cmd+V has CLIPBOARD_PASTE_GAP_SEC to be consumed before the
--- next setContents() call runs.
--- @param tokens table The token list produced by tokens_from_repl().
--- @return number, string, string Total characters, the physical keystroke
---   echo, and the logical text inserted. Clipboard text is deliberately absent
---   from the physical echo, but remains in the logical text for telemetry.
function M.emit_tokens(tokens)
	if type(tokens) ~= "table" then
		Logger.error(LOG, "emit_tokens: tokens must be a table (got %s).", type(tokens))
		return 0, "", ""
	end

	Logger.trace(LOG, "Emitting %d token(s)…", #tokens)
	local count        = 0
	local emitted_str  = ""
	local logical_text = ""
	-- Chain cursor: seconds from now at which the NEXT paste in this call is
	-- allowed to mutate the clipboard. 0 means "fire immediately" (no prior
	-- paste queued yet in this emit_tokens call).
	local next_paste_delay = 0

	-- When the next token of ANY kind may be emitted. Stays 0 — i.e. everything
	-- keeps firing inline — until a paste is actually DEFERRED. Only a deferred
	-- paste creates an ordering hazard: an inline paste has already posted its
	-- Cmd+V by the time the next token runs, and CGEvent delivery preserves post
	-- order, so a following inline keystroke still lands after it. Chaining after
	-- an inline paste too would add a settle gap to the common single-segment
	-- expansion for no benefit.
	local order_delay = 0

	--- Emits inline when nothing is queued ahead, otherwise chains behind it.
	--- Declared above the loop so the closures below capture it rather than a nil
	--- global. Keys and short text reach the OS synchronously, so without this a
	--- token following a deferred paste overtakes it and the replacement arrives
	--- scrambled on screen.
	--- @param delay number Seconds to wait, or <= 0 to fire inline.
	--- @param fn function The emission to perform.
	local function emit_in_order(delay, fn)
		if delay <= 0 then fn() else hs.timer.doAfter(delay, fn) end
	end

	for _, tok in ipairs(tokens) do
		if type(tok) ~= "table" then goto continue end

		if tok.kind == "key" then
			local key_value = tok.value  -- Bound per iteration for the deferred closure
			emit_in_order(order_delay, function() keyStroke({}, key_value, 0) end)
			count = count + 1

		elseif tok.kind == "text" then
			-- Clipboard text has no per-character OS echo but is still part of
			-- the logical replacement consumed by synthetic telemetry.
			logical_text = logical_text .. tok.value
			if M.should_paste(tok.value) then
				local ok_l, tok_len = pcall(text_utils.utf8_len, tok.value)
				count              = count + (ok_l and tok_len or 1)
				_paste_ops_pending = _paste_ops_pending + 1

				local paste_at    = next_paste_delay
				local paste_value = tok.value  -- Bound per iteration for the deferred closure
				if paste_at <= 0 then
					perform_paste(paste_value)
				else
					Logger.debug(LOG, "Deferring paste of %d char(s) by %.2fs to avoid clipboard race.",
						ok_l and tok_len or 1, paste_at)
					hs.timer.doAfter(paste_at, function() perform_paste(paste_value) end)
				end
				-- Every following paste-worthy token must wait at least one more
				-- gap so two deferred pastes never collapse onto the same tick.
				next_paste_delay = paste_at + CLIPBOARD_PASTE_GAP_SEC
				-- A DEFERRED paste has not reached the OS yet, so every later token
				-- must queue strictly behind it. An inline one needs no such fence.
				if paste_at > 0 then order_delay = next_paste_delay end
			else
				local text_value = tok.value  -- Bound per iteration for the deferred closure
				emit_in_order(order_delay, function() keyStrokes(text_value) end)
				local ok, len = pcall(text_utils.utf8_len, tok.value)
				count       = count + (ok and len or 1)
				emitted_str = emitted_str .. tok.value
			end
		end

		::continue::
	end

	Logger.done(LOG, "%d token(s) emitted (%d char(s)).", #tokens, count)
	return count, emitted_str, logical_text
end

--- Emits a raw string directly, choosing between keystrokes and clipboard-paste.
--- @param text string The text to emit.
--- @return number, string, string Characters emitted, the physical echo string
---   (empty on paste), and the logical text inserted (always the supplied text).
function M.emit_text(text)
	if type(text) ~= "string" then
		Logger.error(LOG, "emit_text: text must be a string (got %s).", type(text))
		return 0, "", ""
	end

	-- Log the payload's SIZE, never the payload. Every expansion funnels through
	-- here — including personal_info's SSN / IBAN / phone expansions and LLM
	-- completions — and DEBUG is the driver's default level, so echoing `text`
	-- copied user secrets into a log retained 14 days. #text is a byte count
	-- (free); a codepoint count would cost a utf8 scan on the hot path
	Logger.trace(LOG, "Emitting text (%d byte(s))…", #text)

	if M.should_paste(text) then
		perform_paste(text)
		Logger.done(LOG, "Text pasted via clipboard.")
		-- Signal the pending Cmd+V echo to expander via the paste counter, NOT
		-- via expected_synthetic_chars. Returning text as emitted_str would fill
		-- expected_synthetic_chars with text that Cmd+V never echoes back as
		-- individual keystrokes, causing subsequent real keystrokes matching the
		-- expansion prefix to be silently absorbed (paste-synthetic-chars-leak).
		_paste_ops_pending = _paste_ops_pending + 1
		local ok_l, l = pcall(text_utils.utf8_len, text)
		return (ok_l and l or 1), "", text
	end

	keyStrokes(text)
	local ok, len = pcall(text_utils.utf8_len, text)
	Logger.done(LOG, "Text emitted as keystrokes (%d char(s)).", ok and len or 1)
	return (ok and len or 1), text, text
end





-- =================================
-- =================================
-- ======= 3/ Window Ignorer =======
-- =================================
-- =================================

local _ignored_win_cache_time  = 0
local _ignored_win_cache_value = false
-- Cache dirty flag: true when the cached value can no longer be trusted
-- (focus change, first call, or TTL elapsed). Watchers set this to true
-- synchronously whenever the focused window/app is known to have changed.
local _ignored_win_cache_dirty = true
-- Lazy-init singletons for the focus-change watchers. Created on the first
-- is_ignored_window() call so that module load never forces Hammerspoon to
-- spin up the accessibility APIs when they are not needed yet.
local _ignored_win_app_watcher = nil
local _ignored_win_win_filter  = nil

--- Invalidates the ignored-window cache. Called from focus-change watchers;
--- also safe to call from anywhere else (tests, manual overrides).
local function invalidate_ignored_win_cache()
	_ignored_win_cache_dirty = true
end

--- Starts focus-change watchers on first use. Any failure is logged and
--- falls back to the TTL-only cache behavior — the ignored-window logic
--- must never crash the eventtap.
local function ensure_ignored_win_watchers()
	if _ignored_win_app_watcher and _ignored_win_win_filter then return end

	-- Application-level: fires when a different app becomes/leaves frontmost.
	if not _ignored_win_app_watcher then
		local ok, watcher = pcall(function()
			local w = hs.application.watcher.new(function(_name, event, _app)
				if event == hs.application.watcher.activated
					or event == hs.application.watcher.deactivated then
					invalidate_ignored_win_cache()
				end
			end)
			w:start()
			return w
		end)
		if ok and watcher then
			_ignored_win_app_watcher = watcher
			Logger.debug(LOG, "Ignored-window cache: application watcher started.")
		else
			Logger.warn(LOG, "Ignored-window cache: application watcher setup failed — relying on TTL.")
		end
	end

	-- Window-level: fires on intra-app focus changes and title changes (some apps
	-- reuse one window but change its title between contexts we need to re-evaluate).
	if not _ignored_win_win_filter then
		-- hs.window.filter.default enumerates every window on first use; time it so a
		-- slow first-keystroke is attributable in the logs (keylogger-winfilter-lazy).
		local t0 = hs.timer.absoluteTime()
		local ok, filter = pcall(function()
			local f = hs.window.filter.default
			f:subscribe(
				{ hs.window.filter.windowFocused, hs.window.filter.windowTitleChanged },
				invalidate_ignored_win_cache
			)
			return f
		end)
		if ok and filter then
			_ignored_win_win_filter = filter
			Logger.debug(LOG, "Ignored-window cache: window filter subscribed (%.1f ms).",
				(hs.timer.absoluteTime() - t0) / 1e6)
		else
			Logger.warn(LOG, "Ignored-window cache: window filter setup failed — relying on TTL.")
		end
	end
end

--- Returns true when the frontmost window is on the ignore list.
--- The Hammerspoon console check is folded in here so that the single
--- frontmostApplication() call is covered by the cache — previously
--- a redundant uncached call was made in init.lua on every keystroke.
--- Cache invalidation is event-driven (hs.application.watcher +
--- hs.window.filter), with a long TTL as a safety net. In steady state
--- (user typing without switching apps/windows), this function performs
--- zero syscalls.
--- Accepts the current timestamp from the caller so that the
--- secondsSinceEpoch() syscall is not duplicated when init.lua already
--- holds a fresh `now` value.
--- @param ignored_titles table Hash map of exact window titles to ignore.
--- @param ignored_patterns table Array of Lua patterns matched against window titles.
--- @param now number Current epoch timestamp (seconds) from the caller.
--- @return boolean
function M.is_ignored_window(ignored_titles, ignored_patterns, now)
	-- Fallback for callers that don't hold a pre-computed timestamp
	if not now then now = hs.timer.secondsSinceEpoch() end

	-- Lazy-init on first use so module load never pays the watcher startup cost.
	ensure_ignored_win_watchers()

	-- Fast path: cache is clean and TTL has not elapsed.
	local ttl_elapsed = (now - _ignored_win_cache_time) >= IGNORED_WIN_TTL_SEC
	if not _ignored_win_cache_dirty and not ttl_elapsed then
		return _ignored_win_cache_value
	end

	_ignored_win_cache_time  = now
	_ignored_win_cache_dirty = false
	_ignored_win_cache_value = false

	-- Use the focused window directly rather than frontmostApplication() so that
	-- floating-panel apps (e.g. Raycast) that accept keystrokes without becoming
	-- the NSWorkspace frontmost app are evaluated against their own window title,
	-- not the title of the previously active app.
	local ok_win, win = pcall(hs.window.focusedWindow)
	if not ok_win or not win then return false end

	local ok_app, app = pcall(function() return win:application() end)
	if not ok_app or not app then return false end

	-- Always ignore the Hammerspoon console to prevent feedback loops;
	-- folded here so it benefits from the event-driven cache as the rest.
	if app:name() == "Hammerspoon" then
		_ignored_win_cache_value = true
		return true
	end

	local ok_title, title = pcall(function() return win:title() end)
	if not ok_title or type(title) ~= "string" then return false end

	-- Exact-title match.
	if type(ignored_titles) == "table" and ignored_titles[title] then
		Logger.debug(LOG, "Window '%s' ignored (exact match).", title)
		_ignored_win_cache_value = true
		return true
	end

	-- Pattern match.
	if type(ignored_patterns) == "table" then
		for _, pat in ipairs(ignored_patterns) do
			if type(pat) == "string" and title:match(pat) then
				Logger.debug(LOG, "Window '%s' ignored (pattern '%s').", title, pat)
				_ignored_win_cache_value = true
				return true
			end
		end
	end

	return false
end

--- Prewarms the ignored-window watchers OFF the keystroke path.
--- hs.window.filter.default enumerates every open window on first use — a cold
--- cost measured at ~3 s on a busy desktop. When that enumeration is paid lazily
--- inside the FIRST keystroke (is_ignored_window → ensure_ignored_win_watchers),
--- it blocks the keyDown event tap long enough for macOS to disable the tap
--- ("macOS disabled the keyDown event tap — re-enabling"), dropping that
--- keystroke. Calling this from a deferred boot timer pays the enumeration on a
--- timer callback instead, so the first real keystroke is already warm.
--- Safe to call repeatedly: ensure_ignored_win_watchers() is idempotent.
function M.prewarm_ignored_win_watchers()
	Logger.start(LOG, "Prewarming ignored-window watchers off the keystroke path…")
	local t0 = hs.timer.absoluteTime()
	ensure_ignored_win_watchers()
	Logger.success(LOG, "Ignored-window watchers prewarmed (%.1f ms).",
		(hs.timer.absoluteTime() - t0) / 1e6)
end

--- Stops the ignored-window watchers and unsubscribes from the window filter.
--- Must be called from keymap/init.lua M.stop() to prevent callbacks from firing
--- after the module is unloaded (watcher-leak-on-reload).
function M.stop()
	if _ignored_win_app_watcher then
		pcall(function() _ignored_win_app_watcher:stop() end)
		_ignored_win_app_watcher = nil
		Logger.debug(LOG, "Ignored-window cache: application watcher stopped.")
	end
	if _ignored_win_win_filter then
		pcall(function()
			_ignored_win_win_filter:unsubscribe(invalidate_ignored_win_cache)
		end)
		_ignored_win_win_filter = nil
		Logger.debug(LOG, "Ignored-window cache: window filter unsubscribed.")
	end
	_ignored_win_cache_dirty = true
end

return M
