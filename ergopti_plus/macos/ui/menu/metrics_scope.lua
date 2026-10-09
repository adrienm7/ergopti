--- ui/menu/metrics_scope.lua

--- Owns Metrics configuration without deleting history or converting stored text.
local M = {}
local Manifest = require("infra.manifest_reader")
local Preferences = require("infra.preferences")

local function clone(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in pairs(value) do result[key] = clone(child) end
	return result
end

--- Builds the complete Metrics scope over the existing native owners.
--- @param options table Common persistence ports and concrete Metrics runtime ports.
--- @return table owner Scoped publication and retained compensation.
function M.new(options)
	local state, core = options.state, options.core
	local menubar, widget = options.menubar, options.widget
	local fields = {}
	for _, row in ipairs(Manifest.scope_operations("metrics", "clear")) do
		local path = row.section .. "." .. row.key
		fields[path] = assert(Preferences.flat_key_for(path), "metrics preference owner missing: " .. path)
	end
	local active
	local function restore(snapshot)
		if options.activation_pending() ~= false then return false end
		if core.apply_configuration(snapshot.core) ~= true then return false end
		local lifecycle = snapshot.core.enabled and core.start or core.stop
		if lifecycle(options.script_control) ~= true then return false end
		if menubar.apply_configuration(snapshot.menubar) ~= true then return false end
		if widget.apply_configuration(snapshot.widget) ~= true then return false end
		for _, key in pairs(fields) do state[key] = clone(snapshot.state[key]) end
		return true
	end
	local ports = {}
	for key, value in pairs(options) do ports[key] = value end
	ports.scope, ports.demotion_feature = "metrics", "metrics"
	ports.demotion_keys = function(rows)
		local keys = {}
		for _, row in ipairs(rows) do keys[assert(fields[row.section .. "." .. row.key])] = true end
		return keys
	end
	ports.runtime = {
		capture = function()
			if options.activation_pending() ~= false then return nil end
			local native = core.configuration_snapshot()
			if type(native) ~= "table" then return nil end
			active = { core = native, menubar = menubar.configuration_snapshot(),
				widget = widget.configuration_snapshot(), state = {} }
			for _, key in pairs(fields) do active.state[key] = clone(state[key]) end
			return active
		end,
		apply = function(_, rows)
			if options.activation_pending() ~= false then return false end
			local values, enabled = {}, active.core.enabled
			for _, row in ipairs(rows) do
				local path = row.section .. "." .. row.key
				local key = assert(fields[path], "unexpected metrics scope field: " .. path)
				local value = row.value
				if row.delete then value = Manifest.default_for(path) end
				values[key] = clone(value)
				if path == "metrics.enabled" then enabled = value end
			end
			-- Restore excludes consent; Clear only revokes it. Neither operation
			-- may turn a demoted or inactive collector on.
			assert(enabled == false or active.core.enabled == true, "scope cannot grant metrics consent")
			for key, value in pairs(values) do state[key] = value end
			if not enabled and core.stop() ~= true then return false end
			local native = clone(active.core)
			native.options.encrypt, native.cipher_enabled = state.keylogger_encrypt, state.keylogger_encrypt
			native.options.menubar, native.options.float = state.keylogger_menubar_wpm, state.keylogger_float_wpm
			native.options.float_graph = state.keylogger_float_graph
			native.disabled_apps = clone(state.keylogger_disabled_apps)
			native.private_filter_enabled = state.keylogger_private_filter_enabled
			native.secure_field_filter_enabled = state.keylogger_secure_filter_enabled
			native.system_auth_filter_enabled = state.keylogger_system_auth_filter_enabled
			if core.apply_configuration(native) ~= true then return false end
			if menubar.apply_configuration({ running = enabled and state.keylogger_menubar_wpm,
				colors = state.keylogger_menubar_colors }) ~= true then return false end
			if widget.apply_configuration({ running = enabled and state.keylogger_float_wpm,
				colors = state.keylogger_float_colors, graph = state.keylogger_float_graph }) ~= true then return false end
			return true
		end,
		restore = restore,
	}
	return require("ui.menu.scoped_preferences").new(ports)
end

return M
