--- ui/menu/menu_llm/config_guard.lua

--- ==============================================================================
--- MODULE: AI Menu Configuration Guard (macOS binding)
--- DESCRIPTION:
--- Binds the shared AI configuration guard (_shared/lua/llm/config_guard.lua)
--- to this driver's native row fields (`fn`, `menu`) and logger. The rule
--- itself, one cause per state and rechecked retained clicks, lives there.
--- ==============================================================================

local Shared = require("llm.config_guard")
local Logger = require("infra.logger")

local LOG = "ui.menu.menu_llm.config_guard"

local M = {}

M.NEWER_REASON_KEY = Shared.NEWER_REASON_KEY
M.GENERIC_REASON_KEY = Shared.GENERIC_REASON_KEY
M.reason_key = Shared.reason_key

local DIALECT = {
	action = "fn",
	children = "menu",
	refused = function(reason) Logger.warn(LOG, "AI settings click refused: %s.", reason) end,
}

--- Wraps every action of a native menu tree, in place.
--- @param items table|nil Native items ({ title, fn, menu, ... }).
--- @param current_reason function Returns the current reason key, or nil when writable.
function M.protect(items, current_reason)
	Shared.protect(items, current_reason, DIALECT)
end

return M
