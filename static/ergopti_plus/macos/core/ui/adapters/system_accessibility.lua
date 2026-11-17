--- core/ui/adapters/system_accessibility.lua

--- ==============================================================================
--- MODULE: System Accessibility Settings and Announcements (macOS)
--- DESCRIPTION:
--- Reads the display settings macOS exposes to applications (Reduce motion,
--- Reduce transparency, Increase contrast: NSWorkspace accessibilityDisplay*,
--- through hs.screen.accessibilitySettings) and speaks a short text through
--- VoiceOver when VoiceOver runs.
---
--- FEATURES & RATIONALE:
--- 1. hs.canvas windows are invisible to VoiceOver: the hotstring and AI
---    previews were never read. Announcing them is tied to VoiceOver itself
---    (decided 2026-11-17, no setting of its own): when it does not run,
---    nothing is spoken; when it does, the preview goes through VoiceOver's
---    own voice (its AppleScript « output » command), never a second voice.
---    VoiceOver Utility's « Allow VoiceOver to be controlled with AppleScript »
---    is the system's own consent: a refusal is reported once, never retried
---    in a loop.
--- 2. The same text is spoken once: a preview redrawn for every keystroke
---    that leaves it unchanged would otherwise repeat it.
--- 3. The settings are read at most once a second: a preview is drawn on a
---    keystroke, and each read is a round of NSWorkspace calls.
--- ==============================================================================

local M = {}

local hs          = hs
local Logger      = require("core.logger.engine.logger")
local ShellRunner = require("core.process.adapters.shell_runner")
local Timings     = require("core.timing.engine.timings")

local LOG = "system_accessibility"

-- VoiceOver's bundle identifier: it runs as its own application.
local VOICEOVER_BUNDLE_ID = "com.apple.VoiceOver"

-- How long a settings read stays valid, in seconds.
local SETTINGS_TTL_SECONDS = Timings.sec("tooltip", "accessibility_settings_ttl_ms")

local _settings, _settings_at = nil, nil
local _settings_refusal_reported = false
local _last_announced = nil
local _announce_refusal_reported = false





-- ===================================
-- ===================================
-- ======= 1/ Display Settings =======
-- ===================================
-- ===================================

--- The system's display accessibility settings.
--- @param now number|nil Current time in seconds (test seam), os.time() by default.
--- @return table { reduce_motion, reduce_transparency, increase_contrast } booleans.
function M.display_settings(now)
	now = now or os.time()
	if _settings and _settings_at and now - _settings_at < SETTINGS_TTL_SECONDS then return _settings end
	local ok, raw = pcall(function() return hs.screen.accessibilitySettings() end)
	if not ok or type(raw) ~= "table" then
		if not _settings_refusal_reported then
			_settings_refusal_reported = true
			Logger.warn(LOG, "The system accessibility settings could not be read (%s) — drawn as if all were off.",
				tostring(raw))
		end
		raw = {}
	end
	_settings = {
		reduce_motion       = raw.ReduceMotion == true,
		reduce_transparency = raw.ReduceTransparency == true,
		increase_contrast   = raw.IncreaseContrast == true,
	}
	_settings_at = now
	return _settings
end

--- Whether a surface should be drawn opaque: Reduce transparency or Increase
--- contrast asks for it, as the system's own panels do.
--- @param now number|nil Test seam, see display_settings.
--- @return boolean
function M.wants_opaque(now)
	local settings = M.display_settings(now)
	return settings.reduce_transparency or settings.increase_contrast
end





-- ===================================
-- ===================================
-- ======= 2/ Announcements ==========
-- ===================================
-- ===================================

--- Whether VoiceOver runs now.
--- @return boolean
function M.screen_reader_running()
	local ok, apps = pcall(function() return hs.application.applicationsForBundleID(VOICEOVER_BUNDLE_ID) end)
	return ok and type(apps) == "table" and #apps > 0
end

--- The AppleScript that makes VoiceOver speak a text.
--- @param text string
--- @return string
function M.voiceover_script(text)
	local escaped = text:gsub("[\r\n]+", " "):gsub("\\", "\\\\"):gsub('"', '\\"')
	return 'tell application "VoiceOver" to output "' .. escaped .. '"'
end

--- Speaks a text through VoiceOver when it runs; does nothing otherwise.
--- @param text string|nil The plain text; nil or "" forgets the last one.
--- @return boolean announced True when the text was handed to VoiceOver.
function M.announce(text)
	if type(text) ~= "string" or text:match("^%s*$") then
		_last_announced = nil
		return false
	end
	if text == _last_announced then return false end
	if not M.screen_reader_running() then return false end
	_last_announced = text
	local started = ShellRunner.applescript(M.voiceover_script(text), function(ok)
		if ok or _announce_refusal_reported then return end
		_announce_refusal_reported = true
		Logger.warn(LOG, "VoiceOver refused the announcement: allow it to be controlled with AppleScript "
			.. "in VoiceOver Utility to hear the previews.")
	end)
	return started == true
end

--- Forgets the last announcement, so the same text is spoken again when it
--- comes back after the preview was hidden.
function M.forget_announcement()
	_last_announced = nil
end

return M
