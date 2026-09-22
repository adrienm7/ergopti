--- tests/unit/infra/test_driver_version.lua

--- ==============================================================================
--- TEST: Driver version comes from the release build stamp (Linux)
--- DESCRIPTION:
--- infra/version.lua held a fixed "3.0.0" that no build rewrote, while releases
--- are published as 0.0.0-dev.N and N.N.N: the tray, the healthcheck, the boot
--- snapshot and the updater all reported a version that never existed. The
--- release build now stamps `version=` into the shared tree's build stamp and
--- infra/version.lua resolves it; these tests drive the shared parser, the
--- resolver, and the crash dump, which never wrote a version at all because its
--- only caller passes no context.
--- ==============================================================================

local helpers = require("tests.helpers")

local describe    = helpers.describe
local it          = helpers.it
local assert_eq   = helpers.assert_eq
local assert_true = helpers.assert_true

local Snapshot = require("diagnostics.snapshot")

local SHA = "f58d15798aaaabbbbccccddddeeeeffff0000111"
local SHARED = "/usr/lib/ergopti/_shared"
local STAMP = SHARED .. "/" .. Snapshot.BUILD_STAMP_FILE




-- =====================================
-- =====================================
-- ======= 1/ Fixtures =================
-- =====================================
-- =====================================

--- Builds an in-memory reader from a path → content table.
--- @param files table
--- @return table
local function fixture_fs(files)
	return { read = function(path) return files[path] end }
end

--- Runs body with every log line captured at DEBUG.
--- @param body function
--- @return table lines
local function capture_logs(body)
	local Logger = require("logger")
	local lines = {}
	local previous_level = Logger.get_level()
	Logger.set_level(10)
	Logger.set_sink(function(line) lines[#lines + 1] = tostring(line) end)
	local ok, err = pcall(body)
	Logger.set_sink(nil)
	Logger.set_level(previous_level)
	if not ok then error(err, 0) end
	return lines
end




-- =====================================
-- =====================================
-- ======= 2/ Shared parser ============
-- =====================================
-- =====================================

describe("Driver version: the shared stamp parser", function()
	it("reads the release version a release build stamps", function()
		assert_eq("0.0.0-dev.42", (Snapshot.parse_build_version("commit=" .. SHA .. "\nversion=0.0.0-dev.42\n")))
		assert_eq("1.4.2", (Snapshot.parse_build_version("version=1.4.2\r\ncommit=" .. SHA .. "\r\n")))
	end)

	it("never returns semver build metadata", function()
		assert_eq("0.0.0-dev.42", (Snapshot.parse_build_version("version=0.0.0-dev.42+817\n")))
		assert_eq("2.0.0", (Snapshot.parse_build_version("version=2.0.0+build.7\n")))
	end)

	it("rejects a placeholder or a malformed version with the reason", function()
		local version, reason = Snapshot.parse_build_version("version=__VERSION__\n")
		assert_eq(nil, version)
		assert_true(reason ~= nil and reason:find("__VERSION__", 1, true) ~= nil, tostring(reason))
		version, reason = Snapshot.parse_build_version("version=1.2\n")
		assert_eq(nil, version)
		assert_true(reason ~= nil, "a two-part version is not a release version")
	end)

	it("reports a stamp without a version entry as missing, not as invalid", function()
		local version, reason = Snapshot.parse_build_version("commit=" .. SHA .. "\n")
		assert_eq(nil, version)
		assert_eq(nil, reason)
	end)
end)




-- =====================================
-- =====================================
-- ======= 3/ Linux resolver ===========
-- =====================================
-- =====================================

describe("Driver version: infra/version.lua resolves the stamp", function()
	local Version = require("infra.version")

	it("a release package reports the stamped version", function()
		local version, source = Version.resolve({
			shared_root = SHARED,
			fs = fixture_fs({ [STAMP] = "commit=" .. SHA .. "\nversion=0.0.0-dev.7\n" }),
		})
		assert_eq("0.0.0-dev.7", version)
		assert_eq(Version.SOURCE_BUILD, source)
	end)

	it("a source run with no stamp reports local, the token the updater understands", function()
		local version, source = Version.resolve({ shared_root = SHARED, fs = fixture_fs({}) })
		assert_eq(Version.LOCAL, version)
		assert_eq(Version.SOURCE_LOCAL, source)
		assert_eq("local", require("updater.version").normalize_tag(version),
			"the updater's source-run branch compares against this exact token")
	end)

	it("a package stamped without a version reports unknown and logs why", function()
		local version, source
		local lines = capture_logs(function()
			version, source = Version.resolve({
				shared_root = SHARED, fs = fixture_fs({ [STAMP] = "commit=" .. SHA .. "\n" }),
			})
		end)
		assert_eq(Version.UNKNOWN, version)
		assert_eq(Version.SOURCE_UNKNOWN, source)
		local logged = false
		for _, line in ipairs(lines) do
			if line:find("[WARNING]", 1, true) and line:find("Driver version unknown", 1, true) then
				logged = true
			end
		end
		assert_true(logged, "expected a WARNING; got:\n" .. table.concat(lines, "\n"))
	end)

	it("the checkout resolves to local, never to a fixed release literal", function()
		assert_eq(Version.LOCAL, Version.VERSION,
			"the source tree ships no stamp, so a fixed version literal would be the only way to differ")
		assert_eq(Version.SOURCE_LOCAL, Version.SOURCE)
	end)

	it("the source file carries no version literal a build would have to rewrite", function()
		local fh = assert(io.open(helpers.driver_root() .. "/infra/version.lua", "r"))
		local src = fh:read("*a")
		fh:close()
		assert_eq(nil, src:match('M%.VERSION%s*=%s*"%d'), "M.VERSION must be resolved, not typed")
	end)
end)




-- =====================================
-- =====================================
-- ======= 4/ Crash dump ===============
-- =====================================
-- =====================================

describe("Driver version: the crash dump names the version and the app dir", function()
	it("writes both lines although the daemon passes no context", function()
		local Paths = require("infra.paths")
		local Version = require("infra.version")
		local Reporter = helpers.load_module("modules.diagnostics.crash_reporter")
		local real_open, real_exec, real_popen = io.open, os.execute, io.popen
		local parts = {}
		io.open = function()
			return {
				write = function(_, s) parts[#parts + 1] = s; return true end,
				close = function() return true end,
			}
		end
		os.execute = function() return true end
		io.popen = function() return nil end
		local ok, err = pcall(Reporter.dump, "ergopti_hotstrings", "boom")
		io.open, os.execute, io.popen = real_open, real_exec, real_popen
		if not ok then error(err, 0) end
		local body = table.concat(parts)
		assert_true(body:find("Version:   " .. Version.VERSION .. " (" .. Version.SOURCE .. ")", 1, true) ~= nil, body)
		assert_true(body:find("App dir:   " .. Paths.driver_root(), 1, true) ~= nil, body)
	end)
end)
