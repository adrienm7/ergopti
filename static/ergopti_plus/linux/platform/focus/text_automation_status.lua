--- platform/focus/text_automation_status.lua

--- ==============================================================================
--- MODULE: Text Automation Status (Linux)
--- DESCRIPTION:
--- Publishes the focus guard's text automation mode to the readers that must
--- show it: the log, the diagnostics page and the tray. Every withholding used
--- to be silent: a desktop whose windows were not on the accessibility bus
--- withheld every hotstring with no error, no log line and no menu row.
---
--- FEATURES & RATIONALE:
--- 1. One owner binds: the daemon's focus guard, once; a second bind is a bug.
--- 2. Only lasting conditions reach the tray: one reason must hold for
---    NOTICE_AFTER_MS. A focus change passes through a short window mode on a
---    desktop that works, and a tray rebuild costs hundreds of milliseconds.
--- 3. The tray row is core.ui.engine.component_status's red row, shown while
---    its condition holds. No notification: hotstrings still expand in the
---    window mode, and a notice for every desktop without AT-SPI would be noise.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local Monotonic = require("core.logger.engine.monotonic")
local Timings = require("core.timing.engine.timings")

local LOG = "platform.focus.text_automation_status"

-- How long one window-mode reason must hold before the tray names it
-- (constants.toml [privacy]).
local NOTICE_AFTER_MS = Timings.ms("privacy", "text_automation_notice_after_ms")

-- The lasting reasons the tray names, by mode: "window" ones leave hotstrings
-- on without the password-field check, "closed" ones withhold them all. The
-- transient ones (a context still joining, a verdict not yet read, a password
-- field, a protected window) are left out: they hold for a moment, or by design.
M.NOTICES = {
	atspi_unavailable    = { mode = "window", label = "startup.linux_text_unchecked_label",
		body = "startup.linux_text_reason_atspi_unavailable" },
	no_accessible_window = { mode = "window", label = "startup.linux_text_unchecked_label",
		body = "startup.linux_text_reason_no_accessible_window" },
	no_focus_answer      = { mode = "window", label = "startup.linux_text_unchecked_label",
		body = "startup.linux_text_reason_no_focus_answer" },
	context_unavailable  = { mode = "window", label = "startup.linux_text_unchecked_label",
		body = "startup.linux_text_reason_context_unavailable" },
	no_detector          = { mode = "closed", label = "startup.linux_text_closed_label",
		body = "startup.linux_text_reason_no_detector" },
	window_policy_failed = { mode = "closed", label = "startup.linux_text_closed_label",
		body = "startup.linux_text_reason_window_policy_failed" },
}

-- What the tray says of each reason GNOME Shell sends no focus report
-- (compositor_focus.extension_problem): what to do differs for each.
M.EXTENSION_BODIES = {
	absent = "startup.linux_gnome_extension_body_absent",
	inactive = "startup.linux_gnome_extension_body_inactive",
	out_of_date = "startup.linux_gnome_extension_body_out_of_date",
	error = "startup.linux_gnome_extension_body_error",
	silent = "startup.linux_gnome_extension_body_silent",
}

-- What the log says, once per reason and session, when the window mode first
-- admits text for it. Developer text: the tray row carries the localized one.
local LOG_HINTS = {
	atspi_unavailable = "the accessibility focus worker is not running (is at-spi2-core installed?)",
	no_accessible_window = "the focused window belongs to no application of the accessibility bus",
	no_focus_answer = "the accessibility bus answers no focus query in time or ambiguously",
	context_pending = "the focused field's application is still being identified",
	context_unavailable = "the focused field's application could not be identified",
	field_unknown = "the focused field has no verdict yet",
	no_detector = "the password-field detector could not load",
	window_policy_failed = "the password-app and private-window check of the focused window failed",
}

local _state_reader = nil
local _accessibility_reader = nil
local _mode, _reason, _since_ms = nil, nil, nil
local _logged = {}
local _noticed = {}
-- Whether the GNOME extension's row was shown at the last check, so a
-- recovery (or a relapse) redraws the tray once.
local _extension_visible = false
local _listener = nil
local _status = nil
local _say = nil




-- ====================================
-- ====================================
-- ======= 1/ Ownership ===============
-- ====================================
-- ====================================

--- Binds the daemon's focus guard as the one source of the state.
--- @param state_reader function () -> { mode, reason }.
--- @param accessibility_reader function|nil () -> the accessibility switch state.
function M.bind(state_reader, accessibility_reader)
	assert(_state_reader == nil, "text automation status already bound")
	assert(type(state_reader) == "function", "text automation status needs a state reader")
	assert(accessibility_reader == nil or type(accessibility_reader) == "function",
		"text automation status accessibility reader must be a function")
	_state_reader, _accessibility_reader = state_reader, accessibility_reader
end

--- Replaces the component status owner and the i18n reader (test seam).
--- @param status table|nil core.ui.engine.component_status or a double.
--- @param say function|nil key -> text.
function M._set_dependencies_for_test(status, say)
	_status, _say = status, say
end

--- Sets the one callback told when the tray must show a new condition.
--- @param listener function|nil
function M.set_notice_listener(listener)
	assert(listener == nil or type(listener) == "function", "text automation notice listener must be a function")
	_listener = listener
end




-- ====================================
-- ====================================
-- ======= 2/ Publication =============
-- ====================================
-- ====================================

--- Records a mode change from the focus guard.
--- @param mode string "field", "window" or "closed".
--- @param reason string The guard's reason.
function M.publish(mode, reason)
	-- The guard publishes changes only; a repeat keeps the condition's age.
	if mode == _mode and reason == _reason then return end
	_mode, _reason, _since_ms = mode, reason, Monotonic.now_ms()
	Logger.debug(LOG, "Text automation %s (%s).", tostring(mode), tostring(reason))
	if mode == "window" and not _logged[reason] then
		_logged[reason] = true
		Logger.warn(LOG, "Hotstrings expand without a password-field check: %s. "
			.. "The password-app list still applies; metrics and AI stay closed in such windows.",
			LOG_HINTS[reason] or tostring(reason))
	elseif mode == "closed" and M.NOTICES[reason] and not _logged[reason] then
		_logged[reason] = true
		Logger.warn(LOG, "Hotstrings are withheld everywhere: %s.", LOG_HINTS[reason] or tostring(reason))
	end
end

--- Reads one translated text, the key itself when i18n is unavailable.
--- @param key string
--- @return string
local function say(key)
	if _say then return _say(key) end
	local loaded, i18n = pcall(require, "core.i18n.engine.i18n")
	if not loaded then return key end
	local ok, value = pcall(i18n.get, key)
	return ok and type(value) == "string" and value or key
end

--- Names a lasting condition once it has held long enough: a red tray row
--- (component_status) shown while the guard still reports it.
--- Called from the daemon's periodic loop, off the input path.
--- @param now_ms number|nil Monotonic milliseconds (a test seam).
--- @return boolean noticed True when the tray must be rebuilt.
function M.tick(now_ms)
	local notice = _reason and M.NOTICES[_reason]
	if not notice or notice.mode ~= _mode or _noticed[_reason] then return false end
	local now = now_ms or Monotonic.now_ms()
	if now - _since_ms < NOTICE_AFTER_MS then return false end
	local reason = _reason
	_noticed[reason] = true
	local status = _status or require("core.ui.engine.component_status")
	local label = say(notice.label)
	status.report({
		code = "text_automation_" .. reason,
		label = label,
		title = label,
		body = say(notice.body),
		active = function() return _mode == notice.mode and _reason == reason end,
	})
	if _listener then _listener() end
	return true
end


--- Names a KWin that does not run the Ergopti focus script: the focused
--- application then stays unknown, so the password-app list and the
--- per-application rules cannot judge it (field report, Plasma 6.8 Wayland,
--- 2026-11-25: the script was enabled but never loaded, in silence).
--- @param script_state string|nil window_info.compositor_script_state().
--- @return boolean noticed True when the tray must be rebuilt.
function M.check_desktop_focus(script_state)
	if script_state ~= "not_loaded" and script_state ~= "unanswered" then return false end
	if _noticed.kwin_focus_script then return false end
	_noticed.kwin_focus_script = true
	local status = _status or require("core.ui.engine.component_status")
	local label = say("startup.linux_kwin_script_label")
	status.report({
		code = "kwin_focus_script",
		label = label,
		title = label,
		body = say("startup.linux_kwin_script_body"),
	})
	if _listener then _listener() end
	return true
end
--- Names a GNOME Shell that sends no focus report because the Ergopti
--- extension is missing, disabled, out of date, failed or stale: the focused
--- application then stays unknown, and the layout switch has no one to ask.
--- The red row holds while the reader names a problem and leaves the tray
--- once reports arrive.
--- @param reader function () -> window_info.compositor_extension_problem().
--- @return boolean changed True when the tray must be rebuilt.
function M.check_focus_extension(reader)
	assert(type(reader) == "function", "the focus extension check needs a problem reader")
	local problem = reader()
	local visible = problem ~= nil
	if not _noticed.gnome_focus_extension then
		if not visible then return false end
		local body = M.EXTENSION_BODIES[problem]
		assert(body, "unknown focus extension problem " .. tostring(problem))
		_noticed.gnome_focus_extension = true
		local status = _status or require("core.ui.engine.component_status")
		local label = say("startup.linux_gnome_extension_label")
		status.report({
			code = "gnome_focus_extension",
			label = label,
			title = label,
			body = say(body),
			active = function() return reader() ~= nil end,
		})
	elseif visible == _extension_visible then
		return false
	end
	_extension_visible = visible
	if _listener then _listener() end
	return true
end




-- ====================================
-- ====================================
-- ======= 3/ Readers =================
-- ====================================
-- ====================================

--- The current state for the diagnostics page: "open" when hotstrings may
--- expand in the focused window (with the field check, or in the window mode),
--- "closed" otherwise, and the guard's reason.
--- @return string|nil state "open" or "closed", nil when unbound.
--- @return string|nil reason The guard's reason token.
function M.summary()
	if not _state_reader then return nil end
	local state = _state_reader()
	if type(state) ~= "table" or type(state.mode) ~= "string" then return nil end
	local word = (state.mode == "field" or state.mode == "window") and "open" or "closed"
	return word, tostring(state.reason)
end

--- The guard's mode and reason as it holds them, for the field run's session
--- check: "field" (a checked text field), "window" (the window mode) or
--- "closed", and the reason token.
--- @return string|nil mode nil when unbound.
--- @return string|nil reason
function M.mode()
	if not _state_reader then return nil end
	local state = _state_reader()
	if type(state) ~= "table" or type(state.mode) ~= "string" then return nil end
	return state.mode, tostring(state.reason)
end

--- The session's accessibility switch as the focus worker found it.
--- @return string|nil
function M.accessibility()
	return _accessibility_reader and _accessibility_reader() or nil
end

--- Test seam: forgets every binding and observation.
function M._reset_for_test()
	_state_reader, _accessibility_reader, _listener = nil, nil, nil
	_mode, _reason, _since_ms, _noticed = nil, nil, nil, {}
	_extension_visible = false
	_logged, _status, _say = {}, nil, nil
end

return M
