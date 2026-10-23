--- ui/field_check/init.lua

--- ==============================================================================
--- MODULE: Field Check Window
--- DESCRIPTION:
--- The Debug menu's one-click Mac checks: a click runs the check
--- (infra/field_check.lua over the real ports), writes the evidence line to the
--- log and shows the result, one line per step, with a « Copy report » button.
---
--- FEATURES & RATIONALE:
--- 1. One click, no arguments: the menu row names the check; nothing else is
---    asked of the user. The key accounting check says once, in a
---    notification, that it watches the keyboard, and that it keeps counts only.
--- 2. The same text goes to the window and the clipboard, built from the same
---    privacy-safe result as the log line.
--- 3. Localized: every sentence comes from the locales; step values are raw
---    tokens (counts, states, versions).
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local I18n = require("infra.i18n")
local Engine = require("infra.field_check")

local LOG = "ui.field_check"

--- Menu row id → check identity and window title key.
M.ROWS = {
	field_check_lease = { check = "lease", title = "menu.debug.field_check_lease" },
	field_check_owned_runtime = { check = "owned_runtime", title = "menu.debug.field_check_owned_runtime" },
	field_check_network = { check = "network", title = "menu.debug.field_check_network" },
	field_check_key_accounting = { check = "key_accounting", title = "menu.debug.field_check_key_accounting", watches_keys = true },
}

--- Native services, replaceable by tests.
local function native()
	return {
		ports = function() return require("adapters.field_check_ports").new() end,
		notify = function(title, body, kind)
			return require("adapters.application_notifier").send(title, { body = body, kind = kind })
		end,
		alert = function(...) return require("infra.dialog_util").block_alert(...) end,
		copy = function(text) return hs.pasteboard.setContents(text) end,
		after = function(seconds, fn) return require("adapters.timer_scheduler").after(seconds, fn) end,
	}
end

--- Runs the check of a Debug menu row.
--- @param row_id string A key of M.ROWS.
--- @param services table|nil Test doubles for native services.
--- @return boolean started
function M.run(row_id, services)
	local row = M.ROWS[row_id]
	assert(row ~= nil, "field check: unknown menu row " .. tostring(row_id))
	local env = services or native()
	if Engine.is_running() then
		env.notify(I18n.get(row.title), I18n.get("field_check.busy"), "warn")
		return false
	end
	if row.watches_keys then
		env.notify(I18n.get(row.title), I18n.get("field_check.keys_prompt"), "info")
	end
	return Engine.run(row.check, env.ports(), function(result)
		local text = Engine.format_text(result, I18n.get)
		-- A modal dialog is shown from a fresh turn, not from the port callback.
		env.after(0.05, function()
			local copy_label, close_label = I18n.get("field_check.copy"), I18n.get("field_check.close")
			local clicked = env.alert(I18n.get(row.title), text, copy_label, close_label)
			if clicked == copy_label then
				local ok = env.copy(text)
				Logger.info(LOG, "Report copy %s.", ok and "done" or "refused")
				if ok then env.notify(I18n.get(row.title), I18n.get("field_check.copied"), "info") end
			end
		end)
	end)
end

return M
