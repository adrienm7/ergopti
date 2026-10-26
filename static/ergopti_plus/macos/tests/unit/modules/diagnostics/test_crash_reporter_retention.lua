--- tests/unit/modules/diagnostics/test_crash_reporter_retention.lua

--- ==============================================================================
--- MODULE: Crash Report Retention And Format (macOS)
--- DESCRIPTION:
--- Drives the production CrashReporter.save() boundary and proves that, after a
--- save, only the shared cap of reports remains (the oldest go first, any other
--- file stays), that a refused deletion never fails the save, and that the file
--- is the shared JSON document (parity audit D6, R31).
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs a fixture with a virtual crash folder and restores every seam.
--- @param listing table Names the folder listing returns.
--- @param callback fun(CrashReporter: table, state: table)
local function with_fixture(listing, callback)
	local module_names = {
		"modules.diagnostics.crash_reporter",
		"adapters.file_system",
		"infra.config_paths",
		"infra.i18n",
		"infra.logger",
		"infra.fs_dir",
	}
	helpers.with_fresh_modules(module_names, function()
		local original_attributes, original_mkdir, original_dir = hs.fs.attributes, hs.fs.mkdir, hs.fs.dir
		local state = { files = {}, removed = {}, warnings = {}, refuse_remove = false }
		package.loaded["adapters.file_system"] = {
			create_if_absent = function(path, content)
				if state.files[path] ~= nil then return false, "exists" end
				state.files[path] = content
				return true, "created"
			end,
			remove_exact = function(path)
				state.removed[#state.removed + 1] = path
				if state.refuse_remove then return false, "permission denied" end
				return true
			end,
		}
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		local logger_stub = helpers.make_logger_stub()
		logger_stub.crash_reports_dir = function() return "/virtual/logs/crash_reports/" end
		logger_stub.warn = function(_, fmt, ...) state.warnings[#state.warnings + 1] = string.format(fmt, ...) end
		package.loaded["infra.logger"] = logger_stub
		hs.fs.attributes = function() return { mode = "directory" } end
		hs.fs.mkdir = function() return true end
		hs.fs.dir = function()
			local index = 0
			return function() index = index + 1; return listing[index] end, {}
		end
		local outcome = table.pack(xpcall(function()
			callback(require("modules.diagnostics.crash_reporter"), state)
		end, debug.traceback))
		hs.fs.attributes, hs.fs.mkdir, hs.fs.dir = original_attributes, original_mkdir, original_dir
		if not outcome[1] then error(outcome[2], 0) end
	end)
end

--- A folder listing of `count` consecutive report names plus files that are not reports.
local function listing_of(count)
	local names = { ".", "..", "notes.json", ".last_crash_notice" }
	for index = 1, count do names[#names + 1] = string.format("2026-10-24T10-00-%02dZ.json", index) end
	return names
end

helpers.describe("crash_reporter retention (macOS)", function()
	helpers.it("deletes the oldest reports beyond the shared cap and nothing else", function()
		local cap = require("crash_report").MAX_REPORTS
		with_fixture(listing_of(cap + 2), function(CrashReporter, state)
			local path = CrashReporter.save({ timestamp = "2026-10-25T01:02:03Z", error_msg = "boom" })
			helpers.assert_eq(path, "/virtual/logs/crash_reports/2026-10-25T01-02-03Z.json")
			helpers.assert_eq(state.removed, {
				"/virtual/logs/crash_reports/2026-10-24T10-00-01Z.json",
				"/virtual/logs/crash_reports/2026-10-24T10-00-02Z.json",
			})
		end)
	end)

	helpers.it("keeps everything while the folder is within the cap", function()
		with_fixture(listing_of(3), function(CrashReporter, state)
			helpers.assert_true(CrashReporter.save({ timestamp = "2026-10-25T01:02:03Z", error_msg = "boom" }) ~= nil)
			helpers.assert_eq(state.removed, {})
		end)
	end)

	helpers.it("still returns the saved path when a deletion is refused, and says so", function()
		with_fixture(listing_of(require("crash_report").MAX_REPORTS + 1), function(CrashReporter, state)
			state.refuse_remove = true
			local path = CrashReporter.save({ timestamp = "2026-10-25T01:02:03Z", error_msg = "boom" })
			helpers.assert_true(path ~= nil, "the report is on disk whatever retention does")
			helpers.assert_eq(#state.warnings, 1)
			helpers.assert_true(state.warnings[1]:find("permission denied", 1, true) ~= nil, state.warnings[1])
		end)
	end)

	helpers.it("writes the shared JSON document with every field in the shared order", function()
		with_fixture({}, function(CrashReporter, state)
			local path = CrashReporter.save({ timestamp = "2026-10-25T01:02:03Z", error_msg = "boom", stack_trace = "a\nb" })
			local content = state.files[path]
			local decoded = require("json").decode(content)
			helpers.assert_eq(decoded.error_msg, "boom")
			helpers.assert_eq(decoded.stack_trace, "a\nb")
			helpers.assert_eq(decoded.os_version, "unknown")
			local last = 0
			for _, field in ipairs(require("crash_report").FIELDS) do
				local at = content:find('"' .. field[1] .. '":', 1, true)
				helpers.assert_true(at ~= nil and at > last, field[1] .. " is written in the shared order")
				last = at
			end
		end)
	end)
end)
