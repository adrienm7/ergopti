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
