--- tests/unit/adapters/test_field_probe_ports_log_probe.lua

--- ==============================================================================
--- MODULE: Field Run Log Probe Leaves Nothing Behind
--- DESCRIPTION:
--- The field run's storage step proves the logs folder takes a write with one
--- probe file. The file system adapter's atomic write keeps a lock file beside
--- its target, so writing the probe through it left that lock file in the
--- user's logs folder after every run. The probe must report the folder
--- writable and leave the folder exactly as it found it, and report an
--- unwritable folder as such.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "adapters.field_probe_ports" }

--- Lists a folder's entries, sorted.
--- @param dir string Folder.
--- @return string names Joined by commas.
local function listing(dir)
	local names = {}
	for name in require("lfs").dir(dir) do
		if name ~= "." and name ~= ".." then names[#names + 1] = name end
	end
	table.sort(names)
	return table.concat(names, ",")
end

--- Runs log_facts over a logs folder.
--- @param dir string Logs folder.
--- @return table facts
local function log_facts(dir)
	local facts
	helpers.with_stub_scope(MODULES, function()
		local logger = helpers.make_logger_stub()
		logger.logs_dir = function() return dir .. "/" end
		logger.today_log_path = function() return dir .. "/ErgoptiPlus_2026-10-30.log" end
		package.loaded["infra.logger"] = logger
		package.loaded["adapters.field_probe_ports"] = nil
		-- The folder listing the stub serves is the real folder's
		local real = {}
		local ok = pcall(function()
			for name in require("lfs").dir(dir) do
				if name ~= "." and name ~= ".." then real[#real + 1] = name end
			end
		end)
		hs.fs.__set_entries(dir, ok and real or {})
		facts = require("adapters.field_probe_ports").new().log_facts()
		hs.fs.__reset_entries()
	end)
	return facts
end

helpers.describe("field run log probe", function()
	helpers.it("reports a writable logs folder and leaves no file behind", function()
		local dir = os.tmpname()
		os.remove(dir)
		assert(require("lfs").mkdir(dir))
		local log = assert(io.open(dir .. "/ErgoptiPlus_2026-10-30.log", "wb"))
		log:write("line\n")
		log:close()
		local before = listing(dir)
		local facts = log_facts(dir)
		helpers.assert_true(facts.writable, "the folder takes a write")
		helpers.assert_true(facts.today_present)
		helpers.assert_eq(facts.files, 1)
		helpers.assert_eq(listing(dir), before, "the probe must leave the logs folder as it found it")
		os.remove(dir .. "/ErgoptiPlus_2026-10-30.log")
		require("lfs").rmdir(dir)
	end)

	helpers.it("reports a folder that does not exist as not writable", function()
		local dir = os.tmpname()
		os.remove(dir)
		local facts = log_facts(dir .. "/missing")
		helpers.assert_true(not facts.writable)
		helpers.assert_true(not facts.today_present)
	end)
end)
