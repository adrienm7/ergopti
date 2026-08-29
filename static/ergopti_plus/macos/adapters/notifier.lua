--- adapters/notifier.lua

--- ==============================================================================
--- MODULE: Notifier Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the Notifier port contract defined in
--- static/ergopti_plus/_shared/core/ports/Notifier.spec.js. Wraps hs.notify to deliver
--- system-level notifications without coupling domain modules to the hs API.
---
--- FEATURES & RATIONALE:
--- 1. Kind-to-icon mapping: the optional "kind" field (info, warn, error) maps
---    to a notification subtitle so callers communicate urgency without OS-level
---    icon knowledge.
--- 2. Auto-release: each notification is released immediately after send() to
---    prevent memory growth in long-running sessions.
--- 3. Exact dispatch result: hs.notify reports revoked notification permission
---    by returning false rather than throwing. The adapter checks both outcomes,
---    logs the refusal, and returns an explicit boolean to the caller.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("infra.logger")

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
--- @return boolean accepted True only when hs.notify accepted the notification.
function M.send(title, opts)
	local options  = type(opts) == "table" and opts or {}
	local body     = type(options.body) == "string" and options.body or ""
	local kind     = type(options.kind) == "string" and options.kind or "info"
	local subtitle = KIND_SUBTITLES[kind] or ""

	local ok, accepted_or_err = pcall(function()
		local note = hs.notify.new({
			title        = title,
			informativeText = body,
			subTitle     = subtitle,
		})
		local accepted = note:send()
		note:release()
		return accepted == note
	end)

	if not ok then
		Logger.error(LOG, "send(): hs.notify failed: %s.", tostring(accepted_or_err))
		return false
	end
	if accepted_or_err ~= true then
		Logger.error(LOG, "send(): hs.notify refused delivery.")
		return false
	end
	return true
end

return M
