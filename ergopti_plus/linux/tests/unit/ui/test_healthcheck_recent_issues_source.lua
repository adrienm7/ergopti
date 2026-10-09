--- tests/unit/ui/test_healthcheck_recent_issues_source.lua

--- ==============================================================================
--- MODULE: Recent Issues Come From Today's Errors File (Linux)
--- DESCRIPTION:
--- The window's "Recent warnings / errors" were filtered out of the 200-line
--- ring, which holds every level: at DEBUG a few minutes of routine lines
--- evicted the problems the window is opened to show. They now come from a
--- bounded tail of today's errors file, and the ring answers only when that
--- file does not exist yet (errors-file-issues).
--- ==============================================================================

local helpers = require("tests.helpers")

local TMP = (os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"):gsub("\\", "/")

--- Runs the callback with the sink's errors path pointed at `path`.
--- @param path string
--- @param callback function Receives the freshly loaded bridge.
local function with_errors_path(path, callback)
	local LoggerSink = require("infra.logger_sink")
	local original = LoggerSink.errors_log_path
	LoggerSink.errors_log_path = function() return path end
	local ok, err = pcall(callback, helpers.load_module("ui.healthcheck.bridge"))
	LoggerSink.errors_log_path = original
	if not ok then error(err, 0) end
end

helpers.describe("healthcheck (linux): recent issues source", function()
	helpers.it("reads today's errors file when it exists (errors-file-issues)", function()
		local path = TMP .. "/ergopti_hc_errors_" .. tostring(os.time()) .. ".log"
		local fh = assert(io.open(path, "wb"))
		fh:write("2026-09-23 10:00:00:001 [WARNING] [Layout] first from the file\n"
			.. "2026-09-23 10:00:01:002 [ERROR] [Probe] second from the file\n")
		fh:close()
		local ok, err = pcall(with_errors_path, path, function(Bridge)
			local snapshot = Bridge.build_snapshot({}, false).sections.issues
			helpers.assert_eq(snapshot.recent_source, "errors_file")
			helpers.assert_eq(snapshot.recent, {
				"2026-09-23 10:00:00:001 [WARNING] [Layout] first from the file",
				"2026-09-23 10:00:01:002 [ERROR] [Probe] second from the file",
			})
		end)
		os.remove(path)
		if not ok then error(err, 0) end
	end)

	helpers.it("falls back to the ring only when the file is absent (errors-file-issues)", function()
		local Logger = require("logger")
		Logger.warn("probe", "ring fallback marker")
		with_errors_path(TMP .. "/ergopti_hc_absent_" .. tostring(os.time()) .. ".log", function(Bridge)
			local snapshot = Bridge.build_snapshot({}, false).sections.issues
			helpers.assert_eq(snapshot.recent_source, "ring")
			local found = false
			for _, line in ipairs(snapshot.recent) do
				if line:find("ring fallback marker", 1, true) then found = true end
			end
			helpers.assert_true(found, "the ring fallback must carry the warning just logged")
		end)
	end)

	helpers.it("reports an errors file that exists but cannot be read, never the ring (errors-file-issues)", function()
		local Logger = require("logger")
		Logger.warn("probe", "ring entry that must not stand in for the file")
		local path = TMP .. "/ergopti_hc_unreadable_" .. tostring(os.time()) .. ".log"
		-- The file is there but refuses to open: the ring would answer as if it
		-- did not exist, and the page would say so
		local real_open = io.open
		io.open = function(name, ...)
			if name == path then return nil, path .. ": Permission denied", 13 end
			return real_open(name, ...)
		end
		local ok, err = pcall(with_errors_path, path, function(Bridge)
			local snapshot = Bridge.build_snapshot({}, false).sections.issues
			helpers.assert_eq(snapshot.recent_source, "unavailable")
			helpers.assert_eq(snapshot.recent, {})
		end)
		io.open = real_open
		if not ok then error(err, 0) end
	end)
end)
