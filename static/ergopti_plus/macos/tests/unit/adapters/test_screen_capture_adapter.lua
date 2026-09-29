--- tests/unit/adapters/test_screen_capture_adapter.lua

--- ==============================================================================
--- MODULE: Screen capture adapter (screen-recording-before-capture)
--- DESCRIPTION:
--- The packaged runtime is its own app identity, so a Screen Recording grant
--- held by a stock Hammerspoon does not apply to it. Ctrl+H then showed the
--- selection and left nothing on the clipboard. The adapter must report the
--- native permission exactly, open the exact settings pane, and count a
--- clipboard image only when it can be read back after the write.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs body against a fresh adapter and a fully owned native table.
--- @param native table Replacement global hs table.
--- @param body function Receives the adapter.
local function with_native(native, body)
	local saved_hs = rawget(_G, "hs")
	local saved_module = package.loaded["adapters.screen_capture"]
	package.loaded["adapters.screen_capture"] = nil
	_G.hs = native
	local ok, err = xpcall(function()
		body(require("adapters.screen_capture"))
	end, debug.traceback)
	_G.hs = saved_hs
	package.loaded["adapters.screen_capture"] = saved_module
	if not ok then error(err, 0) end
end

--- Builds a pasteboard double that models the change count and image slot.
--- @param options table|nil write_result, drop_image, keep_count, image_for_path.
--- @return table native
--- @return table state
local function pasteboard_native(options)
	local opts = options or {}
	local state = { count = 7, image = nil, writes = {} }
	local native = {
		image = {
			imageFromPath = function(path)
				if opts.image_for_path == false then return nil end
				return { path = path }
			end,
		},
		pasteboard = {
			changeCount = function() return state.count end,
			readImage = function() return state.image end,
			writeObjects = function(image)
				state.writes[#state.writes + 1] = image
				if opts.write_result ~= nil then return opts.write_result end
				if not opts.keep_count then state.count = state.count + 1 end
				if not opts.drop_image then state.image = image end
				return true
			end,
		},
	}
	return native, state
end

helpers.describe("screen capture adapter: Screen Recording permission", function()
	helpers.it("reports a missing grant without prompting", function()
		local prompts = {}
		with_native({ screenRecordingState = function(prompt)
			prompts[#prompts + 1] = prompt
			return false
		end }, function(adapter)
			helpers.assert_eq(adapter.permission_state(), false)
			helpers.assert_eq(prompts, { false },
				"a state query must never show the macOS prompt")
		end)
	end)

	helpers.it("reports a granted runtime", function()
		with_native({ screenRecordingState = function() return true end }, function(adapter)
			helpers.assert_eq(adapter.permission_state(), true)
		end)
	end)

	helpers.it("keeps a failed or unavailable query distinct from a refusal", function()
		with_native({ screenRecordingState = function() error("tcc down") end }, function(adapter)
			local granted, detail = adapter.permission_state()
			helpers.assert_nil(granted)
			helpers.assert_contains(detail, "tcc down")
		end)
		with_native({}, function(adapter)
			local granted, detail = adapter.permission_state()
			helpers.assert_nil(granted)
			helpers.assert_contains(detail, "screenRecordingState")
		end)
	end)

	helpers.it("asks macOS for its prompt only through request_permission", function()
		local prompts = {}
		with_native({ screenRecordingState = function(prompt)
			prompts[#prompts + 1] = prompt
			return false
		end }, function(adapter)
			helpers.assert_eq(adapter.request_permission(), true)
			helpers.assert_eq(prompts, { true })
		end)
	end)

	helpers.it("opens the exact Screen Recording privacy pane", function()
		local opened = {}
		with_native({ urlevent = { openURL = function(url)
			opened[#opened + 1] = url
			return true
		end } }, function(adapter)
			helpers.assert_eq(adapter.open_permission_settings(), true)
			helpers.assert_eq(opened, {
				"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
			})
		end)
	end)

	helpers.it("reports a refused settings URL instead of claiming it opened", function()
		with_native({ urlevent = { openURL = function() return false end } }, function(adapter)
			local opened, detail = adapter.open_permission_settings()
			helpers.assert_eq(opened, false)
			helpers.assert_contains(detail, "false")
		end)
	end)

	helpers.it("resets only this app's Screen Recording entry through tccutil (screen-recording-stale-reset)",
		function()
			local saved = package.loaded["adapters.shell_runner"]
			local spawned = nil
			package.loaded["adapters.shell_runner"] = {
				spawn = function(executable, args, on_done)
					spawned = { executable = executable, args = args, on_done = on_done }
					return { start = function() return true end }
				end,
			}
			local ok, err = pcall(function()
				with_native({ processInfo = { bundleID = "com.ergoptiplus.app.hammerspoon" } }, function(adapter)
					helpers.assert_eq(adapter.bundle_id(), "com.ergoptiplus.app.hammerspoon")
					local result = nil
					helpers.assert_eq(adapter.reset_permission("com.ergoptiplus.app.hammerspoon",
						function(done, detail) result = { done, detail } end), true)
					helpers.assert_eq(spawned.executable, "/usr/bin/tccutil")
					helpers.assert_eq(table.concat(spawned.args, " "),
						"reset ScreenCapture com.ergoptiplus.app.hammerspoon")
					spawned.on_done(0, "", "")
					helpers.assert_eq(result, { true })
					spawned.on_done(1, "", "no such bundle")
					helpers.assert_eq(result[1], false)
					helpers.assert_contains(result[2], "no such bundle")
					local _, refusal = pcall(adapter.reset_permission, "", function() end)
					helpers.assert_contains(tostring(refusal), "bundle_id must be a non-empty string")
					local _, unsupported = pcall(require("adapters.tcc_grant").reset, "All", "com.ergoptiplus.app.hammerspoon",
						function() end)
					helpers.assert_contains(tostring(unsupported), "unsupported service")
				end)
				with_native({}, function(adapter)
					local bundle_id, detail = adapter.bundle_id()
					helpers.assert_nil(bundle_id)
					helpers.assert_contains(detail, "bundleID")
				end)
			end)
			package.loaded["adapters.shell_runner"] = saved
			if not ok then error(err, 0) end
		end)
end)

helpers.describe("screen capture adapter: verified clipboard image", function()
	helpers.it("copies the capture file and reads the image back", function()
		local native, state = pasteboard_native()
		with_native(native, function(adapter)
			helpers.assert_eq(adapter.copy_image_file_to_clipboard("/tmp/cap.png"), true)
			helpers.assert_eq(#state.writes, 1)
			helpers.assert_eq(state.writes[1].path, "/tmp/cap.png")
			helpers.assert_eq(adapter.clipboard_has_image(), true)
		end)
	end)

	local refusals = {
		{ "an unreadable capture file", { image_for_path = false }, "no readable image" },
		{ "writeObjects returning false", { write_result = false }, "writeObjects returned false" },
		{ "a write that does not advance the change count", { keep_count = true }, "did not advance" },
		{ "a write after which no image can be read", { drop_image = true }, "no image after the write" },
	}
	for _, case in ipairs(refusals) do
		helpers.it("refuses " .. case[1], function()
			local native = pasteboard_native(case[2])
			with_native(native, function(adapter)
				local copied, detail = adapter.copy_image_file_to_clipboard("/tmp/cap.png")
				helpers.assert_eq(copied, false,
					"success may only be reported once the image is on the pasteboard")
				helpers.assert_contains(detail, case[3])
			end)
		end)
	end

	helpers.it("reports an unreadable change count as a failure, not zero", function()
		with_native({ pasteboard = { changeCount = function() error("pboard down") end } },
			function(adapter)
				local count, detail = adapter.clipboard_change_count()
				helpers.assert_nil(count)
				helpers.assert_contains(detail, "pboard down")
			end)
	end)
end)
