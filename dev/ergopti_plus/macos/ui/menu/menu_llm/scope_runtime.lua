--- ui/menu/menu_llm/scope_runtime.lua

--- Reconciles scoped preferences through the existing native LLM owners.
local M = {}
local Manifest = require("infra.manifest_reader")
local Preferences = require("infra.preferences")
local Logger = require("infra.logger")
local LOG = "menu_llm.scope"

local function clone(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in pairs(value) do result[key] = clone(child) end
	return result
end

local function equal(left, right)
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in pairs(left) do if not equal(value, right[key]) then return false end end
	for key in pairs(right) do if left[key] == nil then return false end end
	return true
end

--- Creates synchronous configuration ports; readiness stays owned by warmup.
--- @param ctx table State, core, keymap, shortcuts, admission and label owners.
--- @return table runtime Exact capture, publication and inverse ports.
function M.new(ctx)
	local state, core, keymap = ctx.state, ctx.core, ctx.keymap
	local fields, native_keys = {}, {}
	local core_keys = { llm_backend = "backend", llm_model_mlx = "llm_model_mlx",
		llm_model_ollama = "llm_model_ollama", llm_active_profile = "active_profile_id",
		llm_user_profiles = "user_profiles" }
	local preference_only = { llm_user_models = true, llm_arrow_nav_enabled = true,
		llm_enabled = true }
	for _, row in ipairs(Manifest.scope_operations("llm", "clear")) do
		local path = row.section .. "." .. row.key
		local key = assert(Preferences.flat_key_for(path), "LLM preference owner missing: " .. path)
		fields[path] = key
		if not core_keys[key] and not preference_only[key] then native_keys[key] = true end
	end
	local function invoke(label, callback, ...)
		if type(callback) ~= "function" then return false end
		local ok, result = Logger.callback(LOG, label, callback, ...)
		return ok == true and result == true
	end
	local function set_value(key, value)
		local callback = key == "llm_model" and keymap.set_llm_configuration_model or keymap["set_" .. key]
		if type(callback) ~= "function" then return false end
		local ok, result = Logger.callback(LOG, "Scoped native setting", callback, clone(value))
		if ok ~= true or result == false then return false end
		local found, actual = keymap.get_llm_runtime_setting(key)
		return found == true and equal(actual, value)
	end
	local runtime, active = {}, nil
	function runtime.capture()
		if ctx.idle() ~= true then return nil end
		local enabled = keymap.get_llm_enabled()
		local shortcuts = ctx.shortcuts.configuration_snapshot()
		if type(enabled) ~= "boolean" or type(shortcuts) ~= "table" then return nil end
		local captured = { core = core.configuration_snapshot(), enabled = enabled,
			shortcuts = shortcuts, state = {}, values = {} }
		if type(captured.core) ~= "table" then return nil end
		for _, key in pairs(fields) do captured.state[key] = clone(state[key]) end
		for _, key in ipairs({ "llm_model", "llm_model_power", "llm_profile_shortcuts" }) do captured.state[key] = clone(state[key]) end
		for key in pairs(native_keys) do
			local found, value = keymap.get_llm_runtime_setting(key)
			if found ~= true then return nil end
			captured.values[key] = { value = clone(value) }
		end
		for _, key in ipairs({ "llm_model", "llm_display_model_name", "llm_backend_name" }) do
			local found, value = keymap.get_llm_runtime_setting(key)
			if found ~= true then return nil end
			captured.values[key] = { value = clone(value) }
		end
		active = captured
		return captured
	end
	local function apply_native(configuration, values, shortcuts, enabled)
		if ctx.idle() ~= true then return false end
		if not invoke("Scoped prediction suspension", keymap.set_llm_enabled, false) then return false end
		if not invoke("Scoped dormant identity", core.apply_configuration, configuration) then return false end
		for key, box in pairs(values) do if not set_value(key, box.value) then return false end end
		if not invoke("Scoped shortcut settlement", ctx.shortcuts.apply_configuration, shortcuts) then return false end
		if ctx.reset_health() ~= true then return false end
		-- This acknowledges the prediction gate and its exact timer acquisitions.
		-- It does not assert that a model has finished loading or is ready.
		if not invoke("Scoped prediction posture", keymap.set_llm_enabled, enabled) then return false end
		return keymap.get_llm_enabled() == enabled
	end
	function runtime.restore(snapshot)
		if not apply_native(snapshot.core, snapshot.values, snapshot.shortcuts, snapshot.enabled) then return false end
		for _, key in pairs(fields) do state[key] = clone(snapshot.state[key]) end
		for _, key in ipairs({ "llm_model", "llm_model_power", "llm_profile_shortcuts" }) do state[key] = clone(snapshot.state[key]) end
		return true
	end
	function runtime.apply(_, rows)
		if type(active) ~= "table" then return false end
		local desired, profile_resets = clone(active.state), {}
		desired.llm_profile_shortcuts = desired.llm_profile_shortcuts or {}
		for _, row in ipairs(rows) do
			local path = row.section .. "." .. row.key
			local key = fields[path]
			if key then
				local value = row.value
				if row.delete then value = Manifest.default_for(path) end
				desired[key] = clone(Preferences.state_value_for(path, value))
			else
				local id, leaf = path:match("^llm%.profiles%.shortcuts%.([^.]+)%.([^.]+)$")
				assert(id and (leaf == "mods" or leaf == "key") and row.delete, "unexpected LLM scope path")
				profile_resets[id] = true
				local shortcut = desired.llm_profile_shortcuts[id]
				if type(shortcut) == "table" then shortcut[leaf] = nil end
			end
		end
		local configuration = clone(active.core)
		for key, native_key in pairs(core_keys) do configuration[native_key] = clone(desired[key]) end
		configuration.user_override_backend = true
		local values = {}
		for key in pairs(native_keys) do values[key] = { value = clone(desired[key]) } end
		local model = configuration.backend == "mlx" and configuration.llm_model_mlx or configuration.llm_model_ollama
		desired.llm_model, desired.llm_model_power = model, ctx.model_power(model)
		values.llm_model = { value = model }
		values.llm_display_model_name = { value = ctx.display_model(model) }
		values.llm_backend_name = { value = ctx.backend_label(configuration.backend) }
		local enabled = active.enabled and desired.llm_enabled == true
		local shortcuts = { llm_profile_shortcuts = clone(active.shortcuts.llm_profile_shortcuts) }
		for id in pairs(profile_resets) do shortcuts.llm_profile_shortcuts[id] = nil end
		if not apply_native(configuration, values, shortcuts, enabled) then return false end
		for _, key in pairs(fields) do state[key] = clone(desired[key]) end
		for _, key in ipairs({ "llm_model", "llm_model_power", "llm_profile_shortcuts" }) do state[key] = clone(desired[key]) end
		return true
	end
	runtime.fields = fields
	return runtime
end

return M
