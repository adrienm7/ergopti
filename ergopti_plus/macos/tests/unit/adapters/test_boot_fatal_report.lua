--- tests/unit/adapters/test_boot_fatal_report.lua

--- ==============================================================================
--- MODULE: Fatal Exit Reporter — no silent abort (silent-boot-abort)
--- DESCRIPTION:
--- Release v0.0.0-dev.128 died after the native logger handshake with no dialog
--- and no log: the abort's Logger line was only queued for the native worker,
--- the hs.alert was killed by os.exit(), and Hammerspoon reported exit status 0,
--- which the launcher treats as a deliberate Quit once the logger is configured.
---
--- FEATURES & RATIONALE:
--- 1. The fatal line reaches the fallback boot log and launcher.log as real,
---    closed files before report() returns, i.e. before any os.exit().
--- 2. The launcher report names the stage, the localized message and the cause
---    on single lines, so a traceback cannot corrupt the record.
--- 3. Without a launcher channel, report() says so, so the caller can fall back
---    to a blocking local dialog instead of dying silently.
--- 4. A component that fails after boot completed is a runtime stop: the report
---    says kind=runtime and lists the day's logs, so the launcher no longer
---    tells a user whose app ran for days that it "could not start".
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["adapters.boot_fatal"] = nil
local BootFatal = require("adapters.boot_fatal")

local SCRATCH = helpers.temp_dir() .. "/ergopti_boot_fatal_test"

--- Reads one whole file, or nil when it does not exist.
--- @param path string Absolute path.
--- @return string|nil
local function read_all(path)
	local handle = io.open(path, "rb")
	if not handle then return nil end
	local text = handle:read("a")
	handle:close()
	return text
end

--- Runs `body` with fresh destination paths and removes them afterwards.
--- @param body function Receives the three destination paths.
local function with_destinations(body)
	local stamp = tostring(os.time()) .. "_" .. tostring(math.random(1, 1e9))
	local paths = {
		fallback = SCRATCH .. "_boot_" .. stamp .. ".log",
		launcher = SCRATCH .. "_launcher_" .. stamp .. ".log",
		report = SCRATCH .. "_report_" .. stamp .. ".txt",
	}
	local ok, err = pcall(body, paths)
	for _, path in pairs(paths) do os.remove(path) end
	if not ok then error(err, 0) end
end

--- Builds an environment reader exposing only the given launcher channels.
local function env_with(paths)
	return function(name)
		if name == BootFatal.LAUNCHER_LOG_ENV then return paths.launcher end
		if name == BootFatal.REPORT_FILE_ENV then return paths.report end
		return nil
	end
end

helpers.describe("boot fatal reporter (silent-boot-abort)", function()
	helpers.it("persists the stage and cause to every log before returning", function()
		with_destinations(function(paths)
			local notified = BootFatal.report("accessibility", "event tap refused",
				"Allow ErgoptiPlus in Accessibility.", {
					getenv = env_with(paths),
					fallback_path = paths.fallback,
					clock = function() return "2026-09-22 10:00:00" end,
				})
			helpers.assert_eq(notified, true)
			helpers.assert_contains(read_all(paths.fallback) or "",
				"[ERROR] [init] FATAL at boot stage 'accessibility': event tap refused")
			helpers.assert_contains(read_all(paths.launcher) or "",
				"embedded Hammerspoon FATAL at boot stage 'accessibility': event tap refused")
			helpers.assert_eq(read_all(paths.report),
				"kind=boot\nstage=accessibility\nmessage=Allow ErgoptiPlus in Accessibility.\n"
					.. "detail=event tap refused\n")
		end)
	end)

	helpers.it("(fatal-runtime-kind) reports a runtime stop with its component and logs", function()
		with_destinations(function(paths)
			local notified = BootFatal.report_runtime("native_logger",
				"native logger did not ACK retained sequence 9 within the 30000 ms stall budget",
				"An internal error stopped Ergopti+.",
				{ "/L/ErgoptiPlus_2026-09-22.log", "/L/ErgoptiPlus_errors_2026-09-22.log" }, {
					getenv = env_with(paths),
					fallback_path = paths.fallback,
					clock = function() return "2026-09-22 10:00:00" end,
				})
			helpers.assert_eq(notified, true)
			local fallback = read_all(paths.fallback) or ""
			helpers.assert_contains(fallback, "FATAL in runtime component 'native_logger'")
			helpers.assert_true(fallback:find("boot stage", 1, true) == nil,
				"a runtime stop must not be written as a boot failure")
			helpers.assert_contains(read_all(paths.launcher) or "",
				"embedded Hammerspoon FATAL in runtime component 'native_logger'")
			helpers.assert_eq(read_all(paths.report),
				"kind=runtime\nstage=native_logger\nmessage=An internal error stopped Ergopti+.\n"
					.. "detail=native logger did not ACK retained sequence 9 within the 30000 ms stall budget\n"
					.. "log=/L/ErgoptiPlus_2026-09-22.log\nlog=/L/ErgoptiPlus_errors_2026-09-22.log\n")
		end)
	end)

	helpers.it("(fatal-runtime-kind) a component failing after boot completed is a runtime stop", function()
		local kind, stage, key = BootFatal.presentation("native_logger", true, "Menu built")
		helpers.assert_eq(kind, BootFatal.KIND_RUNTIME)
		helpers.assert_eq(stage, "native_logger", "a runtime stop names the component, not a boot stage")
		helpers.assert_eq(key, "dialog.fatal_error.runtime_stopped")

		kind, stage, key = BootFatal.presentation("native_logger", false, "Menu built")
		helpers.assert_eq(kind, BootFatal.KIND_BOOT)
		helpers.assert_eq(stage, "native_logger")
		helpers.assert_eq(key, "dialog.fatal_error.cannot_start")

		kind, stage = BootFatal.presentation("boot", false, "Menu built")
		helpers.assert_eq(kind, BootFatal.KIND_BOOT)
		helpers.assert_eq(stage, "Menu built", "the generic boot owner names the running stage")

		kind, stage, key = BootFatal.presentation("boot", true, "after Boot complete")
		helpers.assert_eq(kind, BootFatal.KIND_RUNTIME)
		helpers.assert_eq(stage, "boot")
		helpers.assert_eq(key, "dialog.fatal_error.runtime_stopped")
	end)

	helpers.it("(fatal-runtime-kind) every default message key exists in the canonical catalogue", function()
		local catalogue = read_all(helpers.shared("data/locales/en.json"))
		helpers.assert_true(type(catalogue) == "string" and #catalogue > 1000,
			"en.json must be readable")
		local keys = 0
		for _, complete in ipairs({ true, false }) do
			local _, _, key = BootFatal.presentation("native_logger", complete, "stage")
			keys = keys + 1
			helpers.assert_contains(catalogue, '"' .. key .. '":')
		end
		helpers.assert_eq(keys, 2)
	end)

	helpers.it("appends to existing logs and keeps multi-line causes on one line", function()
		with_destinations(function(paths)
			local seed = io.open(paths.fallback, "wb")
			seed:write("earlier boot line\n")
			seed:close()
			BootFatal.report("boot", "first\nstack traceback:\n\tsecond", "msg", {
				getenv = env_with(paths), fallback_path = paths.fallback,
			})
			local fallback = read_all(paths.fallback) or ""
			helpers.assert_contains(fallback, "earlier boot line\n")
			helpers.assert_contains(fallback, "'boot': first | stack traceback: | \tsecond\n")
			local report = read_all(paths.report) or ""
			helpers.assert_contains(report, "detail=first | stack traceback: | \tsecond\n")
			local _, line_count = report:gsub("\n", "")
			helpers.assert_eq(line_count, 4)
		end)
	end)

	helpers.it("tells the caller when no launcher channel exists", function()
		with_destinations(function(paths)
			local notified, outcomes = BootFatal.report("native_logger_environment",
				"native logger authority absent", "msg", {
					getenv = function() return nil end, fallback_path = paths.fallback,
				})
			helpers.assert_eq(notified, false)
			helpers.assert_eq(outcomes.launcher_report.written, false)
			helpers.assert_eq(outcomes.fallback_boot_log.written, true)
			helpers.assert_contains(read_all(paths.fallback) or "", "native_logger_environment")
		end)
	end)

	helpers.it("defaults to the logger's fallback boot log", function()
		local Logger = require("infra.logger")
		-- The default logs folder, beside launcher.log, never the shared /tmp root.
		helpers.assert_eq(Logger.FALLBACK_BOOT_LOG_FILE, Logger.FALLBACK_LOG_DIR .. "ErgoptiPlus_boot.log")
		helpers.assert_true(Logger.FALLBACK_LOG_DIR:find("Library/Logs/ergopti_plus/", 1, true) ~= nil
			or Logger.FALLBACK_LOG_DIR == "/tmp/ergopti_plus/",
			"the fallback boot log must live in the default logs folder: " .. Logger.FALLBACK_LOG_DIR)
		local opened = {}
		BootFatal.report("config_paths", "refused", "msg", {
			getenv = function() return nil end,
			open = function(path)
				opened[#opened + 1] = path
				return nil, "test refuses every write"
			end,
		})
		helpers.assert_eq(opened[1], Logger.FALLBACK_BOOT_LOG_FILE)
	end)
end)
