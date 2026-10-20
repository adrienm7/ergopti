--- tests/unit/modules/shortcuts/text_actions/test_dry_run_remap_dispatch.lua

--- ==============================================================================
--- MODULE: Dry-run Remap Dispatch
--- DESCRIPTION:
--- Runs Main's actual tap-hold initialization through the original Reader, Hook,
--- Manager, pair engine and Writer with controlled native constructors. Native
--- source and output guards remain real. No device or desktop is acquired.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Evaluates actual Main initialization without executing the daemon.
--- @param source string Exact source excerpt.
--- @param environment table Main dependencies.
--- @return any result
local function evaluate(source, environment)
	local compiled
	if loadstring then compiled = assert(loadstring(source)); setfenv(compiled, environment)
	else compiled = assert(load(source, "actual Main remap initialization", "t", environment)) end
	return compiled()
end

--- Runs a configured physical binding under controlled original native consumers.
--- @param route string Single tap, ordered pair or buffered chord.
--- @param dry boolean Actual CLI dry-run option.
--- @param action string Catalogue action.
--- @param hold boolean Whether to keep an independent native Ctrl hold.
--- @param body function Observes decoded native output and action side effects.
--- @param revoke boolean|nil Retires the persisted chord after its first press.
local function with_remap(route, dry, action, hold, body, revoke)
	local saved = {}
	for name, value in pairs(package.loaded) do saved[name] = value end
	for name in pairs(saved) do
		if name:match("^modules%.") or name:match("^adapters%.") or name:match("^infra%.")
			or name:match("^platform%.remap%.") or name:match("^config_binding") or name == "logger.shim" then package.loaded[name] = nil end
	end
	local config_path, tap_path = os.tmpname(), os.tmpname()
	local injector, manager
	local ok, detail = pcall(function()
		local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
		local source = file:read("*a"); assert(file:close())
		local environment = setmetatable({ arg = dry and { "--dry-run" } or {} }, { __index = _G })
		environment.Logger = helpers.make_logger_stub()
		local first = assert(source:find("local function parse_args()", 1, true))
		local last = assert(source:find("\n--- Prints the CLI usage.", first, true))
		environment.opts = evaluate(source:sub(first, last - 1) .. "\nreturn parse_args()", environment)
		helpers.assert_eq(environment.opts.dry_run, dry)
		helpers.assert_eq(environment.opts.tray, false)
		local config = '[shortcuts]\nenabled = true\n[gestures]\nenabled = false\n'
			.. '[gesture_parameters]\ntap_hold__tab__send_text = "ok"\ncombination__caps_lock_then_tab__send_text = "ok"\ncombination__tab_then_caps_lock__send_text = "ok"\n'
		if route == "ordered" then config = config .. '[shortcuts.key_combination_taps]\ncaps_lock_then_tab = "' .. action .. '"\n'
			.. (hold and '[shortcuts.key_combination_holds]\ncaps_lock_then_tab = "ctrl"\n' or "")
		elseif route == "buffered" then config = config .. '[mod_combos]\nenabled = true\nsimultaneous_threshold_ms = 50\nsymmetric = true\n'
			.. '[mod_combos.config.tab_then_caps_lock]\ncombo = "' .. action .. '"\n' end
		file = assert(io.open(config_path, "wb")); assert(file:write(config)); assert(file:close())
		local tap = '[tap_hold]\nenabled = ' .. tostring(route == "single") .. '\ninherit_defaults = false\n'
		if route == "single" then tap = tap .. '[tap_hold.keys.tab]\ntap_action = "' .. action .. '"\n'
			.. 'hold_modifier = "' .. (hold and "ctrl" or "") .. '"\n' .. (hold and "" or 'hold_layer = ""\n') .. 'time_activation_seconds = 0.2\n' end
		file = assert(io.open(tap_path, "wb")); assert(file:write(tap)); assert(file:close())
		local routes = require("infra.config_paths")
		local original_route = routes.config
		routes.config = function(name)
			if name == "config.toml" then return config_path end
			if name == "tap_hold.toml" then return tap_path end
			return original_route(name)
		end
		require("tests.support.text_owner_fixture").with(function(guard)
			-- CapsWord keeps its real Manager/Hook lock transaction. Only XKB's
			-- desktop boundary is stateful here: KEY_CAPSLOCK toggles its Lock.
			local capture, caps_locked
			if action == "caps_word" then
				caps_locked = false
				capture = {
					is_ready = function() return true end, reset_state = function() caps_locked = false; return true end,
					modifier_role = function(code) return require("infra.evdev_codes").MODIFIER_OF[code] end,
					caps_locked = function() return caps_locked end, cancel_compose = function() return true end,
					peek_text = function() return nil end,
					process = function(code, value) if code == 58 and value == 1 then caps_locked = not caps_locked end end,
				}
			end
			require("tests.support.input_owner_fixture").with_session({ public_chords = true, source_ids = { "a" }, keys = {}, capture = capture }, function(session)
				assert(session.hook.set_remapper(nil))
				local world = { reads = 0, writes = 0, lifecycle = 0, resets = 0, errors = {} }
				local logger = assert(dofile(require("infra.paths").shared("lua/logger/init.lua")))
				logger.set_sink(function() end)
				logger.set_error_observer(function(_, _, message) world.errors[#world.errors + 1] = message end)
				package.loaded["logger.shim"], environment.Logger = logger, logger
				local pending, clipboard = nil, "ok"
				package.loaded["adapters.shell_runner"] = {
					has_command = function() return true end,
					exec_checked = function() world.reads = world.reads + 1; return true, clipboard end,
					with_exact_stdin = function(command, text) pending = text; return command end,
					run = function() clipboard = pending; world.writes = world.writes + 1; return true end,
				}
				package.loaded["infra.display_server"] = { UNKNOWN = "unknown", kind = function() return "x11" end,
					is_x11 = function() return true end, is_wayland = function() return false end }
				package.loaded["adapters.window_info"] = { focused_app_id = function() return "owned-editor" end }
				local layout = require("adapters.keyboard_layout")
				layout._set_table_for_test({ o = { keycode = 24, mods = {} }, k = { keycode = 37, mods = {} } })
				injector = require("modules.hotstrings.injector")
				injector._set_nanosleep_for_test(function() end)
				injector._set_uinput(session.writer)
				local function lifecycle() world.lifecycle = world.lifecycle + 1 end
				environment.script_actions = require("modules.shortcuts.script_actions").new({ reset = lifecycle, reload = lifecycle, quit = lifecycle })
				environment.gestures = require("modules.gestures.manager")
				environment.shortcuts = require("modules.shortcuts.manager")
				environment.ActionHandlers = require("modules.shortcuts.action_handlers")
				environment.secure_focus_guard = guard
				evaluate(assert(source:match("\n\t\t(gestures%.init%b())")), environment)
				evaluate(assert(source:match("\n\t\t(shortcuts%.init%b())")), environment)
				manager = helpers.load_module("platform.remap.tap_hold_manager")
				environment.TapHold, environment.keyboard_hook = manager, session.hook
				environment.action_catalogue = environment.gestures
				environment.WordReset = require("modules.hotstrings.word_reset")
				environment.engine = { reset = function() world.resets = world.resets + 1 end }
				evaluate(assert(source:match("\n\t(TapHold%.init%b())")), environment)

				session.rows = {}
				if route ~= "single" then session.edge("a", 58, 1, 1000) end
				world.first_rows = #session.rows
				if revoke then
					local changed = config:gsub('combo = "' .. action .. '"', 'combo = "none"')
					local changed_file = assert(io.open(config_path, "wb"))
					assert(changed_file:write(changed)); assert(changed_file:close())
				end
				session.edge("a", 15, 1, 1010)
				if route == "single" and hold then
					session.edge("a", 30, 1, 1020); session.edge("a", 30, 0, 1030)
				end
				session.edge("a", 15, 0, 1100)
				if route ~= "single" then session.edge("a", 58, 0, 1110) end
				world.caps_word_active = environment.shortcuts.is_caps_word_active()
				world.caps_locked = caps_locked
				if world.caps_word_active then environment.shortcuts.cancel_caps_word("dry-run fixture completed") end
				if capture then helpers.assert_eq(caps_locked, false, "The actual Hook releases its CapsWord lock") end
				assert(manager._reset_for_test()); manager = nil
				world.rows, world.text, world.held = session.rows, {}, {}
				for _, row in ipairs(session.rows) do
					world.held[row[1]] = row[2] == 1 or nil
					if row[1] == 24 or row[1] == 37 then world.text[#world.text + 1] = row end
				end
				helpers.assert_eq(next(world.held), nil, "Every physical/remapped/authored DOWN has cleanup")
				helpers.assert_eq(#world.errors, 0, table.concat(world.errors, " / "))
				body(world)
			end)
		end)
	end)
	if manager then pcall(manager._reset_for_test) end
	if injector then injector._set_uinput(nil); injector._set_nanosleep_for_test(nil) end
	os.remove(config_path); os.remove(tap_path)
	for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved) do package.loaded[name] = value end
	if not ok then error(detail, 0) end
end

helpers.describe("dry-run physical remaps", function()
	for _, route in ipairs({ "single", "ordered", "buffered" }) do
		for _, action in ipairs({ "send_text", "paste_plain" }) do
			for _, dry in ipairs({ false, true }) do
				helpers.it("dry-run-remaps " .. route .. " " .. action .. " " .. tostring(dry), function()
					with_remap(route, dry, action, false, function(world)
						if dry then
							helpers.assert_eq(world.text, {})
							helpers.assert_eq(world.reads, 0)
							helpers.assert_eq(world.writes, 0)
							helpers.assert_eq(world.rows, route == "single" and { { 15, 1 }, { 15, 0 } }
								or { { 58, 1 }, { 15, 1 }, { 15, 0 }, { 58, 0 } }, "Refused payload uses original native events")
							if route == "buffered" then helpers.assert_eq(world.first_rows, 1, "Refused chord must not buffer its first physical press") end
						else
							helpers.assert_eq(world.text, { { 24, 1 }, { 24, 0 }, { 37, 1 }, { 37, 0 } })
							helpers.assert_eq(world.reads, action == "paste_plain" and 1 or 0)
							if route == "buffered" then helpers.assert_eq(world.first_rows, 0, "Positive original source guard must retain the normal chord") end
						end
						if dry then helpers.assert_eq(world.resets, 0) end
					end)
				end)
			end
		end
		for _, action in ipairs({ "script_pause_toggle", "script_reload", "script_quit" }) do
			helpers.it("dry-run-remaps preserves " .. route .. " " .. action, function()
				with_remap(route, true, action, false, function(world)
					helpers.assert_eq(world.lifecycle, 1)
					helpers.assert_eq(world.text, {})
					helpers.assert_eq(world.reads, 0)
				end)
			end)
		end
	end
	helpers.it("dry-run-remaps preserves logical CapsWord single", function()
		with_remap("single", true, "caps_word", false, function(world)
			helpers.assert_true(world.caps_word_active, "The ordinary catalogue action starts the actual shortcuts session")
			helpers.assert_true(world.caps_locked, "The actual Hook owns XKB's CapsLock before cleanup")
			helpers.assert_eq(world.text, {})
			helpers.assert_eq(world.reads, 0)
			helpers.assert_eq(world.writes, 0)
			local toggles = 0
			for _, row in ipairs(world.rows) do if row[1] == 58 and row[2] == 1 then toggles = toggles + 1 end end
			helpers.assert_eq(toggles, 2, "CapsWord emits one lock and one physical unlock through the real Writer")
		end)
	end)
	for _, route in ipairs({ "single", "ordered" }) do
		helpers.it("dry-run-remaps preserves independent Ctrl hold " .. route, function()
			with_remap(route, true, "send_text", true, function(world)
				helpers.assert_eq(world.text, {})
				helpers.assert_eq(world.reads, 0)
				local held = false
				for _, row in ipairs(world.rows) do if row[1] == 29 and row[2] == 1 then held = true end end
				helpers.assert_true(held, "Native Ctrl hold remains live before its cleanup")
			end)
		end)
	end
	helpers.it("dry-run-remaps retains source withdrawal for admitted buffered SCRIPT", function()
		with_remap("buffered", true, "script_reload", false, function(world)
			helpers.assert_eq(world.first_rows, 0, "The original admitted source owns the first press")
			helpers.assert_eq(world.lifecycle, 0, "Changed source cannot dispatch the previously admitted lifecycle payload")
			helpers.assert_eq(world.text, {})
		end, true)
	end)
	for _, action in ipairs({ "copy", "paste", "undo", "enter" }) do
		helpers.it("dry-run-remaps keeps physical single-key/chord remap " .. action, function()
			with_remap("single", true, action, false, function(world)
				helpers.assert_eq(world.reads, 0, "Physical remap never reads or transforms clipboard content")
				helpers.assert_eq(world.writes, 0)
				local code = ({ copy = 46, paste = 47, undo = 44, enter = 28 })[action]
				if action == "enter" then helpers.assert_eq(world.rows, { { code, 1 }, { code, 0 } })
				else helpers.assert_eq(world.rows, { { 29, 1 }, { code, 1 }, { code, 0 }, { 29, 0 } }) end
			end)
		end)
	end
end)
