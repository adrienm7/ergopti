--- tests/unit/modules/diagnostics/test_crash_reporter_redaction.lua

--- ==============================================================================
--- MODULE: Crash Report Redaction Regression
--- DESCRIPTION:
--- Proves the production CrashReporter.save() boundary hands the whole encoded
--- document to the logger's privacy redactor before anything is opened (the
--- policy Linux applies), and that a redactor which cannot answer refuses the
--- report instead of writing the raw bytes.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs a crash-report fixture and restores every global/module seam on failure.
--- @param redact function Logger.redact_message double.
--- @param callback fun(CrashReporter: table, files: table, attempts: table)
local function with_fixture(redact, callback)
	local module_names = {
		"modules.diagnostics.crash_reporter",
		"core.fs.adapters.file_system",
		"infra.config_paths",
		"infra.i18n",
		"infra.logger",
	}
	helpers.with_fresh_modules(module_names, function()
		local original_open = io.open
		local original_attributes = hs.fs.attributes
		local original_mkdir = hs.fs.mkdir
		local files = {}
		local attempts = {}

		package.loaded["core.fs.adapters.file_system"] = {
			create_if_absent = function(path, content)
				attempts[#attempts + 1] = path
				if files[path] ~= nil then return false, "exists" end
				files[path] = content
				return true, "created"
			end,
		}
		package.loaded["infra.i18n"] = {
			get = function(key) return key end,
		}
		local logger_stub = helpers.make_logger_stub()
		-- The logger is the one resolver of the crash-reports folder.
		logger_stub.crash_reports_dir = function() return "/virtual/logs/crash_reports/" end
		logger_stub.redact_message = redact
		package.loaded["infra.logger"] = logger_stub

		-- The legacy implementation writes directly with mode "w". Model that
		-- faithfully so the pre-fix code overwrites the same in-memory path and
		-- fails the behavioral assertions below rather than failing during setup.
		io.open = function(path, mode)
			helpers.assert_eq(mode, "w", "the unsafe legacy writer must use truncating mode")
			local handle = {}
			function handle:write(content)
				files[path] = content
				return true
			end
			function handle:close() return true end
			return handle
		end
		hs.fs.attributes = function() return { mode = "directory" } end
		hs.fs.mkdir = function() return true end

		local outcome = table.pack(xpcall(function()
			local CrashReporter = require("modules.diagnostics.crash_reporter")
			callback(CrashReporter, files, attempts)
		end, debug.traceback))

		io.open = original_open
		hs.fs.attributes = original_attributes
		hs.fs.mkdir = original_mkdir
		if not outcome[1] then error(outcome[2], 0) end
	end)
end

helpers.describe("crash_reporter redacts before persistence", function()
	helpers.it("(crash-redaction) writes only the redacted document", function()
		local function redact(text) return (text:gsub("sk%-canary%-123", "[redacted]")) end
		with_fixture(redact, function(CrashReporter, files)
			local path = CrashReporter.save({
				timestamp = "2026-08-27T01:23:45Z",
				error_msg = "failed with sk-canary-123",
				stack_trace = "stack sk-canary-123",
			})
			helpers.assert_true(path ~= nil, "a live redactor must let the report be saved")
			local written = files["/virtual/logs/crash_reports/" .. path]
				or files[path] or select(2, next(files))
			helpers.assert_true(written:find("sk-canary-123", 1, true) == nil,
				"the raw canary must never reach the written report")
			helpers.assert_true(written:find("[redacted]", 1, true) ~= nil)
		end)
	end)

	helpers.it("(crash-redaction) refuses to write when the redactor cannot answer", function()
		local function redact() error("logger: privacy not initialized") end
		with_fixture(redact, function(CrashReporter, files)
			helpers.assert_eq(CrashReporter.save({ timestamp = "2026-08-27T01:23:45Z", error_msg = "boom" }), nil)
			helpers.assert_true(next(files) == nil, "no raw fallback report may be written")
		end)
	end)
end)
