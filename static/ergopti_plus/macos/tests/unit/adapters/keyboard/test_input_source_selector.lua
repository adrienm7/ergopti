--- tests/unit/adapters/keyboard/test_input_source_selector.lua

--- ==============================================================================
--- MODULE: Native Input-source Selection Command Regression
--- DESCRIPTION:
--- Exercises the real bundle-bound helper resolver over controlled native file
--- identities. Selection identifiers remain argv data, and unavailable helpers
--- or invalid requests cannot authorize an alternate executable or AppleScript.
--- ==============================================================================

local helpers = require("tests.helpers")
local DRIVER_ROOT = "/Applications/ErgoptiPlus.app/Contents/Resources/static/ergopti_plus/macos"
local EXECUTABLE = "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus"


--- Runs the command builder with genuine helper resolution and native doubles.
--- @param options table Native file observation controls.
--- @param body function fn(selector, resolution_count).
local function with_fixture(options, body)
	helpers.with_stub_scope({ "adapters.input_source_selector", "platform.remap.lease_helper" }, function()
		local selector = helpers.load_with_stubs("adapters.input_source_selector", {
			fs = {
				symlinkAttributes = function(path)
					if path ~= EXECUTABLE then return nil end
					return { mode = "file", dev = 1, ino = options.inode or 2 }
				end,
				attributes = function(path)
					if path ~= EXECUTABLE then return nil end
					return { mode = "file", permissions = "rwxr-xr-x", dev = 1, ino = options.inode or 2 }
				end,
				pathToAbsolute = function(path) return path end,
			},
		})
		local helper = require("platform.remap.lease_helper")
		local resolve = helper.resolve
		local resolutions = 0
		helper.resolve = function()
			resolutions = resolutions + 1
			if options.resolution_raises then error("native helper observation failed") end
			return resolve(DRIVER_ROOT)
		end
		local original_getenv = os.getenv
		os.getenv = function(name)
			if name == "ERGOPTI_LAUNCHER_EXECUTABLE" then return EXECUTABLE end
			if name == "ERGOPTI_LAUNCHER_DEVICE" then return "1" end
			if name == "ERGOPTI_LAUNCHER_INODE" then return "2" end
			return original_getenv(name)
		end
		local ok, detail = xpcall(function()
			body(selector, function() return resolutions end)
		end, debug.traceback)
		os.getenv = original_getenv
		if not ok then error(detail, 0) end
	end)
end


helpers.describe("native input-source selection: exact command", function()
	helpers.it("resolves the real bundle identity and preserves the identifier as one literal argv", function()
		with_fixture({}, function(selector, resolutions)
			local identifier = 'com.ergopti."quoted".%s\\literal'
			local executable, args, environment, reason = selector.command(identifier)
			helpers.assert_eq(executable, EXECUTABLE)
			helpers.assert_eq(resolutions(), 1)
			helpers.assert_eq(#args, 2)
			helpers.assert_eq(args[1], "--select-input-source")
			helpers.assert_eq(args[2], identifier)
			helpers.assert_eq(environment.ERGOPTI_LAUNCHER_EXECUTABLE, EXECUTABLE)
			helpers.assert_eq(environment.ERGOPTI_LAUNCHER_DEVICE, "1")
			helpers.assert_eq(environment.ERGOPTI_LAUNCHER_INODE, "2")
			helpers.assert_nil(reason)
		end)
	end)

	helpers.it("refuses a changed native executable identity without a command", function()
		with_fixture({ inode = 3 }, function(selector)
			local executable, args, environment, reason = selector.command("com.apple.keylayout.US")
			helpers.assert_nil(executable)
			helpers.assert_nil(args)
			helpers.assert_nil(environment)
			helpers.assert_not_nil(reason)
		end)
	end)

	helpers.it("refuses malformed identifiers before native helper resolution", function()
		with_fixture({}, function(selector, resolutions)
			for _, case in ipairs({ {}, { value = "" }, { value = 7 }, { value = {} },
				{ value = "bad\0source" }, { value = string.rep("x", 1025) } }) do
				local executable, args, environment, reason = selector.command(case.value)
				helpers.assert_nil(executable)
				helpers.assert_nil(args)
				helpers.assert_nil(environment)
				helpers.assert_eq(reason, "invalid_source")
			end
			helpers.assert_eq(resolutions(), 0)
		end)
	end)

	helpers.it("reports helper resolution exceptions without choosing another executable", function()
		with_fixture({ resolution_raises = true }, function(selector)
			local executable, args, environment, reason = selector.command("com.apple.keylayout.US")
			helpers.assert_nil(executable)
			helpers.assert_nil(args)
			helpers.assert_nil(environment)
			helpers.assert_eq(reason, "helper_resolution_failed")
		end)
	end)
end)
