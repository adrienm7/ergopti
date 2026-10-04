--- tests/unit/adapters/test_boot_journal.lua

--- ==============================================================================
--- MODULE: Boot journal and launcher key report (boot-stage-trail)
--- DESCRIPTION:
--- The synchronous boot journal is the readable trail when Logger lines are
--- still queued for the native worker at os.exit(). It must reach real files
--- before returning, route early stages to launcher.log, and the launcher key
--- report must list names only, never the logger token.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["adapters.boot_journal"] = nil
local BootJournal = require("adapters.boot_journal")
local LauncherEnvironment = require("infra.launcher_environment")

local SCRATCH = helpers.temp_dir() .. "/ergopti_boot_journal_test"

--- Reads one whole file, or "" when it does not exist.
local function read_all(path)
	local handle = io.open(path, "rb")
	if not handle then return "" end
	local text = handle:read("a")
	handle:close()
	return text
end

helpers.describe("boot journal (boot-stage-trail)", function()
	helpers.it("writes early stages to the fallback log and launcher.log as closed files", function()
		local stamp = tostring(os.time()) .. "_" .. tostring(math.random(1, 1e9))
		local fallback = SCRATCH .. "_boot_" .. stamp .. ".log"
		local launcher = SCRATCH .. "_launcher_" .. stamp .. ".log"
		local ok, err = pcall(function()
			BootJournal.configure_for_tests({
				fallback_path = fallback,
				clock = function() return "T" end,
				getenv = function(name)
					if name == BootJournal.LAUNCHER_LOG_ENV then return launcher end
					return nil
				end,
			})
			helpers.assert_eq(BootJournal.append("START", "Boot stage started: Core."), true)
			BootJournal.set_user_log_ready(true)
			BootJournal.append("SUCCESS", "Boot stage completed: Core.")
			helpers.assert_eq(read_all(fallback),
				"T [START] [init] Boot stage started: Core.\nT [SUCCESS] [init] Boot stage completed: Core.\n")
			helpers.assert_eq(read_all(launcher),
				"[T] embedded Hammerspoon boot START: Boot stage started: Core.\n")
		end)
		BootJournal.configure_for_tests(nil)
		os.remove(fallback)
		os.remove(launcher)
		if not ok then error(err, 0) end
	end)

	helpers.it("reports a refused destination instead of claiming success", function()
		BootJournal.configure_for_tests({
			fallback_path = "/never",
			getenv = function() return nil end,
			open = function() return nil, "Permission denied" end,
		})
		local written = BootJournal.append("INFO", "x")
		BootJournal.configure_for_tests(nil)
		helpers.assert_eq(written, false)
	end)

	helpers.it("lists launcher keys by name and never exposes a value", function()
		local present, missing = LauncherEnvironment.presence(function(name)
			if name == "ERGOPTI_LOG_TOKEN" then return "secret-token-value" end
			if name == "ERGOPTI_LAUNCHER_PID" then return "42" end
			return nil
		end)
		helpers.assert_eq(table.concat(present, ","), "ERGOPTI_LAUNCHER_PID,ERGOPTI_LOG_TOKEN")
		helpers.assert_true(#missing >= 10, "every other exported key is reported missing")
		for _, name in ipairs(missing) do
			helpers.assert_true(name:match("^ERGOPTI_[A-Z_]+$") ~= nil, "names only: " .. name)
		end
		helpers.assert_true(not table.concat(present, ","):find("secret", 1, true))
	end)
end)


--- Uses the real synchronous journal files, never an AppleEvent or getter setter.
local function native_state_observation(runtime)
	local fallback = os.tmpname()
	local launcher = os.tmpname()
	os.remove(fallback)
	os.remove(launcher)
	BootJournal.configure_for_tests({
		fallback_path = fallback,
		clock = function() return "T" end,
		getenv = function(name)
			if name == BootJournal.LAUNCHER_LOG_ENV then return launcher end
		end,
	})
	local ok, written = pcall(BootJournal.record_native_scripting_state, runtime)
	BootJournal.configure_for_tests(nil)
	local fallback_text, launcher_text = read_all(fallback), read_all(launcher)
	os.remove(fallback)
	os.remove(launcher)
	helpers.assert_true(ok, "The readonly diagnostic never raises a native getter refusal")
	helpers.assert_eq(written, true, "The real synchronous journal acknowledged publication")
	return fallback_text, launcher_text
end

helpers.describe("managed native scripting admission (native-scripting-state)", function()
	for _, value in ipairs({ true, false }) do
		helpers.it("records the actual boolean " .. tostring(value) .. " getter without enabling scripting", function()
			local observed = { calls = 0, bridge_calls = 0 }
			local getter = function(...)
				observed.calls = observed.calls + 1
				observed.arguments = select("#", ...)
				return value
			end
			local bridge = function() observed.bridge_calls = observed.bridge_calls + 1 end
			local runtime = { processInfo = { processID = 42 }, allowAppleScript = getter,
				__appleScriptRunString = bridge }
			local fallback, launcher = native_state_observation(runtime)
			local expected = "Native scripting server: pid=42; getter=boolean; allowed=" .. tostring(value)
				.. "; bridge=callable; handler_registration=unobserved; handler_entry=unobserved."
			helpers.assert_eq(fallback, "T [INFO] [init] " .. expected .. "\n")
			helpers.assert_eq(launcher, "[T] embedded Hammerspoon boot INFO: " .. expected .. "\n")
			helpers.assert_eq(observed.calls, 1)
			helpers.assert_eq(observed.arguments, 0, "No setter argument can alter the native preference")
			helpers.assert_eq(observed.bridge_calls, 0, "A callable bridge is never executed for readiness")
			helpers.assert_eq(runtime.allowAppleScript, getter)
			helpers.assert_eq(runtime.__appleScriptRunString, bridge, "The native handler binding is not replaced")
		end)
	end

	for _, bad in ipairs({ {}, { value = 1 }, { value = "PRIVATE_GETTER_SECRET" }, { value = {} } }) do
		helpers.it("refuses a " .. type(bad.value) .. " getter result without fabricating enabled state", function()
			local fallback = native_state_observation({ processInfo = { processID = 42 },
				allowAppleScript = function() return bad.value end })
			helpers.assert_true(fallback:find("getter=malformed; allowed=unknown; bridge=missing;", 1, true) ~= nil)
			helpers.assert_true(not fallback:find("PRIVATE_GETTER_SECRET", 1, true))
		end)
	end

	helpers.it("records a thrown getter with a closed token and no exception payload", function()
		local fallback = native_state_observation({ processInfo = { processID = 42 },
			allowAppleScript = function() error("PRIVATE_GETTER_SECRET /private/path") end })
		helpers.assert_true(fallback:find("getter=error; allowed=unknown;", 1, true) ~= nil)
		helpers.assert_true(not fallback:find("PRIVATE_GETTER_SECRET", 1, true))
		helpers.assert_true(not fallback:find("/private/path", 1, true))
	end)

	helpers.it("records a missing getter and bridge without claiming native registration", function()
		local fallback = native_state_observation({ processInfo = { processID = 42 } })
		helpers.assert_true(fallback:find("getter=missing; allowed=unknown; bridge=missing;", 1, true) ~= nil)
		helpers.assert_true(fallback:find("handler_registration=unobserved; handler_entry=unobserved.", 1, true) ~= nil)
	end)

	for _, bad in ipairs({ 0, 1.5, math.huge, "42" }) do
		helpers.it("does not grant owned PID identity from " .. tostring(bad), function()
			local fallback = native_state_observation({ processInfo = { processID = bad },
				allowAppleScript = function() return true end, __appleScriptRunString = "PRIVATE_BRIDGE_SECRET" })
			helpers.assert_true(fallback:find("pid=unknown; getter=boolean; allowed=true; bridge=missing;", 1, true) ~= nil)
			helpers.assert_true(not fallback:find("PRIVATE_BRIDGE_SECRET", 1, true))
		end)
	end

	helpers.it("keeps a refused destination unacknowledged instead of granting a witness", function()
		BootJournal.configure_for_tests({ fallback_path = "/never", getenv = function() return nil end,
			open = function() return nil, "owned destination refused" end })
		local ok, written = pcall(BootJournal.record_native_scripting_state,
			{ processInfo = { processID = 42 }, allowAppleScript = function() return true end })
		BootJournal.configure_for_tests(nil)
		helpers.assert_true(ok)
		helpers.assert_eq(written, false)
	end)
end)
