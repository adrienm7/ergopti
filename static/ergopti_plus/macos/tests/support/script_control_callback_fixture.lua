--- tests/support/script_control_callback_fixture.lua

--- ==============================================================================
--- MODULE: Script Control Callback Fixture
--- DESCRIPTION:
--- Loads real shortcut callback owners with observable native boundaries.
--- ==============================================================================

local helpers = require("tests.helpers")

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

local M = {}

--- Runs the sentinel callback owner in its fixture.
--- @param callback function Receives the constructed subject and observations.
function M.with_sentinel(callback)
	local names = {
		"infra.logger", "infra.notifications", "infra.keycodes", "infra.i18n",
		"modules.gestures.engine", "modules.gestures.actions", "modules.keylogger",
		"adapters.event_provenance", "adapters.synthetic_input",
		"adapters.timer_scheduler", "adapters.key_state",
		"modules.shortcuts.script_control",
	}
	return helpers.with_stub_scope(names, function()
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
		return callback({
			subject = subject, failures = failures,
			deferred = deferred, get_tap_handler = function() return tap_handler end,
		})
	end)
end

--- Runs the configurable callback owner in its fixture.
--- @param callback function Receives the constructed subject and observations.
function M.with_configurable(callback)
	local names = {
		"infra.logger", "infra.paths", "adapters.file_system",
		"adapters.hotkey_registrar", "adapters.storage", "modules.gestures.actions",
		"modules.shortcuts.keyboard_shortcuts", "chord",
	}
	return helpers.with_stub_scope(names, function()
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
		package.loaded["adapters.storage"] = nil
		package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil

		local subject = helpers.load_with_stubs("modules.shortcuts.keyboard_shortcuts", {
			settings = {
				getKeys = function() return {"ergopti.keyboard_shortcut_cmd_a"} end,
				get = function() return "throwing_action" end,
				set = function() return true end,
			},
			json = {decode = function() return {keys = {{id = "a", label = "A"}}} end},
		})
		return callback({
			subject = subject, failures = failures,
			get_bound_callback = function() return bound_callback end,
		})
	end)
end

return M
