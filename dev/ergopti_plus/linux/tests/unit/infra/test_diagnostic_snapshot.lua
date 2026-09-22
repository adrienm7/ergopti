--- tests/unit/infra/test_diagnostic_snapshot.lua

--- ==============================================================================
--- TEST: Diagnostic snapshot (Linux)
--- DESCRIPTION:
--- The boot snapshot is a cross-driver contract: one INFO line, the same field
--- names in the same order on Windows, macOS and Linux, so a user log from any
--- driver answers the same first questions (which build, which OS, which
--- layout, how long the boot took). These tests replay the shared vectors
--- through the shared Lua formatter, drive the real Linux collector against
--- fixture files, and check the daemon source still emits it after "ready".
--- ==============================================================================

local helpers = require("tests.helpers")

local describe    = helpers.describe
local it          = helpers.it
local assert_eq   = helpers.assert_eq
local assert_true = helpers.assert_true

local json     = require("json")
local Paths    = require("infra.paths")
local Snapshot = require("diagnostics.snapshot")




-- =====================================
-- =====================================
-- ======= 1/ Shared contract ==========
-- =====================================
-- =====================================

--- Reads the shared snapshot contract.
--- @return table
local function read_contract()
	local path = Paths.shared("modules/logger/diagnostic_snapshot.json")
	assert_true(path ~= nil, "the shared tree must be reachable")
	local fh = assert(io.open(path, "r"))
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw))
end

describe("Diagnostic snapshot: shared contract", function()
	local contract = read_contract()

	it("the Lua formatter declares exactly the shared field list, in order", function()
		assert_eq(#contract.fields, #Snapshot.FIELDS, "field count")
		for index, name in ipairs(contract.fields) do
			assert_eq(name, Snapshot.FIELDS[index], "field " .. index)
		end
		assert_eq(contract.module, Snapshot.MODULE, "log tag")
		assert_eq(contract.unknown, Snapshot.UNKNOWN, "unknown token")
	end)

	it("every shared vector renders byte for byte", function()
		assert_true(#contract.vectors >= 3, "the vectors must load — zero would make this vacuous")
		for _, vector in ipairs(contract.vectors) do
			assert_eq(vector.expected, Snapshot.format(vector.values), "vector " .. vector.id)
		end
	end)

	it("renders a path under the home directory relative to ~", function()
		assert_eq("~/.config/ergopti", Snapshot.redact_home("/home/alice/.config/ergopti", "/home/alice"))
		assert_eq("/home/alicex/cfg", Snapshot.redact_home("/home/alicex/cfg", "/home/alice"),
			"a sibling account sharing a prefix is not the home directory")
	end)
end)




-- =====================================
-- =====================================
-- ======= 2/ Commit lookup ============
-- =====================================
-- =====================================

--- Builds an in-memory filesystem from a path → content table.
--- @param files table
--- @return table
local function fixture_fs(files)
	return {
		read = function(path) return files[path] end,
		exists = function(path) return files[path] ~= nil end,
	}
end

describe("Diagnostic snapshot: commit lookup", function()
	local sha = "3b924cd46aaaabbbbccccddddeeeeffff0000111"

	it("reads a detached HEAD", function()
		local fs = fixture_fs({ ["/repo/.git/HEAD"] = sha .. "\n" })
		assert_eq("3b924cd46", Snapshot.git_commit(fs, "/repo/static/ergopti_plus/linux"))
	end)

	it("follows a branch ref in a linked worktree to the common directory", function()
		local fs = fixture_fs({
			["/wt/.git"] = "gitdir: /repo/.git/worktrees/wt\n",
			["/repo/.git/worktrees/wt/HEAD"] = "ref: refs/heads/feature\n",
			["/repo/.git/worktrees/wt/commondir"] = "../..\n",
			["/repo/.git/worktrees/wt/../../refs/heads/feature"] = sha .. "\n",
		})
		assert_eq("3b924cd46", Snapshot.git_commit(fs, "/wt/static"))
	end)

	it("falls back to packed-refs", function()
		local fs = fixture_fs({
			["/repo/.git/HEAD"] = "ref: refs/heads/dev\n",
			["/repo/.git/packed-refs"] = "# pack-refs with: peeled\n" .. sha .. " refs/heads/dev\n",
		})
		assert_eq("3b924cd46", Snapshot.git_commit(fs, "/repo"))
	end)

	it("answers nil outside a repository", function()
		assert_eq(nil, Snapshot.git_commit(fixture_fs({}), "/opt/ergopti"))
	end)
end)




-- =======================================
-- =======================================
-- ======= 3/ Linux collector ============
-- =======================================
-- =======================================

describe("Diagnostic snapshot: Linux collector", function()
	local Collector = require("infra.diagnostic_snapshot")
	local files = {
		["/etc/os-release"] = 'NAME="Ubuntu"\nVERSION_ID="24.04"\n',
		["/proc/sys/kernel/osrelease"] = "6.8.0-45-generic\n",
		["/proc/sys/kernel/arch"] = "x86_64\n",
		["/proc/self/status"] = "Name:\tluajit\nUid:\t1000\t1000\t1000\t1000\n",
		["/proc/self/stat"] = "4242 (luajit) S 1\n",
	}
	local env = fixture_fs(files)

	it("fills every probe it owns from the system files", function()
		local values = Collector.collect({
			boot_ms = 812.4, locale = "fr", keyboard_layout = "azerty",
			log_level = "DEBUG", features_enabled = 3, features_total = 5,
			script_dir = "/nowhere",
		}, env)
		assert_eq("linux", values.driver)
		assert_eq("Ubuntu", values.os)
		assert_eq("24.04 kernel 6.8.0-45-generic", values.os_version)
		assert_eq("false", values.elevated, "uid 1000 is not elevated")
		assert_eq("3/5", values.features_enabled)
		assert_eq("812", values.boot_ms)
		assert_eq("4242", Collector.pid(env))
	end)

	it("emits one INFO line carrying every shared field", function()
		local contract = read_contract()
		local lines = {}
		local Logger = require("logger")
		local previous_level = Logger.get_level()
		Logger.set_level(10)
		Logger.ring_buffer_clear()
		Logger.set_sink(function(line) lines[#lines + 1] = line end)
		local ok, err = pcall(Collector.emit, { boot_ms = 5, script_dir = "/nowhere" }, env)
		Logger.set_sink(nil)
		Logger.set_level(previous_level)
		assert_true(ok, tostring(err))
		local snapshot_lines = {}
		for _, line in ipairs(lines) do
			if line:find("[" .. contract.module .. "]", 1, true) then
				snapshot_lines[#snapshot_lines + 1] = line
			end
		end
		assert_eq(1, #snapshot_lines, "exactly one snapshot line")
		assert_true(snapshot_lines[1]:find("[INFO]", 1, true) ~= nil, "at INFO")
		for _, name in ipairs(contract.fields) do
			assert_true(snapshot_lines[1]:find(" " .. name .. "=", 1, true)
				or snapshot_lines[1]:find("(" .. name .. "=", 1, true),
				"field '" .. name .. "' missing from: " .. snapshot_lines[1])
		end
	end)
end)




-- =========================================
-- =========================================
-- ======= 4/ The daemon emits it ==========
-- =========================================
-- =========================================

describe("Diagnostic snapshot: the daemon boot emits it after ready", function()
	local fh = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
	local src = fh:read("*a")
	fh:close()

	it("logs the snapshot once the daemon reports ready", function()
		local ready = src:find('Logger.success(LOG, "Daemon ready', 1, true)
		local complete = src:find("BootProfiler.complete()", 1, true)
		local emit = src:find("\temit_diagnostic_snapshot(boot_ms, opts,", 1, true)
		assert_true(ready ~= nil and complete ~= nil and emit ~= nil,
			"the ready line, the boot total and the snapshot call must all exist")
		assert_true(ready < complete and complete < emit,
			"the snapshot follows ready and carries the frozen boot total")
	end)

	it("closes every boot stage it opens", function()
		local opened = 0
		for name in src:gmatch('BootProfiler%.stage%("([^"]+)"%)') do
			opened = opened + 1
			assert_true(src:find('BootProfiler.stage_done("' .. name .. '"', 1, true) ~= nil,
				"stage '" .. name .. "' has no stage_done: a boot that dies there would be unnamed")
		end
		assert_true(opened >= 5, "the boot must be split into stages, found " .. opened)
	end)
end)
