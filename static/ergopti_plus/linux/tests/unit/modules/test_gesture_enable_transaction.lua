--- tests/unit/modules/test_gesture_enable_transaction.lua

--- ==============================================================================
--- MODULE: Gesture Enable Transaction
--- DESCRIPTION:
--- Proves that the master gesture state becomes visible only after the touchpad
--- reader opens, including the disabled-at-boot path used by the daemon.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = require("tests.fakes")

local MODULES = {
	"modules.gestures.manager",
	"modules.gestures.touchpad_finder",
	"modules.gestures.mt_decoder",
	"adapters.evdev_reader",
	"logger.shim",
}

--- Runs one manager instance over deterministic device, decoder, and log fakes.
--- @param open_fails boolean
--- @param body function
local function with_manager(open_fails, body)
	local saved = {}
	for _, name in ipairs(MODULES) do saved[name] = package.loaded[name] end

	local errors = {}
	local logger = helpers.make_logger_stub()
	logger.error = function(_scope, message, ...)
		errors[#errors + 1] = string.format(message, ...)
	end

	local reader = Fakes.evdev_reader({
		events = { { type = 0, code = 0, value = 0 } },
		open_fails = open_fails,
	})
	local real_open = reader.open
	reader.open = function(path, slot)
		reader.open_attempt = { path = path, slot = slot }
		return real_open(path, slot)
	end

	package.loaded["logger.shim"] = logger
	package.loaded["adapters.evdev_reader"] = reader
	package.loaded["modules.gestures.touchpad_finder"] = {
		find = function()
			return {
				path = "/dev/input/event-test-touchpad",
				name = "Test Touchpad",
				max_fingers = 5,
				semi_mt = false,
			}
		end,
	}
	package.loaded["modules.gestures.mt_decoder"] = {
		new = function()
			return {
				feed = function()
					return { fingers = 3, direction = "left", tap = false }
				end,
			}
		end,
	}
	package.loaded["modules.gestures.manager"] = nil

	local ok, result = pcall(function()
		local manager = require("modules.gestures.manager")
		manager.init({ enabled = false, persist = false })
		return body(manager, reader, errors)
	end)

	for _, name in ipairs(MODULES) do package.loaded[name] = saved[name] end
	if not ok then error(result, 0) end
	return result
end

helpers.describe("gestures: enabling after disabled boot", function()

	helpers.it("opens the touchpad before publishing enabled and dispatches its events", function()
		local result = with_manager(false, function(manager, reader)
			helpers.assert_eq(manager.is_enabled(), false, "the daemon starts this feature disabled")
			local enabled = manager.enable()
			local dispatched = {}
			local real_dispatch = manager.dispatch_gesture
			manager.dispatch_gesture = function(gesture)
				dispatched[#dispatched + 1] = gesture
				return real_dispatch(gesture)
			end
			manager.pump()
			return {
				enabled = enabled,
				state = manager.is_enabled(),
				reading = manager.is_reading(),
				open_attempt = reader.open_attempt,
				dispatched = dispatched,
			}
		end)

		helpers.assert_true(result.enabled and result.state,
			"enable must report and publish success after the reader opens")
		helpers.assert_true(result.reading, "enabled gestures must have a live reader")
		helpers.assert_eq(result.open_attempt.path, "/dev/input/event-test-touchpad")
		helpers.assert_eq(result.open_attempt.slot, "touchpad")
		helpers.assert_eq(#result.dispatched, 1,
			"the first event after a hot enable must reach gesture dispatch")
		helpers.assert_eq(result.dispatched[1].direction, "left")
	end)

	helpers.it("keeps the feature disabled and logs when opening the reader fails", function()
		local result = with_manager(true, function(manager, reader, errors)
			return {
				enabled = manager.enable(),
				state = manager.is_enabled(),
				reading = manager.is_reading(),
				open_attempt = reader.open_attempt,
				errors = errors,
			}
		end)

		helpers.assert_eq(result.enabled, false, "a failed open must be an enable failure")
		helpers.assert_eq(result.state, false, "failure must not publish an enabled state")
		helpers.assert_eq(result.reading, false, "failure must leave no reader to pump")
		helpers.assert_eq(result.open_attempt.path, "/dev/input/event-test-touchpad")
		helpers.assert_true(#result.errors >= 1, "the failed transition must be visible in the error log")
		helpers.assert_true(table.concat(result.errors, "\n"):find("could not start", 1, true) ~= nil,
			"the error must explain why the feature remained disabled")
	end)

end)
