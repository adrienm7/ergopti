--- tests/unit/modules/shortcuts/test_screenshot_save_capture_verdicts.lua

--- ==============================================================================
--- MODULE: Configurable and gesture screenshots verify their result
--- DESCRIPTION:
--- The shared screenshot owner behind the configurable shortcuts and the
--- gestures had the same defects as Ctrl+H: no Screen Recording check, `-c`
--- clipboard captures that were never verified, and every non-zero exit
--- reported as a failure even when the user pressed Escape. These cases drive
--- the real screenshot_save owner, the real capture flow and the real
--- screen_capture adapter against ShellRunner and native doubles.
--- ==============================================================================

local helpers = require("tests.helpers")

local SETTINGS_URL =
	"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

local SUBJECT_MODULES = {
	"adapters.file_system",
	"adapters.screen_capture",
	"adapters.shell_runner",
	"infra.i18n",
	"infra.logger",
	"infra.notifications",
	"modules.shortcuts.actions.screenshot_save",
	"modules.shortcuts.actions.screen_capture_flow",
}





-- ==================================
-- ==================================
-- ======= 1/ Native Fixture ========
-- ==================================
-- ==================================

--- Runs one scenario against the real shared owner.
--- @param options table|nil permission (true/false), drop_image.
--- @param scenario function Receives (subject, fixture).
local function with_screenshot(options, scenario)
	local opts = options or {}
	helpers.with_fresh_modules(SUBJECT_MODULES, function()
		local saved_hs = rawget(_G, "hs")
		local f = {
			tasks = {},
			notifications = {},
			errors = {},
			infos = {},
			opened = {},
			prompts = 0,
			temp_paths = {},
			removed = {},
			files = {},
			pasteboard = { count = 3, image = nil, writes = {} },
		}

		package.loaded["adapters.file_system"] = {
			expand_path = function(path)
				if path == "~" then return "/Users/alice" end
				return path
			end,
			create_secure_temp_file = function()
				local path = "/private/tmp/ergopti-gesture-shot-" .. (#f.temp_paths + 1)
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
		package.loaded["adapters.shell_runner"] = {
			spawn = function(executable, args, on_done)
				local record = { executable = executable, args = args, on_done = on_done }
				f.tasks[#f.tasks + 1] = record
				local handle = { settled = false, observers = {} }
				function handle.start() return true end
				function handle.isSettled() return handle.settled end
				function handle.onSettled(observer)
					if handle.settled then observer()
					else handle.observers[#handle.observers + 1] = observer end
					return true
				end
				function handle.terminate() return true, "pending" end
				--- Delivers the native terminal, then settles observers.
				function record.finish(...)
					handle.settled = true
					on_done(...)
					for _, observer in ipairs(handle.observers) do observer() end
					handle.observers = {}
				end
				return handle
			end,
		}
		package.loaded["infra.i18n"] = { get = function(key)
			if key == "shortcuts.saved" then return "Saved %s" end
			return key
		end }
		package.loaded["infra.logger"] = {
			debug = function() end,
			info = function(_, message, ...)
				f.infos[#f.infos + 1] = string.format(tostring(message), ...)
			end,
			warn = function() end,
			error = function(_, message, ...)
				f.errors[#f.errors + 1] = string.format(tostring(message), ...)
			end,
		}
		package.loaded["infra.notifications"] = {
			notify = function(title, body, kind)
				f.notifications[#f.notifications + 1] = { title = title, body = body, kind = kind }
				return true
			end,
		}
		_G.hs = {
			processInfo = { processID = 4242 },
			timer = { absoluteTime = function() return 1000 end },
			screenRecordingState = function(prompt)
				if prompt == true then
					f.prompts = f.prompts + 1
					return false
				end
				if opts.permission == nil then return true end
				return opts.permission
			end,
			urlevent = { openURL = function(url)
				f.opened[#f.opened + 1] = url
				return true
			end },
			image = { imageFromPath = function(path)
				if (f.files[path] or 0) > 0 then return { path = path } end
				return nil
			end },
			pasteboard = {
				changeCount = function() return f.pasteboard.count end,
				readImage = function() return f.pasteboard.image end,
				writeObjects = function(image)
					f.pasteboard.writes[#f.pasteboard.writes + 1] = image
					f.pasteboard.count = f.pasteboard.count + 1
					if not opts.drop_image then f.pasteboard.image = image end
					return true
				end,
			},
		}

		--- Returns the tasks that ran one executable.
		function f.runs(executable)
			local found = {}
			for _, task in ipairs(f.tasks) do
				if task.executable == executable then found[#found + 1] = task end
			end
			return found
		end
		--- Simulates screencapture writing its image into its last argument.
		function f.write_capture(task)
			f.files[task.args[#task.args]] = 2048
		end
		--- Simulates a held Control key sending the capture to the clipboard.
		function f.capture_to_clipboard()
			f.pasteboard.count = f.pasteboard.count + 1
			f.pasteboard.image = { source = "screencapture" }
		end

		local ok, err = xpcall(function()
			scenario(require("modules.shortcuts.actions.screenshot_save"), f)
		end, debug.traceback)
		_G.hs = saved_hs
		-- with_fresh_modules restores the original entry; clearing the stub here
		-- keeps the dangling-install scanner (test_shell_runner_stub_restore) exact.
		package.loaded["adapters.shell_runner"] = nil
		if not ok then error(err, 0) end
	end)
end

--- Starts a save and completes its mkdir phase.
--- @param subject table Screenshot owner.
--- @param f table Fixture.
--- @param flags table Capture flags.
--- @return table capture Capture task record.
local function save_to_capture(subject, f, flags)
	helpers.assert_eq(subject.save(flags, "reg", "gestures"), true)
	f.runs("/bin/mkdir")[1].finish(0, "", "")
	return f.runs("/usr/sbin/screencapture")[1]
end

--- Asserts exactly one error notification with the given message key.
--- @param f table Fixture.
--- @param key string Expected locale key.
local function assert_one_error(f, key)
	helpers.assert_eq(#f.notifications, 1, "a failed capture must be announced exactly once")
	helpers.assert_eq(f.notifications[1].kind, "error")
	helpers.assert_eq(f.notifications[1].title, key)
end





-- ======================================
-- ======================================
-- ======= 2/ Permission Gate ===========
-- ======================================
-- ======================================

helpers.describe("shared screenshot owner: Screen Recording gate", function()
	helpers.it("a clipboard capture without the permission launches nothing", function()
		with_screenshot({ permission = false }, function(subject, f)
			helpers.assert_eq(subject.capture({ "-i" }, "gestures"), false)
			helpers.assert_eq(#f.tasks, 0)
			helpers.assert_eq(#f.temp_paths, 0)
			helpers.assert_eq(f.notifications[1].title, "shortcuts.screen_recording_required_title")
			helpers.assert_eq(f.notifications[1].body, "shortcuts.screen_recording_required")
			helpers.assert_eq(f.opened, { SETTINGS_URL })
			helpers.assert_eq(f.prompts, 1)
			helpers.assert_eq(subject.has_pending_screenshot_action("gestures"), false)
		end)
	end)

	helpers.it("a saved capture without the permission does not even create the folder", function()
		with_screenshot({ permission = false }, function(subject, f)
			helpers.assert_eq(subject.save({ "-i" }, "reg", "gestures"), false)
			helpers.assert_eq(#f.tasks, 0)
			helpers.assert_eq(f.notifications[1].title, "shortcuts.screen_recording_required_title")
			helpers.assert_eq(f.opened, { SETTINGS_URL })
		end)
	end)
end)





-- ======================================
-- ======================================
-- ======= 3/ Clipboard Captures ========
-- ======================================
-- ======================================

helpers.describe("shared screenshot owner: verified clipboard captures", function()
	helpers.it("rejects a -c request instead of launching an unverifiable capture", function()
		with_screenshot(nil, function(subject, f)
			for _, flags in ipairs({ { "-c" }, { "-ci" }, { "-cw" } }) do
				helpers.assert_eq(subject.capture(flags, "gestures"), false)
			end
			helpers.assert_eq(#f.tasks, 0)
			helpers.assert_eq(#f.notifications, 3)
			helpers.assert_eq(f.notifications[1].kind, "error")
		end)
	end)

	helpers.it("copies the captured file to the clipboard and announces success", function()
		with_screenshot(nil, function(subject, f)
			helpers.assert_eq(subject.capture({ "-i" }, "gestures"), true)
			local capture = f.tasks[1]
			helpers.assert_eq(capture.args, { "-i", "-t", "png", f.temp_paths[1] })
			f.write_capture(capture)
			capture.finish(0, "", "")
			helpers.assert_eq(#f.pasteboard.writes, 1)
			helpers.assert_eq(f.pasteboard.image, f.pasteboard.writes[1])
			helpers.assert_eq(#f.notifications, 1)
			helpers.assert_eq(f.notifications[1].kind, "success")
			helpers.assert_eq(f.notifications[1].title, "shortcuts.screenshot_copied")
			helpers.assert_eq(f.removed, { f.temp_paths[1] })
			helpers.assert_eq(subject.has_pending_screenshot_action("gestures"), false)
		end)
	end)

	helpers.it("stays silent when an interactive capture is cancelled", function()
		with_screenshot(nil, function(subject, f)
			subject.capture({ "-w" }, "gestures")
			f.tasks[1].finish(1, "", "")
			helpers.assert_eq(#f.notifications, 0)
			helpers.assert_eq(#f.errors, 0)
			helpers.assert_eq(f.removed, { f.temp_paths[1] })
		end)
	end)

	helpers.it("notifies an interactive failure and logs its exit code", function()
		with_screenshot(nil, function(subject, f)
			subject.capture({ "-i" }, "gestures")
			f.tasks[1].finish(1, "", "could not create image from rect")
			assert_one_error(f, "shortcuts.screenshot_clipboard_failed")
			helpers.assert_contains(f.errors[1], "code 1")
		end)
	end)

	helpers.it("a full-screen capture has no cancel: a silent non-zero exit is a failure", function()
		with_screenshot(nil, function(subject, f)
			subject.capture({}, "gestures")
			helpers.assert_eq(f.tasks[1].args, { "-t", "png", f.temp_paths[1] })
			f.tasks[1].finish(1, "", "")
			assert_one_error(f, "shortcuts.screenshot_clipboard_failed")
		end)
	end)

	helpers.it("treats exit 0 without an image as an error", function()
		with_screenshot(nil, function(subject, f)
			subject.capture({ "-i" }, "gestures")
			f.tasks[1].finish(0, "", "")
			assert_one_error(f, "shortcuts.screenshot_clipboard_failed")
		end)
	end)

	helpers.it("reports an error when the pasteboard does not hold the image", function()
		with_screenshot({ drop_image = true }, function(subject, f)
			subject.capture({ "-i" }, "gestures")
			f.write_capture(f.tasks[1])
			f.tasks[1].finish(0, "", "")
			assert_one_error(f, "shortcuts.screenshot_clipboard_failed")
		end)
	end)

	helpers.it("accepts a capture a held Control key sent to the clipboard", function()
		with_screenshot(nil, function(subject, f)
			subject.capture({ "-i" }, "gestures")
			f.capture_to_clipboard()
			f.tasks[1].finish(0, "", "")
			helpers.assert_eq(f.notifications[1].kind, "success")
			helpers.assert_eq(#f.pasteboard.writes, 0)
		end)
	end)
end)





-- ======================================
-- ======================================
-- ======= 4/ Saved Captures ============
-- ======================================
-- ======================================

helpers.describe("shared screenshot owner: verified saved captures", function()
	helpers.it("announces a save only when the file exists", function()
		with_screenshot(nil, function(subject, f)
			local capture = save_to_capture(subject, f, { "-i" })
			f.write_capture(capture)
			capture.finish(0, "", "")
			helpers.assert_eq(#f.notifications, 1)
			helpers.assert_eq(f.notifications[1].kind, "success")
			helpers.assert_contains(f.notifications[1].title, "/Users/alice/Pictures/screenshots/reg_")
		end)
	end)

	helpers.it("never claims a save when exit 0 left no file", function()
		with_screenshot(nil, function(subject, f)
			local capture = save_to_capture(subject, f, { "-i" })
			capture.finish(0, "", "")
			assert_one_error(f, "shortcuts.screenshot_failed")
		end)
	end)

	helpers.it("stays silent when an interactive save is cancelled", function()
		with_screenshot(nil, function(subject, f)
			local capture = save_to_capture(subject, f, { "-i" })
			capture.finish(1, "", "")
			helpers.assert_eq(#f.notifications, 0, "Escape is not a failure")
			helpers.assert_contains(f.infos[#f.infos], "cancelled")
		end)
	end)

	helpers.it("reports a save a held Control key sent to the clipboard as copied", function()
		with_screenshot(nil, function(subject, f)
			local capture = save_to_capture(subject, f, { "-i" })
			f.capture_to_clipboard()
			capture.finish(0, "", "")
			helpers.assert_eq(f.notifications[1].kind, "success")
			helpers.assert_eq(f.notifications[1].title, "shortcuts.screenshot_copied")
		end)
	end)

	helpers.it("rejects a save that asks for the clipboard", function()
		with_screenshot(nil, function(subject, f)
			helpers.assert_eq(subject.save({ "-ci" }, "reg", "gestures"), false)
			helpers.assert_eq(#f.tasks, 0)
			assert_one_error(f, "shortcuts.screenshot_failed")
		end)
	end)
end)





-- ======================================
-- ======================================
-- ======= 5/ Gesture Actions ===========
-- ======================================
-- ======================================

helpers.describe("gesture clipboard screenshots use the verified owner", function()
	helpers.it("no gesture clipboard action passes -c", function()
		local saved_actions = package.loaded["modules.gestures.actions"]
		local saved_screenshot = package.loaded["modules.shortcuts.actions.screenshot_save"]
		local saved_hs = _G.hs
		local captures = {}
		package.loaded["modules.shortcuts.actions.screenshot_save"] = {
			capture = function(flags)
				captures[#captures + 1] = flags
				return true
			end,
			save = function() return true end,
		}
		package.loaded["modules.gestures.actions"] = nil
		local ok, err = xpcall(function()
			local actions = helpers.load_with_stubs("modules.gestures.actions")
			for _, name in ipairs({ "screenshot_window_clipboard",
				"screenshot_region_clipboard", "screenshot_fullscreen_clipboard" }) do
				helpers.assert_eq(actions.execute_single(name), true)
			end
			helpers.assert_eq(captures, { { "-w" }, { "-i" }, {} })
		end, debug.traceback)
		package.loaded["modules.gestures.actions"] = saved_actions
		package.loaded["modules.shortcuts.actions.screenshot_save"] = saved_screenshot
		_G.hs = saved_hs
		if not ok then error(err, 0) end
	end)
end)
