--- core/network/proxy_override.lua

--- ==============================================================================
--- MODULE: Proxy Override Row (macOS)
--- DESCRIPTION:
--- Debug > proxy for downloads: runs the shared edit flow
--- (core/network/engine/proxy_override.lua) over this driver's dialogs and settings store.
--- The download preludes (modules/llm/network_env.lua) read the stored value
--- each time a download starts, so a change applies to the next download.
--- ==============================================================================

local M = {}

local Dialog = require("infra.dialog_util")
local I18n = require("core.i18n.engine.i18n")
local Logger = require("core.logger.engine.logger")
local Storage = require("core.fs.adapters.storage")
local NetworkEnv = require("modules.llm.network_env")
local Override = require("core.network.engine.proxy_override")

local LOG = "core.network.proxy_override"

--- Opens the dialog and stores a valid answer.
--- @return boolean saved
function M.run()
	local setting, err = NetworkEnv.proxy_override_setting()
	if not setting then
		Logger.error(LOG, "The proxy override row cannot open: %s.", tostring(err))
		return false
	end
	local ok_label, cancel_label = I18n.get("common.ok"), I18n.get("common.cancel")
	return Override.edit(setting, {
		get = function(key) return Storage.get(key, nil) end,
		set = Storage.set,
		prompt = function(title, text, initial)
			local button, value = Dialog.text_prompt(title, text, initial, ok_label, cancel_label)
			if button == ok_label then return value end
			return nil
		end,
		error = function(title, text) Dialog.block_alert(title, text, ok_label, nil, "critical") end,
		info = function(title, text) Dialog.block_alert(title, text, ok_label) end,
		t = function(key) return I18n.get(key) end,
		log = function(level, message, ...) Logger[level](LOG, message, ...) end,
	})
end

return M
