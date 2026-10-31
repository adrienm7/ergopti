--- ui/proxy_override.lua

--- ==============================================================================
--- MODULE: Proxy Override Row (Linux)
--- DESCRIPTION:
--- Debug > proxy for downloads: runs the shared edit flow
--- (network/proxy_override.lua) over this driver's dialogs and settings store.
--- The proxy policy binding (infra/proxy_policy.lua) reads the stored value at
--- every route decision, so a change applies to the next download.
--- ==============================================================================

local M = {}

local Dialogs = require("ui.menu.menu_dialogs")
local I18n = require("infra.i18n")
local Logger = require("logger.shim")
local Storage = require("adapters.storage")
local Binding = require("infra.proxy_policy")
local Override = require("network.proxy_override")

local LOG = "ui.proxy_override"

--- Opens the dialog and stores a valid answer.
--- @return boolean saved
function M.run()
	local setting, err = Binding.override_setting()
	if not setting then
		Logger.error(LOG, "The proxy override row cannot open: %s.", tostring(err))
		return false
	end
	return Override.edit(setting, {
		get = function(key) return Storage.get(key, nil) end,
		set = Storage.set,
		prompt = function(title, text, initial) return Dialogs.prompt_text(title, text, initial) end,
		error = function(title, text) Dialogs.show_error(text, title) end,
		info = function(title, text) Dialogs.show_info(title, text) end,
		t = function(key) return I18n.get(key) end,
		log = function(level, message, ...) Logger[level](LOG, message, ...) end,
	})
end

return M
