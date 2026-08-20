--- tests/unit/modules/shortcuts/test_copy_pixel_color_clipboard_refusal.lua

--- ==============================================================================
--- MODULE: Pixel-color clipboard refusal
--- DESCRIPTION:
--- Drives both asynchronous ShellRunner completions. A native setContents(false)
--- must produce an error notification, never the user-visible "copied" success.
--- ==============================================================================

local helpers = require("tests.helpers")


helpers.describe("copy_pixel_color: native clipboard refusal is not success", function()
	helpers.it("reports an error when setContents returns false", function()
		local callbacks = {}
		local notifications = {}
		local logs = {}
		local shell_runner = {
			spawn = function(_path, _args, callback)
				callbacks[#callbacks + 1] = callback
				return { start = function() return true end }
			end,
		}
		package.loaded["adapters.shell_runner"] = shell_runner
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
end)
