--- modules/keymap/utils.lua

--- ==============================================================================
--- MODULE: Keymap Utilities (Hammerspoon adapter)
--- DESCRIPTION:
--- Hammerspoon-specific keymap helpers layered on top of the shared pure-Lua
--- core from drivers/_shared/lua/keymap/utils.lua. Adds OS-level text emission
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

local LOG = "keymap.utils"

-- Re-export pure-Lua functions from the shared module so callers that require
-- this HS adapter keep working unchanged without needing to know about the split.
M.tokens_from_repl          = shared_utils.tokens_from_repl
M.plain_text                = shared_utils.plain_text
M.resolve_prediction_overlap = shared_utils.resolve_prediction_overlap




-- ====================================
--- ====================================
-- ======= 1/ Constants & State =======
--- ====================================
-- ====================================

-- Threshold (in UTF-8 characters) above which clipboard-paste is used instead of
-- simulated keystrokes. Pasting is faster and avoids issues with long strings.
local PASTE_THRESHOLD = 50

-- How long the clipboard is left with the pasted value before restoring the
-- user's previous contents. Large enough to let the target app receive the paste.
local CLIPBOARD_RESTORE_SEC = 0.15

-- Safety TTL (seconds) for the ignored-window cache. The cache is normally
-- invalidated on focus-change events (hs.application.watcher + hs.window.filter),
-- so this long TTL only acts as a net in the unlikely case the watcher misses an
-- event. Keeping it large means near-zero syscalls per keystroke in steady state.
local IGNORED_WIN_TTL_SEC = 5.0




-- ==========================================
--- ==========================================
-- ======= 2/ Text Emission Utilities =======
--- ==========================================
-- ==========================================

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

--- Emits a sequence of tokens by simulating keystrokes or pasting via the clipboard.
--- @param tokens table The token list produced by tokens_from_repl().
--- @return number, string Total characters emitted and the concatenated plain-text portion.
function M.emit_tokens(tokens)
	if type(tokens) ~= "table" then
		Logger.error(LOG, "emit_tokens: tokens must be a table (got %s).", type(tokens))
		return 0, ""
	end

	Logger.trace(LOG, "Emitting %d token(s)…", #tokens)
	local count       = 0
	local emitted_str = ""

	for _, tok in ipairs(tokens) do
		if type(tok) ~= "table" then goto continue end

		if tok.kind == "key" then
			keyStroke({}, tok.value, 0)
			count = count + 1

		elseif tok.kind == "text" then
			if M.should_paste(tok.value) then
				local prev = hs.pasteboard.getContents()
				hs.pasteboard.setContents(tok.value)
				keyStroke({ "cmd" }, "v", 0)
				count = count + 1
				-- Restore clipboard asynchronously after the target app has received the paste.
				hs.timer.doAfter(CLIPBOARD_RESTORE_SEC, function()
					pcall(hs.pasteboard.setContents, prev or "")
				end)
			else
				keyStrokes(tok.value)
				local ok, len = pcall(text_utils.utf8_len, tok.value)
				count       = count + (ok and len or 1)
				emitted_str = emitted_str .. tok.value
			end
		end

		::continue::
	end

	Logger.done(LOG, "%d token(s) emitted (%d char(s)).", #tokens, count)
	return count, emitted_str
end

--- Emits a raw string directly, choosing between keystrokes and clipboard-paste.
--- @param text string The text to emit.
--- @return number, string Characters emitted and the emitted string (empty on paste).
function M.emit_text(text)
	if type(text) ~= "string" then
		Logger.error(LOG, "emit_text: text must be a string (got %s).", type(text))
		return 0, ""
	end

	Logger.trace(LOG, "Emitting text ('%s')…", text)

	if M.should_paste(text) then
		local prev = hs.pasteboard.getContents()
		hs.pasteboard.setContents(text)
		keyStroke({ "cmd" }, "v", 0)
		hs.timer.doAfter(CLIPBOARD_RESTORE_SEC, function()
			pcall(hs.pasteboard.setContents, prev or "")
		end)
		Logger.done(LOG, "Text pasted via clipboard.")
		-- Pasted text is not tracked character-by-character, so return (1, "").
		return 1, ""
	end

	keyStrokes(text)
	local ok, len = pcall(text_utils.utf8_len, text)
	Logger.done(LOG, "Text emitted as keystrokes (%d char(s)).", ok and len or 1)
	return (ok and len or 1), text
end




-- =================================
--- =================================
-- ======= 3/ Window Ignorer =======
--- =================================
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
			Logger.debug(LOG, "Ignored-window cache: window filter subscribed.")
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

return M
