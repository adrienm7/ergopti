--- tests/unit/infra/test_build_commit.lua

--- ==============================================================================
--- TEST: Build commit and configuration directory in the diagnostics (Linux)
--- DESCRIPTION:
--- An installed package (.deb, .rpm, AppImage, Flatpak, tarball) carries no
--- .git, so every diagnostic surface answered "unknown" for the commit: the
--- healthcheck never sent one at all, the boot snapshot only read .git, and the
--- crash dump had no commit line. Package builds now stamp the commit into the
--- shared tree (tools/build/write_build_stamp.sh); these tests drive the shared
--- resolver and every Linux consumer of it, and pin the configuration directory
--- the healthcheck reports to the one the daemon reads its config from.
--- ==============================================================================

local helpers = require("tests.helpers")

local describe    = helpers.describe
local it          = helpers.it
local assert_eq   = helpers.assert_eq
local assert_true = helpers.assert_true

local Snapshot = require("diagnostics.snapshot")

local SHA = "f58d15798aaaabbbbccccddddeeeeffff0000111"
local SHORT = "f58d15798"
local OTHER_SHA = "3b924cd46aaaabbbbccccddddeeeeffff0000111"




-- =====================================
-- =====================================
-- ======= 1/ Fixtures =================
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

--- Runs body with package.loaded[name] replaced, restoring it afterwards.
--- @param name string
--- @param value any
--- @param body function
local function with_module(name, value, body)
	local previous = package.loaded[name]
	package.loaded[name] = value
	local ok, err = pcall(body)
	package.loaded[name] = previous
	if not ok then error(err, 0) end
end

-- A package tree with a stamp, and a checkout on another commit, so an answer
-- from the wrong source cannot pass.
local PACKAGE_FILES = {
	["/usr/lib/ergopti/_shared/" .. Snapshot.BUILD_STAMP_FILE] = "commit=" .. SHA .. "\n",
	["/usr/lib/.git/HEAD"] = OTHER_SHA .. "\n",
}




-- =====================================
-- =====================================
-- ======= 2/ Shared resolver ==========
-- =====================================
-- =====================================

describe("Build commit: the shared stamp parser and resolver", function()
	it("parses the stamp the build writes into an abbreviated commit", function()
		assert_eq(SHORT, (Snapshot.parse_build_stamp("commit=" .. SHA .. "\n")))
		assert_eq(SHORT, (Snapshot.parse_build_stamp("commit=" .. SHA:upper() .. "\r\n")),
			"case and CRLF from a hand-copied stamp still resolve to the canonical id")
	end)

	it("rejects a stamp whose commit is not a full id, with the reason", function()
		local commit, reason = Snapshot.parse_build_stamp("commit=__BUNDLE_COMMIT__\n")
		assert_eq(nil, commit)
		assert_true(reason ~= nil and reason:find("__BUNDLE_COMMIT__", 1, true) ~= nil, tostring(reason))
		commit, reason = Snapshot.parse_build_stamp("version=3.0.0\n")
		assert_eq(nil, commit)
		assert_true(reason ~= nil and reason:find("no commit entry", 1, true) ~= nil, tostring(reason))
	end)

	it("reports an absent stamp as absent, not as invalid", function()
		local commit, reason = Snapshot.build_commit(fixture_fs({}), "/usr/lib/ergopti/_shared")
		assert_eq(nil, commit)
		assert_eq(nil, reason)
	end)

	it("prefers the build stamp over any git checkout", function()
		local commit, source = Snapshot.resolve_commit(fixture_fs(PACKAGE_FILES),
			"/usr/lib/ergopti/_shared/", "/usr/lib/ergopti")
		assert_eq(SHORT, commit)
		assert_eq(Snapshot.COMMIT_SOURCE_BUILD, source)
	end)

	it("never hides a broken stamp behind a git answer", function()
		local commit, source, detail = Snapshot.resolve_commit(fixture_fs({
			["/usr/lib/ergopti/_shared/" .. Snapshot.BUILD_STAMP_FILE] = "commit=nope\n",
			["/usr/lib/.git/HEAD"] = OTHER_SHA .. "\n",
		}), "/usr/lib/ergopti/_shared", "/usr/lib/ergopti")
		assert_eq(Snapshot.UNKNOWN, commit)
		assert_eq(Snapshot.COMMIT_SOURCE_UNKNOWN, source)
		assert_true(detail ~= nil and detail:find("nope", 1, true) ~= nil, tostring(detail))
	end)

	it("answers a source run from its git checkout", function()
		local commit, source = Snapshot.resolve_commit(fixture_fs({
			["/repo/.git/HEAD"] = OTHER_SHA .. "\n",
		}), "/repo/static/ergopti_plus/_shared", "/repo/static/ergopti_plus/linux")
		assert_eq("3b924cd46", commit)
		assert_eq(Snapshot.COMMIT_SOURCE_GIT, source)
	end)

	it("answers unknown with both places it looked when neither exists", function()
		local commit, source, detail = Snapshot.resolve_commit(fixture_fs({}), "/opt/e/_shared", "/opt/e/linux")
		assert_eq(Snapshot.UNKNOWN, commit)
		assert_eq(Snapshot.COMMIT_SOURCE_UNKNOWN, source)
		assert_true(detail:find(Snapshot.BUILD_STAMP_FILE, 1, true) ~= nil, detail)
		assert_true(detail:find("/opt/e/linux", 1, true) ~= nil, detail)
	end)

	it("the source tree ships no stamp, so a checkout reports its real HEAD", function()
		local Paths = require("infra.paths")
		local stamp = Paths.shared(Snapshot.BUILD_STAMP_FILE)
		local fh = stamp and io.open(stamp, "r")
		if fh then fh:close() end
		assert_eq(nil, fh, "a committed or leftover stamp would make every source run claim that build")
	end)
end)




-- =====================================
-- =====================================
-- ======= 3/ Linux consumers ==========
-- =====================================
-- =====================================

describe("Build commit: the Linux snapshot resolves and logs", function()
	local Collector = helpers.load_module("infra.diagnostic_snapshot")

	it("the snapshot's commit field is the package stamp", function()
		local values = Collector.collect({
			shared_root = "/usr/lib/ergopti/_shared", script_dir = "/usr/lib/ergopti",
		}, fixture_fs(PACKAGE_FILES))
		assert_eq(SHORT, values.commit)
	end)

	it("an unknown commit is logged with its reason, never silently", function()
		local commit, source
		local lines = capture_logs(function()
			commit, source = Collector.resolve_commit({
				env = fixture_fs({}), shared_root = "/opt/e/_shared", source_dir = "/opt/e/linux",
			})
		end)
		assert_eq(Snapshot.UNKNOWN, commit)
		assert_eq(Snapshot.COMMIT_SOURCE_UNKNOWN, source)
		local logged = false
		for _, line in ipairs(lines) do
			if line:find("[WARNING]", 1, true) and line:find("Build commit unknown", 1, true)
				and line:find(Snapshot.BUILD_STAMP_FILE, 1, true) then
				logged = true
			end
		end
		assert_true(logged, "expected a WARNING naming the missing stamp; got:\n" .. table.concat(lines, "\n"))
	end)

	it("a resolved commit logs no warning", function()
		local lines = capture_logs(function()
			Collector.resolve_commit({
				env = fixture_fs(PACKAGE_FILES), shared_root = "/usr/lib/ergopti/_shared",
				source_dir = "/usr/lib/ergopti",
			})
		end)
		for _, line in ipairs(lines) do
			assert_eq(nil, line:find("Build commit unknown", 1, true), line)
		end
	end)
end)

describe("Build commit: the healthcheck reports the commit and the real config dir", function()
	it("sends the resolved commit, its source, the config dir and the script dir", function()
		local ConfigPaths = require("infra.config_paths")
		local Paths = require("infra.paths")
		local handler = helpers.load_module("ui.healthcheck.bridge")
		local result
		with_module("infra.diagnostic_snapshot", {
			resolve_commit = function() return SHORT, Snapshot.COMMIT_SOURCE_BUILD end,
		}, function()
			result = handler.on_message("ready", {})
		end)
		assert_true(type(result) == "table" and type(result.sys) == "table", "the snapshot carries sys")
		assert_eq(SHORT, result.sys.git_hash, "the page's Last git commit row must not read unknown")
		assert_eq(Snapshot.COMMIT_SOURCE_BUILD, result.sys.commit_source)
		assert_eq(ConfigPaths.get_config_dir(), result.sys.config_dir,
			"the config dir is the one config_paths resolves, not the install tree")
		assert_eq(Paths.driver_root(), result.sys.script_dir)
		assert_true(result.sys.config_dir ~= result.sys.script_dir,
			"the config dir and the script dir are different places")
	end)
end)

describe("Build commit: the crash dump names the build and the config dir", function()
	it("writes the resolved commit and the configuration directory", function()
		local ConfigPaths = require("infra.config_paths")
		local Reporter = helpers.load_module("modules.diagnostics.crash_reporter")
		local real_open, real_exec, real_popen = io.open, os.execute, io.popen
		local parts = {}
		with_module("infra.diagnostic_snapshot", {
			resolve_commit = function() return SHORT, Snapshot.COMMIT_SOURCE_BUILD end,
		}, function()
			io.open = function()
				return {
					write = function(_, s) parts[#parts + 1] = s; return true end,
					close = function() return true end,
				}
			end
			os.execute = function() return true end
			io.popen = function() return nil end
			local ok, err = pcall(Reporter.dump, "engine", "boom")
			io.open, os.execute, io.popen = real_open, real_exec, real_popen
			if not ok then error(err, 0) end
		end)
		local body = table.concat(parts)
		assert_true(body:find("Commit:    " .. SHORT .. " (build)", 1, true) ~= nil, body)
		assert_true(body:find("Config:    " .. ConfigPaths.get_config_dir(), 1, true) ~= nil, body)
	end)

	it("a resolver failure is written as its reason and the dump survives", function()
		local Reporter = helpers.load_module("modules.diagnostics.crash_reporter")
		local real_open, real_exec, real_popen = io.open, os.execute, io.popen
		local parts = {}
		with_module("infra.diagnostic_snapshot", {
			resolve_commit = function() error("stamp read exploded") end,
		}, function()
			io.open = function()
				return {
					write = function(_, s) parts[#parts + 1] = s; return true end,
					close = function() return true end,
				}
			end
			os.execute = function() return true end
			io.popen = function() return nil end
			local ok, err = pcall(Reporter.dump, "engine", "boom")
			io.open, os.execute, io.popen = real_open, real_exec, real_popen
			if not ok then error(err, 0) end
		end)
		local body = table.concat(parts)
		assert_true(body:find("Commit:    unknown (resolution failed:", 1, true) ~= nil, body)
		assert_true(body:find("stamp read exploded", 1, true) ~= nil, body)
		assert_true(body:find("Error:     boom", 1, true) ~= nil, "the dump itself is still written")
	end)
end)
