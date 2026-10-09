--- tests/unit/modules/shortcuts/test_number_row_full_capture.lua

--- ==============================================================================
--- MODULE: The key left of 1 saves every screen at once (number-row-full-capture)
--- DESCRIPTION:
--- Reads the recommendation this driver's generated manifest carries for the
--- number-row key left of 1, then drives that action's capture through the real
--- screenshot owner against ShellRunner and file doubles.
---
--- ROOT CAUSE ENCODED:
--- The key was recommended to open the system's capture tool, whose selection
--- the user has to draw before anything is saved: too slow for what only stays
--- on screen for a moment. The recommendation is now an immediate capture of
--- the whole screen, and with several displays screencapture must be given a
--- file for each one, or it saves the main display alone.
--- ==============================================================================

local helpers = require("tests.helpers")

local SUBJECT_MODULES = {
	"adapters.file_system",
	"adapters.mouse_control",
	"adapters.screen_capture",
	"adapters.shell_runner",
	"infra.i18n",
	"infra.logger",
	"infra.notifications",
	"modules.shortcuts.actions.screenshot_save",
	"modules.shortcuts.actions.screen_capture_flow",
}

local SCREENCAPTURE = "/usr/sbin/screencapture"

--- Runs one capture scenario against the real screenshot owner.
--- @param displays number Number of attached displays.
--- @param scenario function scenario(subject, fixture).
local function with_screenshot(displays, scenario)
	helpers.with_fresh_modules(SUBJECT_MODULES, function()
		local saved_hs = rawget(_G, "hs")
		local f = { tasks = {}, files = {}, notifications = {}, errors = {} }
		package.loaded["adapters.mouse_control"] = {
			getMonitorCount = function() return displays end,
		}
		package.loaded["adapters.file_system"] = {
			expand_path = function(path) return path == "~" and "/Users/alice" or path end,
			classify_no_follow = function(path)
				if f.files[path] == nil then return nil, "absent" end
				return { mode = "file", size = f.files[path] }, "ok"
			end,
			remove_exact = function(path) f.files[path] = nil return true end,
		}
		package.loaded["adapters.shell_runner"] = {
			spawn = function(executable, args, on_done)
				local record = { executable = executable, args = args }
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
				function record.finish(...)
					handle.settled = true
					on_done(...)
					for _, observer in ipairs(handle.observers) do observer() end
				end
				return handle
			end,
		}
		package.loaded["infra.i18n"] = { get = function(key)
			if key == "shortcuts.saved" then return "Saved %s" end
			return key
		end }
		package.loaded["infra.logger"] = {
			debug = function() end, info = function() end, warn = function() end,
			error = function(_, message, ...) f.errors[#f.errors + 1] = string.format(tostring(message), ...) end,
		}
		package.loaded["infra.notifications"] = {
			notify = function(title, _, kind)
				f.notifications[#f.notifications + 1] = { title = title, kind = kind }
				return true
			end,
		}
		_G.hs = {
			processInfo = { processID = 4242 },
			timer = { absoluteTime = function() return 1000 end },
			screenRecordingState = function() return true end,
			image = { imageFromPath = function(path)
				if (f.files[path] or 0) > 0 then return { path = path } end
				return nil
			end },
			pasteboard = { changeCount = function() return 1 end, readImage = function() return nil end },
		}
		local ok, err = xpcall(function()
			scenario(require("modules.shortcuts.actions.screenshot_save"), f)
		end, debug.traceback)
		_G.hs = saved_hs
		package.loaded["adapters.shell_runner"] = nil
		if not ok then error(err, 0) end
	end)
end

--- Starts the recommended capture and returns its screencapture task.
--- @return table capture
local function start_full_capture(subject, f)
	helpers.assert_eq(subject.save({}, "full", "shortcut_bindings"), true)
	f.tasks[1].finish(0, "", "")
	local capture = f.tasks[2]
	helpers.assert_eq(capture.executable, SCREENCAPTURE)
	return capture
end

helpers.describe("the key left of 1 saves every screen at once (number-row-full-capture)", function()
	helpers.it("(number-row-full-capture) macOS recommends the immediate whole-screen capture", function()
		local manifest = require("_generated.features_manifest")
		local recommended = nil
		for _, entry in ipairs(manifest.features) do
			if entry.path == "shortcuts.tap_keys.number_row_left" then recommended = entry.recommended end
		end
		helpers.assert_eq(recommended, "screenshot_fullscreen_save",
			"a selection to draw is too slow for what is only on screen for a moment")
	end)

	helpers.it("(number-row-full-capture) one display: one file, no selection, saved", function()
		with_screenshot(1, function(subject, f)
			local capture = start_full_capture(subject, f)
			helpers.assert_eq(#capture.args, 1, "no area flag and a single target")
			helpers.assert_true(capture.args[1]:match("^/Users/alice/Pictures/screenshots/full_") ~= nil)
			f.files[capture.args[1]] = 2048
			capture.finish(0, "", "")
			helpers.assert_eq(f.notifications, { { title = "Saved " .. capture.args[1], kind = "success" } })
		end)
	end)

	helpers.it("(number-row-full-capture) two displays: a file for each, all verified", function()
		with_screenshot(2, function(subject, f)
			local capture = start_full_capture(subject, f)
			helpers.assert_eq(#capture.args, 2,
				"screencapture saves the main display alone unless every display has a file")
			for _, arg in ipairs(capture.args) do
				helpers.assert_true(arg:sub(1, 1) == "/", "no interactive flag: " .. arg)
			end
			helpers.assert_true(capture.args[1] ~= capture.args[2])
			f.files[capture.args[1]] = 2048
			f.files[capture.args[2]] = 2048
			capture.finish(0, "", "")
			helpers.assert_eq(f.notifications[1].kind, "success")
		end)
	end)

	helpers.it("(number-row-full-capture) a display left without its image is a failure", function()
		with_screenshot(2, function(subject, f)
			local capture = start_full_capture(subject, f)
			f.files[capture.args[1]] = 2048
			capture.finish(0, "", "")
			helpers.assert_eq(#f.notifications, 1)
			helpers.assert_eq(f.notifications[1].kind, "error")
		end)
	end)
end)
