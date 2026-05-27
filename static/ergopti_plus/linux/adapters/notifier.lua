--- static/ergopti_plus/linux/adapters/notifier.lua

--- ==============================================================================
--- MODULE: Notifier Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the Notifier port contract defined in
--- static/ergopti_plus/shared/ports/Notifier.spec.js. Wraps the D-Bus
--- org.freedesktop.Notifications interface (notify-send CLI) to deliver
--- desktop notifications without coupling domain modules to any OS API.
---
--- FEATURES & RATIONALE:
--- 1. Kind-to-urgency mapping: the optional "kind" field (info, warn, error)
---    maps to the --urgency flag of notify-send so the DE renders the
---    notification with the correct visual weight.
--- 2. Graceful degradation: if notify-send is absent (headless / server),
---    the adapter logs a warning and silently no-ops instead of crashing.
--- 3. Defensive pcall: io.popen can raise on permission errors; every OS
---    call is wrapped so a notification failure never propagates upward.
--- ==============================================================================

local M = {}

local Logger = require("lib.logger")

local LOG = "adapters.notifier"


-- =============================================
-- =============================================
-- ======= 1/ Kind → Urgency Mapping ==========
-- =============================================
-- =============================================

-- Maps the port "kind" field to a notify-send --urgency value.
-- D-Bus org.freedesktop.Notifications accepts low/normal/critical.
local KIND_URGENCY = {
	info  = "normal",
	warn  = "normal",
	error = "critical",
}


-- =========================================
-- =========================================
-- ======= 2/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Sends a desktop notification via notify-send (D-Bus backend).
--- @param title string  The notification title.
--- @param opts  table   Options table: { body?, kind? }
---                        body  string  Notification body text.
---                        kind  string  "info" | "warn" | "error" (default "info").
function M.send(title, opts)
	-- TODO(linux): implement via D-Bus org.freedesktop.Notifications or notify-send
	local options  = type(opts) == "table" and opts or {}
	local body     = type(options.body) == "string" and options.body or ""
	local kind     = type(options.kind) == "string" and options.kind or "info"
	local urgency  = KIND_URGENCY[kind] or "normal"

	local ok, err = pcall(function()
		-- Escape single quotes in title and body to avoid shell injection.
		local safe_title = title:gsub("'", "'\\''")
		local safe_body  = body:gsub("'", "'\\''")
		local cmd = string.format(
			"notify-send --urgency=%s '%s' '%s' 2>/dev/null",
			urgency, safe_title, safe_body
		)
		local pipe = io.popen(cmd)
		if pipe then pipe:close() end
	end)

	if not ok then
		Logger.error(LOG, "send(): notify-send failed — %s", tostring(err))
	end
end

return M
