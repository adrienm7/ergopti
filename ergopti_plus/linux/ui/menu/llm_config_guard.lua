--- ui/menu/llm_config_guard.lua

--- ==============================================================================
--- MODULE: AI Menu Configuration Guard (Linux binding)
--- DESCRIPTION:
--- Binds the shared AI configuration guard (_shared/lua/llm/config_guard.lua)
--- to this driver's provider rows (`action`, `items`), its logger and its
--- config.toml path, and greys the rows that write the file with the cause.
---
--- FEATURES & RATIONALE:
--- 1. The profile parent and the inline model/API list write config.toml, so
---    they name the same cause as the switch: « Saved by a newer version »
---    for a newer file, the generic « unavailable » for any other refusal.
--- 2. A retained row rechecks at click time: a tray menu stays on screen while
---    a reload can read a newer file, and the click must not write over it.
--- ==============================================================================

local Shared = require("llm.config_guard")
local Logger = require("logger.shim")

local LOG = "ui.menu.llm_config_guard"

local M = {}

local DIALECT = {
	action = "action",
	children = "items",
	refused = function(reason) Logger.warn(LOG, "AI settings click refused: %s.", reason) end,
}

--- The locale key naming why config.toml cannot be written now, or nil.
--- @return string|nil reason_key
function M.reason()
	return Shared.reason_key(require("infra.config_paths").config("config.toml"), require("config_migrate"))
end

--- Wraps every action of a provider tree, in place, so a click asks again.
--- @param rows table|nil Provider rows ({ label, action, items, ... }).
function M.protect(rows)
	Shared.protect(rows, M.reason, DIALECT)
end

--- Greys the actionable rows of an inline list when the file refuses writes,
--- and puts one inert row naming the cause first. Separators and inert rows
--- keep their shape.
--- @param rows table Provider rows, edited in place.
--- @param reason_key string|nil Cause from M.reason(), nil when writable.
--- @param label string Translated cause, shown on the leading inert row.
function M.grey_list(rows, reason_key, label)
	if reason_key == nil then return end
	for _, row in ipairs(rows) do
		if type(row) == "table" and not row.separator and (row.action ~= nil or row.items ~= nil) then
			row.disabled = true
		end
	end
	table.insert(rows, 1, { label = label, disabled = true })
end

return M
