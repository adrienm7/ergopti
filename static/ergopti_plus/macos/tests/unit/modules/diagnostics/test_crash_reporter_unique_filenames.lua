--- tests/unit/modules/diagnostics/test_crash_reporter_unique_filenames.lua

--- ==============================================================================
--- MODULE: Crash Report Filename Uniqueness Regression
--- DESCRIPTION:
--- Replays two reports carrying the same second-resolution timestamp through the
--- production CrashReporter.save() boundary. The persistence double implements
--- the exact create-if-absent contract, so the test proves that a collision is
--- retried under a new name instead of silently truncating the first report.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs a crash-report fixture and restores every global/module seam on failure.
--- @param callback fun(CrashReporter: table, files: table, attempts: table)
local function with_fixture(callback)
	local module_names = {
		"modules.diagnostics.crash_reporter",
		"adapters.file_system",
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

		package.loaded["adapters.file_system"] = {
			create_if_absent = function(path, content)
				attempts[#attempts + 1] = path
				if files[path] ~= nil then return false, "exists" end
				files[path] = content
				return true, "created"
			end,
		}
		package.loaded["infra.config_paths"] = {
			get_config_dir = function() return "/virtual/config/" end,
		}
		package.loaded["infra.i18n"] = {
			get = function(key) return key end,
		}
		package.loaded["infra.logger"] = helpers.make_logger_stub()

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

helpers.describe("crash_reporter preserves same-second reports", function()
	helpers.it("reserves a numeric suffix instead of truncating the first JSON", function()
		with_fixture(function(CrashReporter, files, attempts)
			local timestamp = "2026-08-27T01:23:45Z"
			local first_path = CrashReporter.save({
				timestamp = timestamp,
				error_msg = "first fatal",
			})
			local second_path = CrashReporter.save({
				timestamp = timestamp,
				error_msg = "second fatal",
			})

			helpers.assert_eq(first_path,
				"/virtual/config/hammerspoon/crash_reports/2026-08-27T01-23-45Z.json",
				"the first report keeps the timestamp-only canonical name")
			helpers.assert_eq(second_path,
				"/virtual/config/hammerspoon/crash_reports/2026-08-27T01-23-45Z-2.json",
				"the colliding report must reserve the first deterministic suffix")
			helpers.assert_true(first_path ~= second_path,
				"same-second reports must never share a truncating destination")
			helpers.assert_true(files[first_path]:find("first fatal", 1, true) ~= nil,
				"the earlier crash report must remain byte-addressable after the collision")
			helpers.assert_true(files[second_path]:find("second fatal", 1, true) ~= nil,
				"the later crash report must be stored under the unique suffix")
			helpers.assert_eq(#attempts, 3,
				"the second save must observe the base collision before reserving suffix 2")
			helpers.assert_eq(attempts[1], first_path,
				"the first save must reserve the canonical path atomically")
			helpers.assert_eq(attempts[2], first_path,
				"the second save must retry the exact colliding path first")
			helpers.assert_eq(attempts[3], second_path,
				"the second save must atomically reserve its unique successor")
		end)
	end)
end)
