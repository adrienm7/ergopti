--- tests/support/shortcuts_scope_fixture.lua

--- Composes real shortcut owners over observable native handles and a canonical file.
local helpers = require("tests.helpers")
local M = {}

local function run_fixture(body, source)
	local root = helpers.driver_root()
	require("tests.support.module_isolation").purge(root, root:gsub("[/\\]macos$", "/_shared/lua"))
	helpers.load_with_stubs("hs")
	local controls = { writes = 0, native = {}, keyboard_handles = {} }
	local files = { config = source or '[shortcuts]\nenabled = true\nchatgpt_url = "https://example.test"\nkeyboard = { cmd_a = "send_text", foreign = 17 }\ntap_keys = { number_row_left = "send_text", foreign = 21 }\nscript_control = { chords_enabled = true, script_altgr_enter = "open_url", script_altgr_backspace = "none", script_altgr_escape = "none", future = 42 }\nkeys = { ctrl_g = true, future = true }\n[gestures]\naction_parameters = { keyboard__cmd_a__send_text = "keyboard", tap_key__number_row_left__send_text = "tap", script__script_altgr_enter__open_url = "https://example.test", tap_4__open_url = "https://apple.com", future = { keep = 9 } }\n[future]\nkeep = 7\n' }
	if source == false then files.config = nil end
	local file_port = {
		read = function(path)
			local file = assert(io.open(path, "rb"))
			local content = file:read("*a"); file:close(); return content
		end,
		read_with_status = function(path) return files[path], files[path] and "ok" or "absent" end,
		write = function() error("scope requires conditional publication") end,
		write_if_unchanged = function(path, value, expected)
			if controls.refuse_write and path == "config" then return false end
			if expected.status ~= (files[path] and "ok" or "absent")
				or (expected.status == "ok" and expected.content ~= files[path]) then return false end
			if controls.during_write then controls.during_write(path) end
			files[path] = value; controls.writes = controls.writes + 1; return true
		end,
	}
	-- Preserve the controlled native callback before the final logical fence.
	function file_port.write_if_unchanged_admitted(path, value, expected, _, admission)
		if type(expected) ~= "table" or getmetatable(expected) ~= nil or type(admission) ~= "function" then return false end
		local status, content = rawget(expected, "status"), rawget(expected, "content")
		if not (status == "ok" and type(content) == "string" or status == "absent" and content == nil) then return false end
		if controls.refuse_write and path == "config" then return false end
		if status ~= (files[path] and "ok" or "absent") or status == "ok" and files[path] ~= content then return false end
		if controls.during_write then controls.during_write(path) end
		local called, admitted = pcall(admission)
		if not called or admitted ~= true then return false end
		if status ~= (files[path] and "ok" or "absent") or status == "ok" and files[path] ~= content then return false end
		files[path] = value; controls.writes = controls.writes + 1; return true
	end
	package.loaded["adapters.file_system"] = file_port
	package.loaded["infra.config_paths"] = { get = function() return "config" end }
	package.loaded["infra.paths"] = { shared = helpers.shared }
	local logger = helpers.make_logger_stub()
	controls.errors = {}
	logger.error = function(_, message, ...) controls.errors[#controls.errors + 1] = string.format(message, ...) end
	package.loaded["infra.logger"] = logger
	package.loaded["infra.keycodes"] = {
		F18_WAKE_OS = 79, F19_LAYER_NAV_EXITED = 80,
		F13_KARABINER_RETURN = 106, F14_KARABINER_BACKSPACE = 107, F15_KARABINER_ESCAPE = 108,
		F18_KARABINER_DELETE = 79, SCRIPT_CHORD_SENTINELS = require("keycodes").SCRIPT_CHORD_SENTINELS,
		RETURN = 36, BACKSPACE = 51, ESCAPE = 53, FORWARD_DELETE = 117,
		to_name = function(code) return "f" .. tostring(code) end,
	}
	-- A layers.toml that binds no wheel direction: the layer's wheel owner
	-- stays unbound, as for a user who never saved one.
	package.loaded["platform.remap.nav_layer"] = {
		load = function() return { bindings = {}, registry = {}, wheel = { vertical = {}, horizontal = {} } } end,
	}
	local function handle(kind)
		if controls.refuse_start == kind then return nil end
		local native = { enabled = true, kind = kind }
		function native:delete()
			if controls.refuse_stop == kind then return false end
			self.enabled = false; return true
		end
		controls.native[#controls.native + 1] = native
		return native
	end
	hs.hotkey.bind = function() return handle("binding") end
	package.loaded["adapters.hotkey_registrar"] = {
		bind = function(chord, callback)
			-- Both producers share the same port. Attribute the native refusal to
			-- its actual owner, independently of key names and acquisition order.
			local kind, level = nil, 2
			while kind == nil do
				local frame = debug.getinfo(level, "S")
				assert(frame, "scope fixture encountered an unknown hotkey producer")
				if frame.source:match("[/\\]modules[/\\]shortcuts[/\\]bindings%.lua$") then kind = "binding" end
				if frame.source:match("[/\\]modules[/\\]shortcuts[/\\]keyboard_shortcuts%.lua$") then kind = "keyboard" end
				level = level + 1
			end
			local native = handle(kind)
			if native then
				native.chord, native.callback = chord, callback
				if kind == "keyboard" then controls.keyboard_handles[#controls.keyboard_handles + 1] = native end
			end
			return native
		end,
		unbind = function(native) return native:delete() end,
		setEnabled = function(native, enabled) native.enabled = enabled; return true end,
		set_delivery_guard = function() return true end,
		replace_physical_claims = function(owner, rows)
			controls.physical_claims = controls.physical_claims or {}
			controls.physical_claims[owner] = rows
			return true
		end,
	}
	local facades = { text = {}, apps = {}, system = {} }
	for _, record in ipairs({ { "text", "text" }, { "apps", "apps" }, { "system", "mouse" }, { "system", "pixel" } }) do
		local facade, paused = facades[record[1]], false
		local suffix = record[2] .. "_actions"
		facade["pause_" .. suffix] = function() paused = true; return true end
		facade["stop_" .. suffix] = function() paused = true; return true end
		facade["resume_" .. suffix] = function() paused = false; return true end
		facade["is_" .. suffix .. "_paused"] = function() return paused end
		facade["has_pending_" .. record[2] .. "_action"] = function() return false end
	end
	local claims = {}
	for _, edge in ipairs({ "pause", "stop", "resume" }) do
		facades.system[edge .. "_screenshot_actions"] = function(parent) claims[parent] = edge ~= "resume" or nil; return true end
	end
	facades.system.has_screenshot_pause_claim = function(parent) return claims[parent] == true end
	facades.system.has_pending_screenshot_action = function() return false end
	for _, edge in ipairs({ "pause", "stop", "resume" }) do facades.system[edge .. "_awake"] = function() return true end end
	for _, name in ipairs({ "bind_instant_screenshot", "bind_layer_wheel", "bind_wrap_text_if_selected", "bind_cmd_star", "bind_tap_keys" }) do
		facades.system[name] = function() return handle("binding") end
	end
	for name, facade in pairs(facades) do
		setmetatable(facade, { __index = function() return function() return true end end })
		package.loaded["modules.shortcuts.actions." .. name] = facade
	end
	local old_new = hs.eventtap.new
	hs.eventtap.new = function(...)
		local tap = old_new(...)
		local stop = tap.stop
		tap.stop = function(self)
			if controls.refuse_script_stop then return self end
			return stop(self)
		end
		local start = tap.start
		tap.start = function(self)
			if controls.refuse_script_start then return false end
			return start(self)
		end
		return tap
	end
	local gestures = require("modules.gestures")
	local bindings = require("modules.shortcuts.bindings")
	local keyboard = require("modules.shortcuts.keyboard_shortcuts")
	local taps = require("modules.shortcuts.tap_keys")
	local script = require("modules.shortcuts.script_control")
	local shortcuts = require("modules.shortcuts")
	local prefs = require("infra.preferences")
	local saved = prefs.load("config")
	local state = { shortcuts = true, script_control_enabled = true,
		script_control_shortcuts = { script_altgr_enter = "open_url", script_altgr_backspace = "none",
			script_altgr_delete = "open_personal_shortcuts", script_altgr_escape = "none" },
		shortcut_keys = { ctrl_g = true }, chatgpt_url = "https://example.test" }
	for key, value in pairs(saved.gesture_action_parameters or {}) do
		local binding, action = gestures.split_action_parameter_key(key)
		if binding and action and type(value) == "string" then
			helpers.assert_eq(gestures.set_action_parameter(binding, action, value), true)
		end
	end
	taps.load(gestures.is_assignable)
	bindings.pause_hotkeys_only(); bindings.enable("ctrl_g")
	bindings.set_chatgpt_url(state.chatgpt_url)
	helpers.assert_eq(shortcuts.start(), true)
	helpers.assert_eq(bindings.is_started(), true, "fixture static registry started")
	helpers.assert_eq(keyboard.is_started(), true, "fixture keyboard registry started")
	for key, value in pairs(state.script_control_shortcuts) do script.set_shortcut_action(key, value) end
	local function start_script() return script.start({}, shortcuts, gestures) end
	helpers.assert_eq(start_script(), true)
	local modules = { gestures = gestures, shortcuts_mod = shortcuts }
	local demotions = require("ui.menu.session_demotions").new()
	local save, checkpoint = require("ui.menu.preferences_transaction").bind(prefs, {
		path = "config", state = state, hotfiles = {}, core_modules = modules,
		initial_state = state, initial_preferences = prefs.snapshot(state, {}, modules),
		snapshot_view = demotions.persisted_view,
		-- Ordinary-save compensation below exercises the URL's real runtime owner;
		-- the complete scope compensation uses the production Shortcuts owner.
		restore_runtime = function(snapshot) return bindings.set_chatgpt_url(snapshot.chatgpt_url) end,
	})
	local busy = false
	local owner = require("ui.menu.shortcuts_scope").new({
		path = "config", files = file_port, state = state, preferences = prefs, checkpoint = checkpoint,
		gestures = gestures, shortcuts = shortcuts, bindings = bindings, keyboard = keyboard,
		tap_keys = taps, script_control = script, start_script_control = start_script, demotions = demotions,
		idle = function() return controls.idle ~= false end,
		capture_preferences = function() return prefs.snapshot(state, {}, modules) end,
		backup_path = function() return "backup" end,
		paused = function() return controls.paused == true end,
		admission = function(_, callback)
			if busy then return false end
			busy = true; local ok, result, detail = pcall(callback); busy = false
			if not ok then error(result) end
			return result, detail
		end,
	})
	local ok, detail = pcall(body, { owner = owner, state = state, files = files, controls = controls,
		gestures = gestures, bindings = bindings, keyboard = keyboard, taps = taps, script = script,
		shortcuts = shortcuts, prefs = prefs, save = save, demotions = demotions, checkpoint = checkpoint })
	controls.refuse_stop, controls.refuse_script_stop = nil, false
	shortcuts.pause_bindings("feature_toggle"); script.stop()
	if not ok then error(detail, 0) end
end

--- Restores the entire pre-fixture module cache and global native double on every exit.
--- @param body function Assertions against real owners and controlled native boundaries.
--- @param source string|boolean|nil Initial canonical source; false models an absent file.
function M.run(body, source)
	local saved, original_hs = {}, _G.hs
	for name, value in pairs(package.loaded) do saved[name] = value end
	local ok, detail = xpcall(function() run_fixture(body, source) end, debug.traceback)
	for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved) do package.loaded[name] = value end
	_G.hs = original_hs
	if not ok then error(detail, 0) end
end

return M
