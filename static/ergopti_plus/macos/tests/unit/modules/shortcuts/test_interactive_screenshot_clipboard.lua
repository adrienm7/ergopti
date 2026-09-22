--- tests/unit/modules/shortcuts/test_interactive_screenshot_clipboard.lua

--- ==============================================================================
--- MODULE: Ctrl+H interactive screenshot reaches the clipboard
--- DESCRIPTION:
--- In the packaged ErgoptiPlus.app, Ctrl+H showed the macOS selector and then
--- left nothing on the clipboard. The action ran `screencapture -i -c` without
--- checking Screen Recording (the packaged runtime has its own identity, so a
--- stock Hammerspoon grant does not apply), logged every non-zero exit as a
--- warning, and announced success on exit 0 without looking at the clipboard.
--- These cases drive the real system_pixel owner, the real capture flow and the
--- real screen_capture adapter against native doubles.
--- ==============================================================================

local helpers = require("tests.helpers")

local SETTINGS_URL =
	"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

local SUBJECT_MODULES = {
	"adapters.task_lifecycle",
	"adapters.file_system",
	"adapters.screen_capture",
	"infra.notifications",
	"infra.logger",
	"modules.shortcuts.actions.system_pixel",
	"modules.shortcuts.actions.screen_capture_flow",
}





-- ==================================
-- ==================================
-- ======= 1/ Native Fixture ========
-- ==================================
-- ==================================

--- Runs one scenario against the real owner and faithful native doubles.
--- @param options table|nil permission (true/false/"throw"), drop_image.
--- @param scenario function Receives (subject, fixture).
local function with_pixel(options, scenario)
	local opts = options or {}
	helpers.with_stub_scope(SUBJECT_MODULES, function()
		local f = {
			tasks = {},
			notifications = {},
			logs = { info = {}, warn = {}, error = {} },
			opened = {},
			prompts = {},
			temp_paths = {},
			removed = {},
			files = {},
			pasteboard = { count = 10, image = nil, writes = {} },
		}

		package.loaded["adapters.task_lifecycle"] = {
			native = function(label, path, callback, args)
				local task = { label = label, path = path, args = args, callback = callback }
				f.tasks[#f.tasks + 1] = task
				return {
					start = function() return true end,
					isRunning = function() return true end,
					terminate = function(self) return self end,
				}
			end,
			start = function() return true end,
		}
		package.loaded["adapters.file_system"] = {
			create_secure_temp_file = function()
				local path = "/private/tmp/ergopti-shot-" .. (#f.temp_paths + 1)
				f.temp_paths[#f.temp_paths + 1] = path
				f.files[path] = 0
				return path
			end,
			remove_exact = function(path)
				f.removed[#f.removed + 1] = path
				f.files[path] = nil
				return true
			end,
			classify_no_follow = function(path)
				if f.files[path] == nil then return nil, "absent" end
				return { mode = "file", size = f.files[path] }, "ok"
			end,
		}
		package.loaded["infra.notifications"] = {
			notify = function(title, body, kind)
				f.notifications[#f.notifications + 1] = { title = title, body = body, kind = kind }
				return true
			end,
		}
		local logger = helpers.make_logger_stub()
		for _, level in ipairs({ "info", "warn", "error" }) do
			logger[level] = function(_, message, ...)
				f.logs[level][#f.logs[level] + 1] = string.format(tostring(message), ...)
			end
		end
		package.loaded["infra.logger"] = logger

		local subject = helpers.load_with_stubs("modules.shortcuts.actions.system_pixel", {
			screenRecordingState = function(prompt)
				f.prompts[#f.prompts + 1] = prompt
				if opts.permission == "throw" then error("tcc unavailable") end
				if prompt == true then return false end
				if opts.permission == nil then return true end
				return opts.permission
			end,
			urlevent = { openURL = function(url)
				f.opened[#f.opened + 1] = url
				return true
			end },
			mouse = { absolutePosition = function() return { x = 10, y = 20 } end },
			image = { imageFromPath = function(path)
				if (f.files[path] or 0) > 0 then return { path = path } end
				return nil
			end },
			pasteboard = {
				setContents = function() return true end,
				changeCount = function() return f.pasteboard.count end,
				readImage = function() return f.pasteboard.image end,
				writeObjects = function(image)
					f.pasteboard.writes[#f.pasteboard.writes + 1] = image
					f.pasteboard.count = f.pasteboard.count + 1
					if not opts.drop_image then f.pasteboard.image = image end
					return true
				end,
			},
		})

		--- Simulates screencapture writing an image into its file target.
		function f.write_capture(task)
			f.files[task.args[#task.args]] = 4096
		end
		--- Simulates screencapture sending the image to the clipboard itself,
		--- which is what a held Control key does in interactive mode.
		function f.capture_to_clipboard()
			f.pasteboard.count = f.pasteboard.count + 1
			f.pasteboard.image = { source = "screencapture" }
		end
		function f.count_prompts()
			local n = 0
			for _, prompt in ipairs(f.prompts) do if prompt == true then n = n + 1 end end
			return n
		end

		scenario(subject, f)
	end)
end

--- Asserts the single error notification a failed capture must produce.
--- @param f table Fixture.
local function assert_clipboard_failure(f)
	helpers.assert_eq(#f.notifications, 1, "a failed capture must be announced exactly once")
	helpers.assert_eq(f.notifications[1].kind, "error")
	helpers.assert_eq(f.notifications[1].title, "shortcuts.screenshot_clipboard_failed")
end





-- ======================================
-- ======================================
-- ======= 2/ Permission Gate ===========
-- ======================================
-- ======================================

helpers.describe("Ctrl+H interactive screenshot: Screen Recording gate", function()
	helpers.it("does not launch screencapture without the permission", function()
		with_pixel({ permission = false }, function(subject, f)
			helpers.assert_eq(subject.interactive_screenshot(), false)
			helpers.assert_eq(#f.tasks, 0,
				"without Screen Recording the capture fails after the selection")
			helpers.assert_eq(#f.temp_paths, 0, "a refused capture must not allocate a file")
			helpers.assert_eq(subject.has_pending_pixel_action(), false)
		end)
	end)

	helpers.it("tells the user in a translated error notification", function()
		with_pixel({ permission = false }, function(subject, f)
			subject.interactive_screenshot()
			helpers.assert_eq(#f.notifications, 1)
			helpers.assert_eq(f.notifications[1].title, "shortcuts.screen_recording_required_title")
			helpers.assert_eq(f.notifications[1].body, "shortcuts.screen_recording_required")
			helpers.assert_eq(f.notifications[1].kind, "error")
		end)
	end)

	helpers.it("opens System Settings on the Screen Recording pane", function()
		with_pixel({ permission = false }, function(subject, f)
			subject.interactive_screenshot()
			helpers.assert_eq(f.opened, { SETTINGS_URL })
		end)
	end)

	helpers.it("asks macOS for its prompt once, not on every refused shortcut", function()
		with_pixel({ permission = false }, function(subject, f)
			subject.interactive_screenshot()
			subject.interactive_screenshot()
			helpers.assert_eq(f.count_prompts(), 1,
				"the prompt registers the runtime in the list; one request is enough")
			helpers.assert_eq(#f.notifications, 2, "every refusal is still explained")
			helpers.assert_eq(#f.opened, 2)
		end)
	end)

	helpers.it("refuses the same way when the permission query itself fails", function()
		with_pixel({ permission = "throw" }, function(subject, f)
			helpers.assert_eq(subject.interactive_screenshot(), false)
			helpers.assert_eq(#f.tasks, 0)
			helpers.assert_eq(f.notifications[1].title, "shortcuts.screen_recording_required_title")
			helpers.assert_contains(f.logs.error[1], "tcc unavailable")
		end)
	end)

	helpers.it("the pixel color reader is gated the same way", function()
		with_pixel({ permission = false }, function(subject, f)
			helpers.assert_eq(subject.copy_pixel_color(), false)
			helpers.assert_eq(#f.tasks, 0,
				"without the grant the capture omits windows and the wrong color is copied")
			helpers.assert_eq(f.notifications[1].title, "shortcuts.screen_recording_required_title")
			helpers.assert_eq(f.opened, { SETTINGS_URL })
		end)
	end)

	helpers.it("a granted runtime launches both captures (positive control)", function()
		with_pixel(nil, function(subject, f)
			helpers.assert_eq(subject.copy_pixel_color(), true)
			helpers.assert_eq(#f.tasks, 1)
			helpers.assert_eq(#f.notifications, 0)
			helpers.assert_eq(#f.opened, 0)
		end)
	end)
end)





-- ======================================
-- ======================================
-- ======= 3/ Capture Verdict ===========
-- ======================================
-- ======================================

helpers.describe("Ctrl+H interactive screenshot: verified clipboard result", function()
	helpers.it("captures into an owned file, never with -c", function()
		with_pixel(nil, function(subject, f)
			helpers.assert_eq(subject.interactive_screenshot(), true)
			helpers.assert_eq(f.tasks[1].path, "/usr/sbin/screencapture")
			helpers.assert_eq(f.tasks[1].args, { "-i", "-t", "png", f.temp_paths[1] },
				"-c hands the image to screencapture and leaves nothing to verify; a "
				.. "held Control key even turns it away from the clipboard")
		end)
	end)

	helpers.it("puts the captured image on the clipboard and announces success", function()
		with_pixel(nil, function(subject, f)
			subject.interactive_screenshot()
			f.write_capture(f.tasks[1])
			f.tasks[1].callback(0, "", "")
			helpers.assert_eq(#f.pasteboard.writes, 1)
			helpers.assert_eq(f.pasteboard.writes[1].path, f.temp_paths[1])
			helpers.assert_eq(f.pasteboard.image, f.pasteboard.writes[1],
				"the image must actually be on the pasteboard")
			helpers.assert_eq(#f.notifications, 1)
			helpers.assert_eq(f.notifications[1].kind, "success")
			helpers.assert_eq(f.notifications[1].title, "shortcuts.screenshot_copied")
		end)
	end)

	helpers.it("removes the temporary capture file after success", function()
		with_pixel(nil, function(subject, f)
			subject.interactive_screenshot()
			f.write_capture(f.tasks[1])
			f.tasks[1].callback(0, "", "")
			helpers.assert_eq(f.removed, { f.temp_paths[1] })
			helpers.assert_eq(subject.has_pending_pixel_action(), false)
		end)
	end)

	helpers.it("stays silent when the user cancels with Escape", function()
		with_pixel(nil, function(subject, f)
			subject.interactive_screenshot()
			f.tasks[1].callback(1, "", "")
			helpers.assert_eq(#f.notifications, 0, "a cancel is not an error")
			helpers.assert_eq(#f.pasteboard.writes, 0)
			helpers.assert_eq(f.removed, { f.temp_paths[1] })
			helpers.assert_contains(f.logs.info[#f.logs.info], "cancelled")
		end)
	end)

	helpers.it("notifies a failed capture and logs its exit code", function()
		with_pixel(nil, function(subject, f)
			subject.interactive_screenshot()
			f.tasks[1].callback(1, "", "could not create image from rect\n")
			assert_clipboard_failure(f)
			local logged = table.concat(f.logs.error, "\n")
			helpers.assert_contains(logged, "code 1")
			helpers.assert_contains(logged, "could not create image from rect")
		end)
	end)

	helpers.it("treats exit 0 without any image as an error, never as success", function()
		with_pixel(nil, function(subject, f)
			subject.interactive_screenshot()
			f.tasks[1].callback(0, "", "")
			assert_clipboard_failure(f)
			helpers.assert_contains(table.concat(f.logs.error, "\n"), "produced no image")
		end)
	end)

	helpers.it("reports an error when the clipboard does not hold the image after the write", function()
		with_pixel({ drop_image = true }, function(subject, f)
			subject.interactive_screenshot()
			f.write_capture(f.tasks[1])
			f.tasks[1].callback(0, "", "")
			assert_clipboard_failure(f)
		end)
	end)

	helpers.it("does not trust a file written by a capture that exited non-zero", function()
		with_pixel(nil, function(subject, f)
			subject.interactive_screenshot()
			f.write_capture(f.tasks[1])
			f.tasks[1].callback(1, "", "")
			assert_clipboard_failure(f)
			helpers.assert_eq(#f.pasteboard.writes, 0)
		end)
	end)

	helpers.it("accepts a capture sent to the clipboard by a held Control key", function()
		with_pixel(nil, function(subject, f)
			subject.interactive_screenshot()
			f.capture_to_clipboard()
			f.tasks[1].callback(0, "", "")
			helpers.assert_eq(#f.notifications, 1)
			helpers.assert_eq(f.notifications[1].kind, "success")
			helpers.assert_eq(#f.pasteboard.writes, 0,
				"the clipboard already holds the capture; it must not be overwritten")
		end)
	end)

	helpers.it("counts the clipboard change only when it happened during the capture", function()
		with_pixel(nil, function(subject, f)
			f.capture_to_clipboard()
			subject.interactive_screenshot()
			f.tasks[1].callback(0, "", "")
			assert_clipboard_failure(f)
		end)
	end)
end)
