--- tests/unit/modules/gestures/test_screen_reading_capture.lua

--- ==============================================================================
--- MODULE: Screen Reading Capture (llm-vision)
--- DESCRIPTION:
--- Exercises screenshot_save.capture_image, the capture behind the
--- llm_screen_region and llm_screen_full actions, against faked processes and
--- files: screencapture writes a private temporary PNG (never the clipboard),
--- sips downscales it only when its longest edge exceeds the bound, the image
--- reaches the caller as base64, and the file is removed however the capture
--- ends, with no screenshot notification (the caller shows its own notice).
---
--- ROOT CAUSE ENCODED:
--- The screenshot owner only knew saved files and clipboard copies: a vision
--- request had no private image to read, and no owner that removes it.
--- ==============================================================================

local helpers = require("tests.helpers")

local TEMP = "/tmp/lua_screen_reading"

local SUBJECT_MODULES = {
	"adapters.file_system",
	"adapters.screen_capture",
	"adapters.shell_runner",
	"modules.shortcuts.actions.screen_capture_flow",
	"infra.i18n",
	"infra.logger",
	"infra.notifications",
	"modules.shortcuts.actions.screenshot_save",
}

--- Encodes a number as a big-endian 32-bit integer.
--- @param value number
--- @return string bytes
local function be32(value)
	return string.char(math.floor(value / 16777216) % 256, math.floor(value / 65536) % 256,
		math.floor(value / 256) % 256, value % 256)
end

--- Builds the bytes of a PNG of the given size (header only, enough to size it).
--- @param width number
--- @param height number
--- @param tag string Distinguishes two images of the same size.
--- @return string bytes
local function png(width, height, tag)
	return "\137PNG\r\n\26\n" .. be32(13) .. "IHDR" .. be32(width) .. be32(height) .. "\8\6\0\0\0" .. tag
end

--- Loads the subject against faked process, file and notification boundaries.
--- @param scenario function Receives (subject, fixture).
local function with_subject(scenario)
	local saved = {}
	for _, name in ipairs(SUBJECT_MODULES) do saved[name] = package.loaded[name] end
	local saved_hs = _G.hs
	local fixture = { tasks = {}, notifications = {}, removed = {}, infos = {}, file = nil }

	package.loaded["adapters.file_system"] = {
		create_secure_temp_file = function()
			fixture.file = ""
			return TEMP
		end,
		classify_no_follow = function(path)
			if path ~= TEMP or fixture.file == nil then return nil, "absent" end
			return { mode = "file", size = #fixture.file }, "ok"
		end,
		read_with_status = function(path)
			if path ~= TEMP or fixture.file == nil then return nil, "absent" end
			return fixture.file, "ok"
		end,
		remove_exact = function(path)
			fixture.removed[#fixture.removed + 1] = path
			fixture.file = nil
			return true
		end,
	}
	package.loaded["adapters.screen_capture"] = {
		permission_state = function() return true end,
		request_permission = function() return true end,
		open_permission_settings = function() return true end,
		clipboard_change_count = function() return 1 end,
		clipboard_has_image = function() return false end,
		copy_image_file_to_clipboard = function() error("a screen reading never touches the clipboard") end,
		encode_base64 = function(data) return "B64(" .. data .. ")" end,
	}
	package.loaded["modules.shortcuts.actions.screen_capture_flow"] = nil
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.logger"] = {
		debug = function() end,
		info = function(_, message, ...) fixture.infos[#fixture.infos + 1] = string.format(message, ...) end,
		warn = function() end,
		error = function() end,
	}
	package.loaded["infra.notifications"] = {
		notify = function(message, _, kind)
			fixture.notifications[#fixture.notifications + 1] = { message = message, kind = kind }
			return true
		end,
	}
	package.loaded["adapters.shell_runner"] = {
		spawn = function(executable, args, on_done)
			local record = { executable = executable, args = args }
			fixture.tasks[#fixture.tasks + 1] = record
			local handle = { settled = false, observers = {} }
			function handle.start() return true end
			function handle.isSettled() return handle.settled end
			function handle.onSettled(observer)
				if handle.settled then observer() else handle.observers[#handle.observers + 1] = observer end
				return true
			end
			function handle.terminate()
				handle.settled = true
				return true, "settled"
			end
			function record.finish(...)
				handle.settled = true
				on_done(...)
				for _, observer in ipairs(handle.observers) do observer() end
				handle.observers = {}
			end
			return handle
		end,
	}
	package.loaded["modules.shortcuts.actions.screenshot_save"] = nil
	_G.hs = { processInfo = { processID = 7001 }, timer = { absoluteTime = function() return 1 end } }

	local ok, err = xpcall(function()
		scenario(require("modules.shortcuts.actions.screenshot_save"), fixture)
	end, debug.traceback)
	_G.hs = saved_hs
	for _, name in ipairs(SUBJECT_MODULES) do package.loaded[name] = saved[name] end
	package.loaded["adapters.shell_runner"] = saved["adapters.shell_runner"]
	if not ok then error(err, 0) end
end

--- Starts a capture and returns what it delivered.
--- @param subject table screenshot_save.
--- @param flags table screencapture flags.
--- @return table delivered { outcome, data } once on_image ran.
local function start(subject, flags)
	local delivered = {}
	helpers.assert_eq(subject.capture_image(flags, "gestures", 1568, function(outcome, data)
		delivered[#delivered + 1] = { outcome = outcome, data = data }
	end), true, "the capture starts")
	return delivered
end

helpers.describe("screen reading capture (llm-vision)", function()
	helpers.it("captures to a private PNG, delivers it as base64 and removes the file", function()
		with_subject(function(subject, fixture)
			local delivered = start(subject, { "-i" })
			helpers.assert_eq(#fixture.tasks, 1)
			local capture = fixture.tasks[1]
			helpers.assert_eq(capture.executable, "/usr/sbin/screencapture")
			helpers.assert_eq(table.concat(capture.args, " "), "-i -t png " .. TEMP,
				"the drawn region, as PNG, into the private file: never -c")
			local image = png(1200, 800, "small")
			fixture.file = image
			capture.finish(0, "", "")
			helpers.assert_eq(#fixture.tasks, 1, "an image within the bound is not resampled")
			helpers.assert_eq(#delivered, 1)
			helpers.assert_eq(delivered[1].outcome, "image")
			helpers.assert_eq(delivered[1].data, "B64(" .. image .. ")")
			helpers.assert_eq(fixture.removed[1], TEMP, "the file is removed once delivered")
			helpers.assert_eq(#fixture.notifications, 0, "no screenshot notification")
		end)
	end)

	helpers.it("downscales an image larger than the bound with sips before delivering it", function()
		with_subject(function(subject, fixture)
			local delivered = start(subject, { "-R", "0,0,3024,1964" })
			fixture.file = png(3024, 1964, "large")
			fixture.tasks[1].finish(0, "", "")
			helpers.assert_eq(#delivered, 0, "the original is not sent")
			helpers.assert_eq(#fixture.removed, 0, "the file lives while sips works on it")
			local sips = fixture.tasks[2]
			helpers.assert_eq(sips.executable, "/usr/bin/sips")
			helpers.assert_eq(table.concat(sips.args, " "), "-Z 1568 " .. TEMP)
			local resized = png(1568, 1018, "resized")
			fixture.file = resized
			sips.finish(0, "", "")
			helpers.assert_eq(delivered[1].outcome, "image")
			helpers.assert_eq(delivered[1].data, "B64(" .. resized .. ")", "the resampled image is sent")
			helpers.assert_eq(fixture.removed[1], TEMP)
		end)
	end)

	helpers.it("sends the original when sips fails, and says so once per session", function()
		with_subject(function(subject, fixture)
			for round = 1, 2 do
				local delivered = start(subject, { "-i" })
				local original = png(4000, 3000, "original" .. round)
				fixture.file = original
				fixture.tasks[#fixture.tasks].finish(0, "", "")
				fixture.tasks[#fixture.tasks].finish(1, "", "sips: error")
				helpers.assert_eq(delivered[1].data, "B64(" .. original .. ")", "the original is sent")
			end
			local mentions = 0
			for _, line in ipairs(fixture.infos) do
				if line:find("could not be downscaled", 1, true) then mentions = mentions + 1 end
			end
			helpers.assert_eq(mentions, 1, "one INFO line per session")
		end)
	end)

	helpers.it("reports a cancelled selection and a failed capture without a notification", function()
		with_subject(function(subject, fixture)
			local cancelled = start(subject, { "-i" })
			fixture.file = nil
			fixture.tasks[1].finish(1, "", "")
			helpers.assert_eq(cancelled[1].outcome, "cancelled")

			local failed = start(subject, { "-R", "0,0,10,10" })
			fixture.tasks[2].finish(1, "", "could not create image from display")
			helpers.assert_eq(failed[1].outcome, "failed")
			helpers.assert_eq(#fixture.notifications, 0, "the caller shows its own notice")
			helpers.assert_eq(#fixture.removed, 2, "every temporary file is removed")
		end)
	end)

	helpers.it("refuses flags that target the clipboard", function()
		with_subject(function(subject, fixture)
			helpers.assert_eq(subject.capture_image({ "-ic" }, "gestures", 1568, function()
				error("nothing is delivered")
			end), false)
			helpers.assert_eq(#fixture.tasks, 0)
		end)
	end)

	helpers.it("reads the PNG size from its header", function()
		with_subject(function(subject)
			local width, height = subject._png_size(png(70000, 3, "x"))
			helpers.assert_eq(width, 70000)
			helpers.assert_eq(height, 3)
			helpers.assert_nil((subject._png_size("GIF89a not a png at all.....")))
		end)
	end)
end)
