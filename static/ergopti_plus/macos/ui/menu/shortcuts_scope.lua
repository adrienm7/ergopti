--- ui/menu/shortcuts_scope.lua

--- Applies complete shortcut intent through the existing native and source owners.
local M = {}
local PhysicalAvailability = require("shortcuts.physical_availability")
local Manifest = require("infra.manifest_reader")
local Preferences = require("infra.preferences")
local Scope = require("infra.preferences_scope")

local STATE_FIELDS = { "shortcuts", "chatgpt_url", "shortcut_keys", "script_control_enabled", "script_control_shortcuts" }

-- The rows of the script chords' submenu: their section, and the parameters
-- of the bindings they dispatch under (modules/shortcuts/script_control.lua
-- BINDING_PREFIX).
local SCRIPT_CHORD_SECTION = "shortcuts.script_control"
local SCRIPT_CHORD_PARAMETERS = "gestures.action_parameters." .. require("modules.shortcuts.script_control").BINDING_PREFIX

--- Whether a Shortcuts scope row belongs to the script chords' submenu, whose
--- restore and clear narrow the scope to it (config_scope_transaction `select`).
--- @param path string Configuration path of a scope row.
--- @return boolean
function M.script_chord_rows(path)
	return path == SCRIPT_CHORD_SECTION or path:sub(1, #SCRIPT_CHORD_SECTION + 1) == SCRIPT_CHORD_SECTION .. "."
		or path:sub(1, #SCRIPT_CHORD_PARAMETERS) == SCRIPT_CHORD_PARAMETERS
end

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
	local captured, edit_source
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
		if keyboard.apply_configuration(configuration, target.keyboard_claims) ~= true
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
		if script.set_chords_enabled(target.script_chords_on) ~= true
			or script.chords_enabled() ~= target.script_chords_on then return false end
		for id, action in pairs(target.keyboard_expected) do if keyboard.get_action(id) ~= action then return false end end
		for id, action in pairs(target.tap_keys) do if taps.get_action(id) ~= action then return false end end
		if target.master and shortcuts.resume_bindings("feature_toggle", configuration, target.keyboard_claims) ~= true then return false end
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
	ports.edit_fence = {
		acquire = keyboard.acquire_physical_publication,
		release = keyboard.release_physical_publication,
		validate = keyboard.validate_physical_edits,
	}

	ports.transaction_factory = function(config)
		config.expected_source = edit_source
		config.gestures = gestures
		config.owned_paths = keyboard.get_owned_config_paths
		-- The scope's reset owns both assignment containers, an older build's
		-- plain value included; the script chords' submenu (a `select`) owns
		-- neither, but writes its inline leaves the same way.
		local containers = config.select == nil and not config.editing and Preferences.SHORTCUT_CONTAINERS or nil
		config.parameter_name_owned = function(domain, name)
			if domain == "keyboard" and require("shortcuts.physical_slots").is_namespace(name) then
				return keyboard.physical_slot_descriptor(name) ~= nil
			end
			return nil
		end
		config.validate_edit_row = function(scope, row)
			if scope ~= "shortcuts" then return false end
			if row.section == "shortcuts.keyboard" then
				return keyboard.physical_slot_descriptor(row.key) ~= nil
					and (row.delete == true or gestures.is_assignable(row.value) == true)
			end
			if row.section == "gestures.action_parameters" then
				local binding, action = gestures.split_action_parameter_key(row.key)
				local slot = type(binding) == "string" and binding:match("^keyboard__(.+)$") or nil
				return slot ~= nil and keyboard.physical_slot_descriptor(slot) ~= nil
					and type(action) == "string" and type(gestures.get_action_parameter_spec(action)) == "string"
					and (row.delete == true or gestures.validate_action_parameter(action, row.value) == true)
			end
			return false
		end
		config.prepare_rows = function(source, rows)
			return Preferences.prepare_shortcut_updates(source, rows, containers)
		end
		return Scope.new(config)
	end
	ports.runtime = {
		capture = function()
			assert(options.idle() == true and script.is_pause_transition_pending() == false
				and shortcuts.has_bindings_pause_debt() == false, "shortcut scope has unsettled ownership")
			local assignments, claims = keyboard.get_configuration_intent()
			local native = { master = read_started(bindings), script_started = read_started(script),
				keyboard = assignments, keyboard_claims = claims,
				keyboard_expected = clone(keyboard.get_assignments()), tap_keys = {}, keys = {},
				script_actions = script.get_shortcut_actions(), script_chords_on = script.chords_enabled(),
				url = bindings.get_chatgpt_url() }
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
					if row.delete then
						if row.section == "shortcuts.keyboard" and keyboard.physical_slot_descriptor(row.key) ~= nil then value = "none"
						else value = Manifest.default_for(row.section .. "." .. row.key) end
					end
					if row.section == "shortcuts.keyboard" then
						native.keyboard_expected[row.key] = value
						if row.delete then
							native.keyboard[row.key], native.keyboard_claims[row.key] = nil, nil
						else
							native.keyboard[row.key], native.keyboard_claims[row.key] = value, true
						end
					elseif row.section == "shortcuts.tap_keys" then native.tap_keys[row.key] = value
					elseif row.section == "shortcuts.keys" then
						assert(native.keys[row.key] ~= nil, "scope key has no native binding owner: " .. row.key)
						native.keys[row.key], desired.shortcut_keys[row.key] = value, value
					elseif row.section == "shortcuts.script_control" then
						if row.key == "chords_enabled" then desired.script_control_enabled = value
						else desired.script_control_shortcuts[row.key] = value end
					elseif row.section == "shortcuts" and row.key == "enabled" then native.master, desired.shortcuts = value, value
					elseif row.section == "shortcuts" and row.key == "chatgpt_url" then native.url, desired.chatgpt_url = value, value
					else error("shortcut scope has no runtime owner: " .. row.section .. "." .. row.key) end
				end
			end
			-- The switch off keeps every slot's action (a clear writes "none" in
			-- each slot, since an absent slot starts with its preset).
			for key in pairs(native.script_actions) do
				local value = desired.script_control_shortcuts[key]
				if Manifest.has_default("shortcuts.script_control." .. key) then
					assert(type(value) == "string" and (value == "none" or gestures.is_assignable(value)),
						"invalid script action in scope candidate")
					native.script_actions[key] = value
				end
			end
			assert(type(desired.script_control_enabled) == "boolean", "invalid script chords switch in scope candidate")
			native.script_chords_on = desired.script_control_enabled
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
	local owner = require("ui.menu.scoped_preferences").new(ports)
	local source_owner = options.preferences or Preferences
	local inventory = require("shortcuts.physical_editor_inventory").new({
		path = options.path, current_path = options.current_path or function() return require("infra.config_paths").get("config.toml") end,
		read = options.files.read_with_status, keyboard = keyboard, parameters = require("modules.gestures.actions"),
		recognizes = function(binding)
			return type(binding) == "string" and (binding:match("^keyboard__") ~= nil
				or binding:match("^tap_key__") ~= nil or binding:match("^script__") ~= nil)
		end,
		source_guard = function(expected)
			local current = source_owner.source_snapshot(options.path)
			if type(current) ~= "table" or current.status ~= expected.status or current.content ~= expected.content then return nil end
			return source_owner.capture_source_delivery_guard(options.path)
		end,
	})
	function owner.capture_editor_inventory()
		if owner.pending() then return nil, "unavailable" end
		local called, values, receipt = pcall(inventory.capture)
		if not called then return nil, "unavailable" end
		return values, receipt
	end
	function owner.editor_source_current(receipt)
		local called, current = pcall(inventory.current, receipt)
		return called and current == true
	end
	--- Keeps native physical admission separate from GUI availability.
	--- @return boolean available Strict native delivery acknowledgement.
	function owner.physical_delivery_available()
		return PhysicalAvailability.ready(keyboard.physical_delivery_available)
	end
	local edit = owner.edit
	function owner.edit(rows, receipt)
		rows = PhysicalAvailability.capture_updates(rows)
		if rows == nil then return false, "save_failed" end
		if not owner.physical_delivery_available()
			and PhysicalAvailability.requires_delivery(rows, "gestures.action_parameters", options.gestures.split_action_parameter_key) then
			return false, "unavailable"
		end
		if receipt ~= nil then
			local called, expected = pcall(inventory.expected_source, receipt)
			if not called or not expected then return false, "source_changed" end
			edit_source = expected
		end
		local called, committed, reason = pcall(edit, rows)
		edit_source = nil
		if called and committed == true then return true end
		local closed = { source_changed = true, collision = true, unavailable = true, save_failed = true }
		return false, called and closed[reason] and reason or "save_failed"
	end
	return owner
end

return M
