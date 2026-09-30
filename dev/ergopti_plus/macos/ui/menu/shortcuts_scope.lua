--- ui/menu/shortcuts_scope.lua

--- Applies complete shortcut intent through the existing native and source owners.
local M = {}
local Manifest = require("infra.manifest_reader")
local Preferences = require("infra.preferences")
local Scope = require("infra.preferences_scope")

local STATE_FIELDS = { "shortcuts", "chatgpt_url", "shortcut_keys", "script_control_enabled", "script_control_shortcuts" }

local function clone(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, item in pairs(value) do result[key] = clone(item) end
	return result
end

--- Creates an atomic scope without publishing a menu command or acquiring a second store.
--- ScriptControl's boot-owned eventtap posture is preserved independently of its action gate.
--- @param options table Real shortcut, parameter, native and preference transaction owners.
--- @return table owner Apply, pending and retained-compensation operations.
function M.new(options)
	local shortcuts, bindings, keyboard = options.shortcuts, options.bindings, options.keyboard
	local taps, script, gestures, state = options.tap_keys, options.script_control, options.gestures, options.state
	assert(type(options.start_script_control) == "function" and type(options.idle) == "function",
		"shortcut scope needs script-control acquisition and menu admission owners")
	local captured
	local function read_started(owner)
		local value = owner.is_started()
		assert(type(value) == "boolean", "shortcut native ownership is ambiguous")
		return value
	end
	local function apply_native(target)
		-- Quiesce both independent producers even if either teardown refuses.
		local script_stopped = script.stop()
		local bindings_stopped = shortcuts.pause_bindings("feature_toggle")
		if script_stopped ~= true or bindings_stopped ~= true then return false end
		if read_started(script) or read_started(bindings) or read_started(keyboard) then return false end
		local configuration = { shortcuts = { keyboard = target.keyboard, tap_keys = target.tap_keys } }
		if keyboard.apply_configuration(configuration) ~= true
			or taps.apply_configuration(configuration, gestures.is_assignable) ~= true then return false end
		for id, enabled in pairs(target.keys) do
			if (enabled and bindings.enable or bindings.disable)(id) ~= true
				or bindings.is_enabled(id) ~= enabled then return false end
		end
		if bindings.set_chatgpt_url(target.url) ~= true or bindings.get_chatgpt_url() ~= target.url then return false end
		for key, action in pairs(target.script_actions) do
			if script.set_shortcut_action(key, action) ~= true
				or script.get_shortcut_actions()[key] ~= action then return false end
		end
		for id, action in pairs(target.keyboard) do if keyboard.get_action(id) ~= action then return false end end
		for id, action in pairs(target.tap_keys) do if taps.get_action(id) ~= action then return false end end
		if target.master and shortcuts.resume_bindings("feature_toggle", configuration) ~= true then return false end
		if target.script_started and options.start_script_control() ~= true then return false end
		if read_started(bindings) ~= target.master or read_started(keyboard) ~= target.master
			or read_started(script) ~= target.script_started then return false end
		return true
	end
	local function set_state(values)
		for _, key in ipairs(STATE_FIELDS) do state[key] = clone(values[key]) end
	end
	local ports = {}
	for key, value in pairs(options) do ports[key] = value end
	ports.scope, ports.demotion_feature = "shortcuts", "shortcuts"
	ports.transaction_factory = function(config)
		config.gestures = gestures
		config.owned_paths = keyboard.get_owned_config_paths
		-- The scope's reset owns both assignment containers, an older build's
		-- plain value included.
		config.prepare_rows = function(source, rows)
			return Preferences.prepare_shortcut_updates(source, rows, Preferences.SHORTCUT_CONTAINERS)
		end
		return Scope.new(config)
	end
	ports.runtime = {
		capture = function()
			assert(options.idle() == true and script.is_pause_transition_pending() == false
				and shortcuts.has_bindings_pause_debt() == false, "shortcut scope has unsettled ownership")
			local native = { master = read_started(bindings), script_started = read_started(script),
				keyboard = clone(keyboard.get_assignments()), tap_keys = {}, keys = {},
				script_actions = script.get_shortcut_actions(), url = bindings.get_chatgpt_url() }
			assert(read_started(keyboard) == native.master, "shortcut children have inconsistent native posture")
			taps.ensure_loaded(gestures.is_assignable)
			for _, key in ipairs(taps.keys()) do native.tap_keys[key.id] = taps.get_action(key.id) end
			for _, row in ipairs(bindings.list_shortcuts()) do
				if Manifest.has_default("shortcuts.keys." .. row.id) then
					local value = bindings.is_enabled(row.id)
					assert(type(value) == "boolean", "shortcut preference posture is unavailable")
					native.keys[row.id] = value
				end
			end
			local desired = {}
			for _, key in ipairs(STATE_FIELDS) do desired[key] = clone(state[key]) end
			captured = { native = native, state = desired }
			return captured
		end,
		apply = function(_, updates)
			local native, desired = clone(captured.native), clone(captured.state)
			desired.shortcut_keys = desired.shortcut_keys or {}
			desired.script_control_shortcuts = desired.script_control_shortcuts or {}
			for _, row in ipairs(updates) do
				if row.section ~= "gestures.action_parameters" then
					local value = row.value
					if row.delete then value = Manifest.default_for(row.section .. "." .. row.key) end
					if row.section == "shortcuts.keyboard" then native.keyboard[row.key] = value
					elseif row.section == "shortcuts.tap_keys" then native.tap_keys[row.key] = value
					elseif row.section == "shortcuts.keys" then
						assert(native.keys[row.key] ~= nil, "scope key has no native binding owner: " .. row.key)
						native.keys[row.key], desired.shortcut_keys[row.key] = value, value
					elseif row.section == "shortcuts.script_control" then
						if row.key == "enabled" then desired.script_control_enabled = value
						else desired.script_control_shortcuts[row.key] = value end
					elseif row.section == "shortcuts" and row.key == "enabled" then native.master, desired.shortcuts = value, value
					elseif row.section == "shortcuts" and row.key == "chatgpt_url" then native.url, desired.chatgpt_url = value, value
					else error("shortcut scope has no runtime owner: " .. row.section .. "." .. row.key) end
				end
			end
			for key in pairs(native.script_actions) do
				local value = desired.script_control_shortcuts[key]
				if Manifest.has_default("shortcuts.script_control." .. key) then
					assert(type(value) == "string" and gestures.is_assignable(value), "invalid script action in scope candidate")
					native.script_actions[key] = desired.script_control_enabled and value or "none"
				end
			end
			if apply_native(native) ~= true then return false end
			set_state(desired)
			return true
		end,
		restore = function(snapshot)
			if apply_native(snapshot.native) ~= true then return false end
			set_state(snapshot.state)
			return true
		end,
	}
	return require("ui.menu.scoped_preferences").new(ports)
end

return M
