--- tests/unit/ui/test_healthcheck_recent_issues_source.lua

--- ==============================================================================
--- MODULE: Recent Issues Come From Today's Errors File (macOS)
--- DESCRIPTION:
--- The window's "Recent warnings / errors" were filtered out of the 200-line
--- ring, which holds every level: at DEBUG a few minutes of routine lines
--- evicted the problems the window is opened to show. They now come from a
--- bounded tail of today's errors file, and the ring answers only when that
--- file does not exist yet (errors-file-issues).
--- ==============================================================================

local helpers = require("tests.helpers")

-- A level no variant reaches: silences the logger during the snapshot
local SILENT_LEVEL = 1000

--- Runs the callback with the real logger and a healthcheck whose native
--- probes are replaced by empty collectors.
--- @param callback function Receives (Logger, Healthcheck).
local function with_healthcheck(callback)
	helpers.with_stub_scope({
		"infra.logger", "logger", "ui.healthcheck.core", "ui.healthcheck.helpers",
	}, function()
		local Logger = helpers.load_with_stubs("infra.logger")
		Logger.set_level("DEBUG")
		Logger.reset_dedup()
		Logger.ring_buffer_clear()
		local saved_path_reader = Logger.today_errors_path
		local saved_path = Logger.ERRORS_LOG_FILE
		-- The collector reads the logger's live dated-path owner, independently
		-- of the append sink cached when the logger started.
		Logger.today_errors_path = function() return Logger.ERRORS_LOG_FILE end
		local collectors = helpers.load_with_stubs("ui.healthcheck.helpers")
		for name, value in pairs(collectors) do
			if type(value) == "function" then collectors[name] = function() return {} end end
		end
		local healthcheck = helpers.load_with_stubs("ui.healthcheck.core")
		local ok, err = xpcall(callback, debug.traceback, Logger, healthcheck)
		Logger.today_errors_path = saved_path_reader
		Logger.ERRORS_LOG_FILE = saved_path
		if not ok then error(err, 0) end
	end)
end

helpers.describe("healthcheck recent issues source (errors-file-issues)", function()
	helpers.it("reads today's errors file when it exists (errors-file-issues)", function()
		with_healthcheck(function(Logger, healthcheck)
			local path = helpers.temp_dir() .. "/ergopti_hc_errors_" .. tostring(os.time()) .. ".log"
			local fh = assert(io.open(path, "wb"))
			fh:write("2026-09-23 10:00:00:001 [WARNING] [Layout] first from the file\n"
				.. "2026-09-23 10:00:01:002 [ERROR] [Probe] second from the file\n")
			fh:close()
			-- Above every level: the headless logger re-points its dated paths on
			-- the next line it writes, so nothing may be written before the read
			Logger.set_level(SILENT_LEVEL)
			Logger.ERRORS_LOG_FILE = path
			local ok, snapshot = pcall(healthcheck.run)
			os.remove(path)
			helpers.assert_true(ok, tostring(snapshot))
			helpers.assert_eq(snapshot.sections.issues.recent_source, "errors_file")
			helpers.assert_eq(snapshot.sections.issues.recent, {
				"2026-09-23 10:00:00:001 [WARNING] [Layout] first from the file",
				"2026-09-23 10:00:01:002 [ERROR] [Probe] second from the file",
			})
		end)
	end)

	helpers.it("falls back to the ring only when the file is absent (errors-file-issues)", function()
		with_healthcheck(function(Logger, healthcheck)
			Logger.warn("probe", "ring fallback marker")
			Logger.set_level(SILENT_LEVEL)
			Logger.ERRORS_LOG_FILE = helpers.temp_dir() .. "/ergopti_hc_absent_" .. tostring(os.time()) .. ".log"
			local snapshot = healthcheck.run()
			helpers.assert_eq(snapshot.sections.issues.recent_source, "ring")
			local found = false
			for _, line in ipairs(snapshot.sections.issues.recent) do
				if line:find("ring fallback marker", 1, true) then found = true end
			end
			helpers.assert_true(found, "the ring fallback must carry the warning just logged")
		end)
	end)

	helpers.it("reports an errors file that exists but cannot be read, never the ring (errors-file-issues)", function()
		with_healthcheck(function(Logger, healthcheck)
			Logger.warn("probe", "ring entry that must not stand in for the file")
			Logger.set_level(SILENT_LEVEL)
			local path = helpers.temp_dir() .. "/ergopti_hc_unreadable_" .. tostring(os.time()) .. ".log"
			Logger.ERRORS_LOG_FILE = path
			-- The file is there but refuses to open: the ring would answer as if it
			-- did not exist, and the page would say so
			local real_open = io.open
			io.open = function(name, ...)
				if name == path then return nil, path .. ": Permission denied", 13 end
				return real_open(name, ...)
			end
			local ok, snapshot = pcall(healthcheck.run)
			io.open = real_open
			helpers.assert_true(ok, tostring(snapshot))
			helpers.assert_eq(snapshot.sections.issues.recent_source, "unavailable")
			helpers.assert_eq(snapshot.sections.issues.recent, {})
		end)
	end)
end)


--- Exercises the existing recent-source refusal contract after a real open.
local function with_tail_receipt(fault, callback)
	local sequence = tostring(os.time()) .. "_" .. fault
	local path = (os.getenv("TMPDIR") or os.getenv("TEMP") or "/tmp") .. "/ergopti_tail_receipt_" .. sequence .. ".log"
	local text = fault == "empty" and "" or "2026-09-23 10:00:01:002 [ERROR] [Probe] synthetic retained error\n"
	local file = assert(io.open(path, "wb"))
	assert(file:write(text)); assert(file:close())
	local original_open, calls, opened = io.open, { close = 0, read = 0 }, {}
	io.open = function(name, mode)
		local fh, detail, code = original_open(name, mode)
		if name ~= path or not fh then return fh, detail, code end
		local entry = { handle = fh, closed = false }; opened[#opened + 1] = entry
		return {
			seek = function(_, whence, offset)
				if fault == "seek_end_nil" and whence == "end" then return nil, "controlled end seek refusal", 5 end
				if fault == "seek_set_nil" and whence == "set" then return nil, "controlled position seek refusal", 5 end
				if fault == "seek_end_raise" and whence == "end" then error("controlled end seek exception") end
				return fh:seek(whence, offset)
			end,
			read = function(_, size)
				calls.read = calls.read + 1
				if fault == "read_nil" or fault == "read_close_nil" then return nil, "controlled read refusal", 5 end
				if fault == "read_errno2" then return nil, "controlled later ENOENT read refusal", 2 end
				if fault == "read_raise" then error("controlled read exception") end
				if fault == "read_short" then return assert(fh:read(size)):sub(1, -2) end
				return fh:read(size)
			end,
			close = function()
				calls.close = calls.close + 1
				local closed, close_detail = fh:close(); entry.closed = closed == true
				if fault == "close_nil" or fault == "read_close_nil" then return nil, "controlled close refusal", 5 end
				if fault == "close_errno2" then return nil, "controlled later ENOENT close refusal", 2 end
				if fault == "close_false" then return false, "controlled false close receipt" end
				if fault == "close_raise" then error("controlled close exception") end
				return closed, close_detail
			end,
		}
	end
	local ran, primary = pcall(callback, path, calls)
	io.open = original_open
	local closed_before_cleanup = true
	for _, entry in ipairs(opened) do
		if not entry.closed then closed_before_cleanup = false; assert(entry.handle:close()) end
	end
	assert(os.remove(path))
	if not ran then error(primary, 0) end
	helpers.assert_eq(calls.close, 1, "the source owner must close each opened native file exactly once, including after IO refusal")
	helpers.assert_true(closed_before_cleanup, "the production owner, rather than fixture cleanup, must close the real file")
end

helpers.describe("healthcheck closed recent-file IO", function()
	for _, fault in ipairs({ "seek_end_nil", "seek_set_nil", "seek_end_raise", "read_nil", "read_errno2", "read_raise", "read_short", "close_nil", "close_errno2", "close_false", "close_raise", "read_close_nil" }) do
		helpers.it("(errors-file-io-receipts) refuses " .. fault .. " without a ring fallback", function()
			with_tail_receipt(fault, function(path)
				with_healthcheck(function(Logger, healthcheck)
					Logger.set_level(SILENT_LEVEL); Logger.ERRORS_LOG_FILE = path
					local issues = healthcheck.run().sections.issues
					helpers.assert_eq(issues.recent_source, "unavailable", "a post-open IO refusal cannot claim a valid file or absence")
					helpers.assert_eq(issues.recent, {})
				end)
			end)
		end)
	end
	helpers.it("(errors-file-io-receipts) admits an empty closed file without inventing entries", function()
		with_tail_receipt("empty", function(path)
			with_healthcheck(function(Logger, healthcheck)
				Logger.set_level(SILENT_LEVEL); Logger.ERRORS_LOG_FILE = path
				local issues = healthcheck.run().sections.issues
				helpers.assert_eq(issues.recent_source, "errors_file")
				helpers.assert_eq(issues.recent, {})
			end)
		end)
	end)
end)


helpers.describe("healthcheck simultaneous source refusals", function()
	helpers.it("(errors-file-io-receipts) preserves both read and close refusal details", function()
		with_tail_receipt("read_close_nil", function(path)
			local completed, detail = pcall(require("healthcheck.snapshot").read_tail, path, 1)
			helpers.assert_eq(completed, false, "post-open refusal cannot return an open-failure errno")
			helpers.assert_true(tostring(detail):find("controlled read refusal", 1, true) ~= nil, "retain the original read refusal")
			helpers.assert_true(tostring(detail):find("controlled close refusal", 1, true) ~= nil, "retain the independent close refusal")
		end)
	end)
end)
