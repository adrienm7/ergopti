--- tests/unit/modules/shortcuts/test_script_control_extra_callback_errors.lua

--- ==============================================================================
--- MODULE: Script-Control Callback Error Regression Tests
--- DESCRIPTION:
--- Drives the real deferred sentinel and configurable-hotkey owners with
--- callbacks that throw. The event remains contained, the callback boundary
--- records one contextual traceback, and no failed action is reported as true.
---
--- ROOT CAUSE ENCODED:
--- Bare pcall sites discarded their false/error tuple. Script-control then
--- consumed a physical key after an extension produced no output, while the
--- configurable-hotkey owner and gesture dispatcher independently published
--- success after a thrown action.
--- ==============================================================================

local helpers = require("tests.helpers")
local ABSENT = {}

--- Creates a logger double whose callback boundary preserves exact results and
--- records the same context/traceback evidence as infra.logger.
--- @return table logger
--- @return table failures
local function callback_logger()
	local logger = helpers.make_logger_stub()
	local failures = {}
	logger.callback = function(_, label, fn, ...)
		local results = table.pack(xpcall(fn, debug.traceback, ...))
		if not results[1] then
			failures[#failures + 1] = tostring(label) .. ": " .. tostring(results[2])
		end
		return table.unpack(results, 1, results.n)
	end
	return logger, failures
end

--- Restores package.loaded entries changed by one isolated integration fixture.
--- @param saved table Module-name to prior value map.
local function restore_modules(saved)
	for name, value in pairs(saved) do
		package.loaded[name] = value == ABSENT and nil or value
	end
end

helpers.describe("HS-016 script-control callbacks are visible and truthful", function()
	helpers.it("contains a throwing extra on the real deferred sentinel path", function()
		local names = {
			"infra.logger", "infra.notifications", "infra.keycodes", "infra.i18n",
			"modules.gestures.engine", "modules.gestures.actions", "modules.keylogger",
			"adapters.event_provenance", "adapters.synthetic_input",
			"adapters.timer_scheduler", "adapters.key_state",
			"modules.shortcuts.script_control",
		}
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] or ABSENT end

		local logger, failures = callback_logger()
		local deferred = {}
		local tap_handler
		package.loaded["infra.logger"] = logger
		package.loaded["infra.notifications"] = {notify = function() end}
		package.loaded["infra.i18n"] = {get = function(key) return key end}
		package.loaded["infra.keycodes"] = {
			F13_KARABINER_RETURN = 0x6A,
			F14_KARABINER_BACKSPACE = 0x6B,
			F15_KARABINER_ESCAPE = 0x6C,
			BACKSPACE = 0x33,
			RETURN = 0x24,
			ESCAPE = 0x35,
		}
		package.loaded["modules.gestures.engine"] = {init = function() end}
		package.loaded["modules.gestures.actions"] = {
			SG_NAMES = {"none", "open_config"},
			get_label = function(name) return name end,
			execute_single = function() return false end,
		}
		package.loaded["modules.keylogger"] = {log_shortcut = function() end}
		package.loaded["adapters.event_provenance"] = {
			STATUS_UNREADABLE = "unreadable",
			classify_with_fence = function() return nil, "hardware", nil end,
		}
		package.loaded["adapters.synthetic_input"] = {
			defer_after_callback = function(_, callback)
				deferred[#deferred + 1] = callback
				return true
			end,
		}
		package.loaded["adapters.timer_scheduler"] = {
			every = function(_, callback) return {callback = callback}, true end,
			cancel = function() return true end,
		}
		package.loaded["adapters.key_state"] = {
			is_right_altgr_held = function() return false end,
			describe_held_modifiers = function() return "none" end,
		}
		package.loaded["modules.shortcuts.script_control"] = nil

		local subject = helpers.load_with_stubs("modules.shortcuts.script_control", {
			application = {
				frontmostApplication = function()
					return {title = function() return "CallbackTest" end}
				end,
			},
			eventtap = {
				new = function(_, callback)
					tap_handler = callback
					local tap = {enabled = false}
					function tap:start() self.enabled = true; return self end
					function tap:isEnabled() return self.enabled end
					function tap:stop() self.enabled = false; return self end
					return tap
				end,
				checkKeyboardModifiers = function() return {_raw = 0} end,
				event = {
					types = {keyDown = 10},
					properties = {
						eventSourceUserData = 1,
						eventSourceUnixProcessID = 2,
						eventSourceStateID = 3,
					},
					rawFlagMasks = {},
				},
			},
		})
		subject.set_shortcut_action("return_key", "open_config")
		subject.set_extras({open_config = function() error("extra exploded") end})
		local started = subject.start({}, {}, {}, nil)
		local consumed = tap_handler({
			getProperty = function() return 0 end,
			getKeyCode = function() return 0x6A end,
			getFlags = function() return {ctrl = true, shift = true} end,
		})
		local deferred_ok, deferred_handled = false, nil
		if #deferred == 1 then
			deferred_ok, deferred_handled = pcall(deferred[1])
		end
		local stopped = subject.stop()
		restore_modules(saved)

		helpers.assert_true(started, "the fixture must own the real eventtap callback")
		helpers.assert_true(consumed, "the tagged physical sentinel must reach deferred dispatch")
		helpers.assert_true(deferred_ok,
			"the external exception must not escape the deferred runloop callback")
		helpers.assert_eq(deferred_handled, false,
			"the deferred owner must not report a throwing extra as handled")
		helpers.assert_true(stopped)
		helpers.assert_eq(#failures, 1, "one throwing extra must emit one callback failure")
		helpers.assert_contains(failures[1], "Script-control extra 'open_config'")
		helpers.assert_contains(failures[1], "extra exploded")
		helpers.assert_contains(failures[1], "stack traceback")
	end)

	helpers.it("returns false when a configurable gesture action throws", function()
		local names = {
			"infra.logger", "infra.paths", "adapters.file_system",
			"adapters.hotkey_registrar", "modules.gestures.actions",
			"modules.shortcuts.keyboard_shortcuts",
		}
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] or ABSENT end

		local logger, failures = callback_logger()
		local bound_callback
		package.loaded["infra.logger"] = logger
		package.loaded["infra.paths"] = {shared = function() return "catalogue.json" end}
		package.loaded["adapters.file_system"] = {
			read = function() return '{"keys":[{"id":"a","label":"A"}]}' end,
		}
		package.loaded["adapters.hotkey_registrar"] = {
			bind = function(_, callback)
				bound_callback = callback
				return "callback-hotkey"
			end,
			unbind = function() return true end,
		}
		package.loaded["modules.gestures.actions"] = {
			execute_single = function() error("gesture exploded") end,
		}
		package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil

		local subject = helpers.load_with_stubs("modules.shortcuts.keyboard_shortcuts", {
			settings = {
				getKeys = function() return {"keyboard_shortcut_cmd_a"} end,
				get = function() return "throwing_action" end,
				set = function() return true end,
			},
			json = {decode = function() return {keys = {{id = "a", label = "A"}}} end},
		})
		local started = subject.start()
		local call_ok, handled = pcall(bound_callback)
		local stopped = subject.stop()
		restore_modules(saved)

		helpers.assert_true(started)
		helpers.assert_true(call_ok, "the hotkey callback must contain the gesture exception")
		helpers.assert_eq(handled, false,
			"a thrown gesture action cannot be reported as handled")
		helpers.assert_true(stopped)
		helpers.assert_eq(#failures, 1)
		helpers.assert_contains(failures[1], "Configurable shortcut 'cmd_a'")
		helpers.assert_contains(failures[1], "gesture exploded")
		helpers.assert_contains(failures[1], "stack traceback")
	end)
end)

return true
