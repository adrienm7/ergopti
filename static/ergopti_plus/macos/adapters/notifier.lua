--- adapters/notifier.lua

--- ==============================================================================
--- MODULE: Notifier Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the Notifier port contract defined in
--- static/ergopti_plus/shared/ports/Notifier.spec.js. Wraps hs.notify to deliver
--- system-level notifications without coupling domain modules to the hs API.
---
--- FEATURES & RATIONALE:
--- 1. Kind-to-icon mapping: the optional "kind" field (info, warn, error) maps
---    to a notification subtitle so callers communicate urgency without OS-level
---    icon knowledge.
--- 2. Auto-release: each notification is released immediately after send() to
---    prevent memory growth in long-running sessions.
--- 3. Defensive pcall: hs.notify can silently fail when notification permissions
---    are revoked; the adapter logs the error instead of propagating it.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")

local LOG = "adapters.notifier"


-- ===========================================
-- ===========================================
-- ======= 1/ Kind → Subtitle Mapping ========
-- ===========================================
-- ===========================================

-- Human-readable subtitle injected as the notification subtitle so the urgency
-- level is visible even when the OS groups multiple notifications together.
local KIND_SUBTITLES = {
	info  = "",
	warn  = "⚠️",
	error = "🔴 Erreur",
}


-- =========================================
-- =========================================
-- ======= 2/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Sends a system notification with an optional urgency kind.
--- @param title string  The notification title (bold text on macOS).
--- @param opts  table   Options table: { body?, kind? }
---                        body  string  Notification body text.
---                        kind  string  "info" | "warn" | "error" (default "info").
function M.send(title, opts)
	local options  = type(opts) == "table" and opts or {}
	local body     = type(options.body) == "string" and options.body or ""
	local kind     = type(options.kind) == "string" and options.kind or "info"
	local subtitle = KIND_SUBTITLES[kind] or ""

	local ok, err = pcall(function()
		local note = hs.notify.new({
			title        = title,
			informativeText = body,
			subTitle     = subtitle,
		})
		note:send()
		note:release()
	end)

	if not ok then
		Logger.error(LOG, "send(): hs.notify failed — %s", tostring(err))
	end
end

return M
