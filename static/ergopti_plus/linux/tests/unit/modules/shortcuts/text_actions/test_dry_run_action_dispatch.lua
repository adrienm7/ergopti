--- tests/unit/modules/shortcuts/text_actions/test_dry_run_action_dispatch.lua

--- ==============================================================================
--- MODULE: Dry-run Action Dispatch
--- DESCRIPTION:
--- Executes Main's actual CLI parser, initialization and dispatch callbacks with
--- real configuration, focus ownership, action handlers and text injector. Only
--- desktop boundaries are controlled; emitted text keys differ from the input
--- chord, so physical forwarding cannot masquerade as programmatic injection.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Evaluates an actual Main excerpt without starting the daemon.
--- @param source string Exact source excerpt.
--- @param environment table Main's explicit dependencies.
--- @return any result
local function evaluate(source, environment)
	local compiled
	if loadstring then compiled = assert(loadstring(source)); setfenv(compiled, environment)
	else compiled = assert(load(source, "actual Main action dispatch", "t", environment)) end
	return compiled()
end

--- Runs an isolated configured action through Main and the actual dispatchers.
--- @param route string Physical callback route.
--- @param mode string Normal, dry, or dry before deferred delivery.
--- @param action string Catalogue action.
--- @param body function Observes the action and controlled native boundaries.
local function with_action(route, mode, action, body)
	local saved = {}
	for name, value in pairs(package.loaded) do saved[name] = value end
	for name in pairs(saved) do
		if name:match("^modules%.") or name:match("^adapters%.") or name:match("^infra%.")
			or name:match("^config_binding") or name == "logger.shim" then package.loaded[name] = nil end
	end
	local path = os.tmpname()
	local injector
	local ok, detail = pcall(function()
		local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
		local source = file:read("*a"); assert(file:close())
		local arguments = mode == "dry" and { "--dry-run" } or {}
		if route == "observe" then arguments[#arguments + 1] = "--no-grab" end
		local environment = setmetatable({ arg = arguments }, { __index = _G })
		environment.Logger = helpers.make_logger_stub()
		local first = assert(source:find("local function parse_args()", 1, true))
		local last = assert(source:find("\n--- Prints the CLI usage.", first, true))
		environment.opts = evaluate(source:sub(first, last - 1) .. "\nreturn parse_args()", environment)
		helpers.assert_eq(environment.opts.tray, false, "The valid dry-run CLI has no graphical tray")
		helpers.assert_eq(environment.opts.grab, route ~= "observe")
		local configuration = assert(io.open(path, "wb"))
		configuration:write('[shortcuts]\nenabled = true\nwrap_text_if_selected = false\n'
			.. '[shortcuts.keyboard]\nctrl_j = "' .. action .. '"\n'
			.. '[shortcuts.tap_keys]\nnumber_row_left = "' .. action .. '"\n'
			.. '[shortcuts.script_control]\nchords_enabled = true\nscript_altgr_enter = "' .. action .. '"\n'
			.. '[gestures]\nenabled = ' .. tostring(route == "gesture") .. '\ntap_3 = "' .. action .. '"\n'
			.. '[gesture_parameters]\nkeyboard__ctrl_j__send_text = "ok"\n'
			.. 'tap_key__number_row_left__send_text = "ok"\nscript__script_altgr_enter__send_text = "ok"\n'
			.. 'tap_3__send_text = "ok"\n')
		assert(configuration:close())
		local routes = require("infra.config_paths")
		local config_route = routes.config
		routes.config = function(name) return name == "config.toml" and path or config_route(name) end
		require("tests.support.text_owner_fixture").with(function(guard)
			local world = { keys = {}, held = {}, reads = 0, writes = 0, lifecycle = 0, errors = {} }
			local logger = assert(dofile(require("infra.paths").shared("lua/logger/init.lua")))
			logger.set_sink(function() end)
			logger.set_error_observer(function(_, _, message) world.errors[#world.errors + 1] = message end)
			package.loaded["logger.shim"], environment.Logger = logger, logger
			local pending, clipboard = nil, "ok"
			local quote = require("adapters.shell_runner").quote
			package.loaded["adapters.shell_runner"] = {
				has_command = function() return true end, quote = quote,
				exec_checked = function(command)
					if command:find("zenity", 1, true) then return true, "" end
					world.reads = world.reads + 1; return true, clipboard
				end,
				with_exact_stdin = function(command, text) pending = text; return command end,
				run = function() clipboard = pending; world.writes = world.writes + 1; return true end,
			}
			package.loaded["infra.display_server"] = { UNKNOWN = "unknown", kind = function() return "x11" end,
				is_x11 = function() return true end, is_wayland = function() return false end }
			package.loaded["adapters.window_info"] = { focused_app_id = function() return "owned-editor" end }
			package.loaded["modules.gestures.touchpad_finder"] = { find = function()
				return { path = "controlled-touchpad", name = "controlled", max_fingers = 3 }
			end }
			package.loaded["adapters.evdev_reader"] = { TOUCHPAD = "touchpad",
				open = function() return true end, close = function() return true end }
			local layout = require("adapters.keyboard_layout")
			layout._set_table_for_test({ o = { keycode = 24, mods = {} }, k = { keycode = 37, mods = {} },
				O = { keycode = 24, mods = { "shift" } }, K = { keycode = 37, mods = { "shift" } } })
			injector = require("modules.hotstrings.injector")
			injector._set_nanosleep_for_test(function() end)
			injector._set_uinput({ is_open = function() return true end, emit = function(code, value)
				world.keys[#world.keys + 1] = { code, value }; world.held[code] = value == 1 or nil; return true
			end })
			local function lifecycle() world.lifecycle = world.lifecycle + 1 end
			environment.script_actions = require("modules.shortcuts.script_actions").new({ reset = lifecycle, reload = lifecycle, quit = lifecycle })
			for field, name in pairs({ shortcuts = "modules.shortcuts.manager", event_loop = "adapters.event_loop",
				gestures = "modules.gestures.manager", ActionHandlers = "modules.shortcuts.action_handlers",
				prediction_engine = "modules.llm.prediction_engine", keyboard_shortcuts = "modules.shortcuts.keyboard_shortcuts",
				keyboard_hook = "adapters.keyboard_hook", keylogger = "modules.keylogger.keylogger", Monotonic = "infra.monotonic",
				MagicKeySource = "modules.hotstrings.magic_key_source", script_chords = "modules.shortcuts.script_chords",
				tap_keys = "modules.shortcuts.tap_keys", hotstrings_config = "modules.hotstrings.hotstrings_config",
				MagicKey = "modules.hotstrings.magic_key", TapHold = "platform.remap.tap_hold_manager" }) do environment[field] = require(name) end
			environment.secure_focus_guard, environment.injector = guard, injector
			environment.input_capture_gate = require("infra.input_capture_gate").new()
			environment.on_char = function() error("The bound chord must not become a text callback") end
			environment.privacy_owners = {}
			evaluate(assert(source:match("\n\t\t(gestures%.init%b())")), environment)
			evaluate(assert(source:match("\n\t\t(shortcuts%.init%b())")), environment)
			first = assert(source:find("\tlocal wrap_on_type = ", 1, true))
			last = assert(source:find("\n\tprivacy_owners.end_wrap_selection", first, true))
			environment.wrap_on_type = evaluate(source:sub(first, last - 1) .. "\nreturn wrap_on_type", environment)
			for _, name in ipairs({ "script_chords", "tap_keys", "MagicKeySource" }) do
				evaluate(assert(source:match("\n\t(" .. name .. "%.init%b())")), environment)
			end
			first = assert(source:find("\tlocal function consume_bound_chord(detail)", 1, true))
			last = assert(source:find("\n\t-- Bind the same privacy owner", first, true))
			local consume = evaluate(source:sub(first, last - 1) .. "\nreturn on_consume", environment)
			local event = { code = 36, key = "j", char = "j", mods = { ctrl = true } }
			if route == "tap" then event = { code = 41, mods = {} }
			elseif route == "chord" then event = { code = 28, mods = { altgr = true } } end
			if route == "gesture" then
				world.consumed = environment.gestures.dispatch_gesture({ fingers = 3, tap = true })
			elseif route == "observe" then
				first = assert(source:find("\t\t\tlocal shortcuts_on = shortcuts ~= nil and shortcuts.is_enabled()", 1, true))
				last = assert(source:find("\n\t\tend", first, true))
				environment.detail = event
				evaluate(source:sub(first, last - 1), environment)
			else world.consumed = consume(event) end
			if route ~= "gesture" and route ~= "observe" then
				helpers.assert_eq(#world.keys, 0, "Text must wait until the physical callback has returned")
				helpers.assert_eq(world.reads, 0)
			end
			if mode == "late" then environment.opts.dry_run = true end
			environment.event_loop._run_idle_tick()
			world.paused = environment.script_actions.is_paused()
			world.inventory = environment.tap_keys.capture_collision_inventory()
			helpers.assert_eq(next(world.held), nil, "Every authored key must be released")
			helpers.assert_eq(#world.errors, 0, table.concat(world.errors, " / "))
			body(world)
		end)
	end)
	if injector then injector._set_uinput(nil); injector._set_nanosleep_for_test(nil) end
	os.remove(path)
	for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved) do package.loaded[name] = value end
	if not ok then error(detail, 0) end
end

helpers.describe("dry-run configured actions", function()
	for _, route in ipairs({ "keyboard", "tap", "chord", "gesture", "observe" }) do
		for _, action in ipairs({ "send_text", "paste_plain" }) do
			for _, mode in ipairs({ "normal", "dry" }) do
				helpers.it("dry-run-actions " .. route .. " " .. action .. " " .. mode, function()
					with_action(route, mode, action, function(world)
						if mode == "normal" then
							helpers.assert_eq(world.keys, { { 24, 1 }, { 24, 0 }, { 37, 1 }, { 37, 0 } })
							helpers.assert_eq(world.reads, action == "paste_plain" and 1 or 0)
						else
							helpers.assert_eq(#world.keys, 0, "Dry-run must not author text")
							helpers.assert_eq(world.reads, 0, "Dry-run must refuse before clipboard I/O")
							helpers.assert_eq(world.writes, 0)
						end
						if route ~= "observe" then helpers.assert_eq(world.consumed, mode == "normal", "A refused binding leaves its physical key available") end
						if route == "tap" then
							helpers.assert_true(world.inventory ~= nil)
							local claimed = false
							for _, claim in ipairs(world.inventory.claims) do if claim.code == 41 then claimed = true end end
							helpers.assert_eq(claimed, mode == "normal", "Collision claims match actual action admission")
						end
					end)
				end)
			end
		end
		for _, action in ipairs({ "script_pause_toggle", "script_reload", "script_quit" }) do
			helpers.it("dry-run-actions preserves " .. route .. " " .. action, function()
				with_action(route, "dry", action, function(world)
					helpers.assert_eq(world.lifecycle, 1)
					helpers.assert_eq(#world.keys, 0)
					helpers.assert_eq(world.reads, 0)
					if route ~= "observe" then helpers.assert_true(world.consumed) end
				end)
			end)
		end
	end
	for _, route in ipairs({ "keyboard", "tap", "chord" }) do
		helpers.it("dry-run-actions revalidates deferred " .. route, function()
			with_action(route, "late", "paste_plain", function(world)
				helpers.assert_true(world.consumed)
				helpers.assert_eq(#world.keys, 0)
				helpers.assert_eq(world.reads, 0)
			end)
		end)
	end
end)
