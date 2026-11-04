--- tests/unit/adapters/system/test_running_application.lua

--- ==============================================================================
--- MODULE: Running Application Lookup Adapter Tests
--- DESCRIPTION:
--- The adapter resolves applications from the process list only. Its native
--- double makes hs.application.get/find and hs.window.allWindows raise, since
--- those are the calls that read every window of every application when no
--- running application matches (app-lookup-no-window-scan, issue #99).
--- ==============================================================================

local helpers = require("tests.helpers")
local RunningApplication = require("adapters.running_application")

--- Builds one running application as hs.application.runningApplications lists it.
--- @param name string Localised name.
--- @param kind number Activation kind (1 regular, 0 accessory, -1 background).
--- @return table app Application double.
local function running(name, kind)
	return { name = function() return name end, kind = function() return kind end }
end

--- Runs a callback with a native double installed as the global `hs`.
--- @param apps table Applications the process list holds.
--- @param callback function Receives the double and its call counts.
local function with_native(apps, callback)
	local previous = rawget(_G, "hs")
	local counts = { listed = 0, scans = 0 }
	local function scan() counts.scans = counts.scans + 1; error("window scan", 0) end
	local native = {
		application = {
			runningApplications = function() counts.listed = counts.listed + 1; return apps end,
			applicationsForBundleID = function(id)
				if id == "com.example.present" then return { apps[1] } end
				return {}
			end,
			applicationForPID = function(pid) return pid == 4242 and apps[1] or nil end,
			get = scan,
			find = scan,
		},
		window = { allWindows = scan, find = scan },
		processInfo = { processID = 4242 },
	}
	hs = native
	local ok, err = pcall(callback, native, counts)
	hs = previous
	if not ok then error(err, 0) end
end

helpers.describe("running application lookup stays on the process list (app-lookup-no-window-scan)", function()
	helpers.it("finds an exact name without scanning windows", function()
		local mail = running("Mail", 1)
		with_native({ running("Mailspring", 1), mail }, function(_, counts)
			helpers.assert_true(rawequal(RunningApplication.by_name("Mail"), mail),
				"an exact name must resolve that application, not a fragment match")
			helpers.assert_eq(counts.listed, 1, "the process list must actually be read")
			helpers.assert_eq(counts.scans, 0, "no window may be read")
		end)
	end)

	helpers.it("answers nil for an application that is not running, without a window scan", function()
		with_native({ running("Safari", 1) }, function(_, counts)
			helpers.assert_eq(RunningApplication.by_name("Quit App"), nil)
			helpers.assert_eq(RunningApplication.by_bundle_id("com.example.gone"), nil)
			helpers.assert_eq(counts.scans, 0,
				"the miss is where hs.application.get searched every window for 13.4 s")
		end)
	end)

	helpers.it("prefers a regular application over a background one of the same name", function()
		local background, regular = running("Twin", -1), running("Twin", 1)
		with_native({ background, regular }, function()
			helpers.assert_true(rawequal(RunningApplication.by_name("Twin"), regular))
		end)
	end)

	helpers.it("resolves a bundle identifier and this process exactly", function()
		local present = running("Present", 1)
		with_native({ present }, function()
			helpers.assert_true(rawequal(RunningApplication.by_bundle_id("com.example.present"), present))
			helpers.assert_true(rawequal(RunningApplication.current(), present),
				"current() must resolve this process by its PID")
		end)
	end)

	helpers.it("rejects an empty or non-string query without touching the native layer", function()
		with_native({ running("", 1) }, function(_, counts)
			helpers.assert_eq(RunningApplication.by_name(""), nil)
			helpers.assert_eq(RunningApplication.by_name(nil), nil)
			helpers.assert_eq(RunningApplication.by_bundle_id(""), nil)
			helpers.assert_eq(counts.listed, 0)
		end)
	end)
end)
