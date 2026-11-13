--- ui/proxy_override.lua

--- ==============================================================================
--- MODULE: Proxy Override Row (Linux)
--- DESCRIPTION:
--- Debug > proxy for downloads: runs the shared edit flow
--- (core/network/engine/proxy_override.lua) over this driver's dialogs and settings store.
--- The proxy policy binding (infra/proxy_policy.lua) reads the stored value at
--- every route decision, so a change applies to the next download.
--- ==============================================================================

local M = {}

local Dialogs = require("ui.menu.menu_dialogs")
local I18n = require("infra.i18n")
local Logger = require("core.logger.engine.shim")
local Storage = require("core.fs.adapters.storage")
local Binding = require("infra.proxy_policy")
local Override = require("core.network.engine.proxy_override")

local LOG = "ui.proxy_override"

--- Opens the dialog and stores a valid answer.
--- @return boolean saved
function M.run()
	local setting, err = Binding.override_setting()
	if not setting then
		Logger.error(LOG, "The proxy override row cannot open: %s.", tostring(err))
		return false
	end
	local receipt
	return Override.edit(setting, {
		get = function(key)
			local value
			value, receipt = Storage.capture_string_edit(key)
			return value, receipt ~= nil
		end,
		set = function(_, value) return Storage.commit_string_edit(receipt, value) end,
		prompt = function(title, text, initial) return Dialogs.prompt_text(title, text, initial) end,
		error = function(title, text) Dialogs.show_error(text, title) end,
		info = function(title, text) Dialogs.show_info(title, text) end,
		t = function(key) return I18n.get(key) end,
		log = function(level, message, ...) Logger[level](LOG, message, ...) end,
	})
end

return M
