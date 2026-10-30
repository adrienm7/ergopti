--- tests/unit/adapters/test_field_probe_ports_crash_reports.lua

--- ==============================================================================
--- MODULE: Field Run Crash Report Port
--- DESCRIPTION:
--- The real crash report port over temporary folders:
--- 1. a driver crash_reports folder that does not exist holds no report and
---    logs no error (the 2026-10-30 20:51 run logged "Cannot iterate
---    directory" from infra/fs_dir.lua for it);
--- 2. macOS reports are split into this app's processes, each with its kind
---    read as closed tokens from the report, and other apps' ones, counted;
--- 3. a report older than a day is not counted.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "infra.fs_dir", "adapters.field_probe_ports" }

--- Writes one file.
local function write(path, text)
	local file = assert(io.open(path, "wb"))
	file:write(text)
	file:close()
end

helpers.describe("field run crash report port", function()
	helpers.it("names this app's reports with closed tokens and logs no error for an absent folder", function()
		local lfs = require("lfs")
		local home = os.tmpname()
		os.remove(home)
		assert(lfs.mkdir(home))
		assert(lfs.mkdir(home .. "/Library"))
		assert(lfs.mkdir(home .. "/Library/Logs"))
		local reports = home .. "/Library/Logs/DiagnosticReports"
		assert(lfs.mkdir(reports))
		write(reports .. "/ErgoptiPlus-2026-10-30-205212.ips", '{"app_name":"ErgoptiPlus","bug_type":"309"}\n'
			.. '{"procPath":"/Users/someone/x","exception":{"type":"EXC_CRASH","signal":"SIGKILL"},'
			.. '"termination":{"namespace":"CODESIGNING"}}')
		write(reports .. "/ollama-2026-10-30.hang", "hang\n")
		write(reports .. "/Safari-2026-10-30.ips", "{}\n")
		write(reports .. "/Hammerspoon-2026-10-01.ips", "{}\n")
		local old = os.time() - 3 * 86400
		lfs.touch(reports .. "/Hammerspoon-2026-10-01.ips", old, old)
		local entries = {}
		for name in lfs.dir(reports) do
			if name ~= "." and name ~= ".." then entries[#entries + 1] = name end
		end
		local counts, errors
		helpers.with_stub_scope(MODULES, function()
			local logger = helpers.make_logger_stub()
			errors = 0
			logger.error = function() errors = errors + 1 end
			logger.crash_reports_dir = function() return home .. "/missing/crash_reports/" end
			package.loaded["infra.logger"] = logger
			package.loaded["infra.fs_dir"] = nil
			package.loaded["adapters.field_probe_ports"] = nil
			hs.fs.__set_entries(reports, entries)
			local saved = os.getenv
			os.getenv = function(name) if name == "HOME" then return home end return saved(name) end
			local ok, result = pcall(function() return require("adapters.field_probe_ports").new().crash_counts() end)
			os.getenv = saved
			hs.fs.__reset_entries()
			assert(ok, result)
			counts = result
		end)
		helpers.assert_eq(errors, 0, "an absent folder is no report, not an error")
		helpers.assert_eq(counts.driver, 0)
		helpers.assert_eq(counts.other, 1)
		helpers.assert_eq(#counts.owned, 2, "the old Hammerspoon report is not counted")
		local kinds = {}
		for _, entry in ipairs(counts.owned) do kinds[entry.process] = entry.kind end
		helpers.assert_eq(kinds.ergoptiplus, "crash:exc_crash:sigkill:codesigning")
		helpers.assert_eq(kinds.ollama, "hang")
		for _, name in ipairs(entries) do os.remove(reports .. "/" .. name) end
		lfs.rmdir(reports); lfs.rmdir(home .. "/Library/Logs"); lfs.rmdir(home .. "/Library"); lfs.rmdir(home)
	end)
end)
