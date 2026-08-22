--- tests/unit/modules/shortcuts/test_copy_pixel_color_clipboard_refusal.lua

--- ==============================================================================
--- MODULE: Pixel-color clipboard refusal
--- DESCRIPTION:
--- Drives both asynchronous TaskLifecycle completions. A native setContents(false)
--- must produce an error notification, never the user-visible "copied" success.
--- ==============================================================================

local helpers = require("tests.helpers")


helpers.describe("copy_pixel_color: native clipboard refusal is not success", function()
	helpers.it("reports an error when setContents returns false", function()
		local callbacks = {}
		local notifications = {}
		local logs = {}
		local task_lifecycle = {
			native = function(_label, _path, callback, _args)
				callbacks[#callbacks + 1] = callback
				return {
					start = function(self) return self end,
					isRunning = function() return true end,
					terminate = function(self) return self end,
				}
			end,
			start = function(task) return task:start() and true or false end,
		}
		package.loaded["adapters.task_lifecycle"] = task_lifecycle
		package.loaded["infra.notifications"] = {
			notify = function(message, _, level)
				notifications[#notifications + 1] = { message = message, level = level }
			end,
		}
		package.loaded["infra.i18n"] = {
			get = function(key) return key end,
		}
		package.loaded["infra.logger"] = setmetatable({
			error = function(_log, message, ...)
				logs[#logs + 1] = string.format(message, ...)
			end,
		}, { __index = function() return function() end end })

		local actions = helpers.load_with_stubs("modules.shortcuts.actions.system_pixel", {
			mouse = { absolutePosition = function() return { x = 10, y = 20 } end },
			pasteboard = { setContents = function() return false end },
		})
		actions.copy_pixel_color()
		helpers.assert_eq(#callbacks, 1, "screencapture must be launched")
		callbacks[1](0, "", "")
		helpers.assert_eq(#callbacks, 2, "pixel decoder must follow a successful capture")
		callbacks[2](0, "#a1b2c3\n", "")

		helpers.assert_eq(#notifications, 1)
		helpers.assert_eq(notifications[1].level, "error",
			"a refused native write must not show the copied-success notification")
		helpers.assert_eq(notifications[1].message, "shortcuts.pixel_read_error")
		helpers.assert_eq(#logs, 1,
			"the async failure must reach the file logger rather than only HS Console")
	end)

	helpers.it("keeps terminal clipboard delivery visible to a re-entrant PAUSE", function()
		local callbacks = {}
		local clipboard = "original"
		local nested_pause = nil
		local actions
		package.loaded["adapters.task_lifecycle"] = {
			native = function(_label, _path, callback, _args)
				callbacks[#callbacks + 1] = callback
				return {
					start = function() return true end,
					isRunning = function() return true end,
					terminate = function() return true end,
				}
			end,
			start = function(task) return task.start() == true end,
		}
		package.loaded["infra.notifications"] = { notify = function() return true end }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.logger"] = helpers.make_logger_stub()

		actions = helpers.load_with_stubs("modules.shortcuts.actions.system_pixel", {
			mouse = { absolutePosition = function() return { x = 10, y = 20 } end },
			pasteboard = {
				setContents = function(value)
					nested_pause = actions.pause_pixel_actions()
					clipboard = value
					return true
				end,
			},
		})

		helpers.assert_eq(actions.copy_pixel_color(), true)
		callbacks[1](0, "", "")
		helpers.assert_eq(#callbacks, 2)
		callbacks[2](0, "#a1b2c3\n", "")
		helpers.assert_eq(nested_pause, false,
			"PAUSE cannot certify settlement inside clipboard delivery")
		helpers.assert_eq(clipboard, "#a1b2c3")
		helpers.assert_eq(actions.is_pixel_actions_paused(), true)
		helpers.assert_eq(actions.has_pending_pixel_action(), false)
		helpers.assert_eq(actions.pause_pixel_actions(), true)
	end)
end)
