--- tests/unit/lib/test_config_paths_write_transaction.lua

--- ==============================================================================
--- MODULE: Config Paths — Transactional Bootstrap Writes
--- DESCRIPTION:
--- Proves that a paths.toml write is confirmed before the in-memory resolver
--- publishes a new directory.
---
--- ROOT CAUSE ENCODED:
--- save_bootstrap() ignored the return values of io.open/file:write/file:close,
--- while set_config_dir() mutated _bootstrap first and returned only the
--- in-memory comparison. A read-only bundle, full disk, or late close failure
--- therefore looked like success to the path editor, which reloaded and silently
--- restored the old on-disk value. This is the macOS sibling of Windows F-29.
---
--- Low-level open/write/close failures are owned by the FileSystem/TOML writer
--- tests. These tests inject their concrete reasons at the FileSystem port and
--- assert ConfigPaths' observable transaction: false + reason, old resolver
--- value retained, no success claim.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Creates a private real directory and returns it with a trailing separator.
--- @return string
local function make_tmp_dir()
	local path = os.tmpname()
	os.remove(path)
	os.execute('mkdir "' .. path .. '"')
	return path .. "/"
end

local function write_exact(path, content)
	local handle = assert(io.open(path, "wb"))
	assert(handle:write(content))
	assert(handle:close())
end

local function read_exact(path)
	local handle = assert(io.open(path, "rb"))
	local content = assert(handle:read("*a"))
	assert(handle:close())
	return content
end

--- Loads and initializes a pristine source-tree resolver whose replacement
--- publication is rejected by the FileSystem port.
--- @param write_error string Concrete failure returned by FileSystem.write.
--- @return table config_paths
--- @return table observations
local function fresh_resolver(write_error)
	local base_dir = make_tmp_dir()
	local previous_file_system = package.loaded["adapters.file_system"]
	package.loaded["adapters.file_system"] = nil
	local real_file_system = require("adapters.file_system")
	local observations = { writes = 0 }
	local injected_file_system = setmetatable({
		create_if_absent = function()
			return true, "created"
		end,
		write = function()
			observations.writes = observations.writes + 1
			return false, write_error
		end,
		write_if_unchanged = function()
			observations.writes = observations.writes + 1
			return false, write_error
		end,
	}, { __index = real_file_system })
	package.loaded["adapters.file_system"] = injected_file_system
	local real_getenv = os.getenv
	os.getenv = function(name)
		if name == "ERGOPTI_PATHS_FILE" then return nil end
		return real_getenv(name)
	end
	local ok, ConfigPaths = pcall(helpers.load_with_stubs, "infra.config_paths")
	os.getenv = real_getenv
	package.loaded["adapters.file_system"] = previous_file_system
	if not ok then error(ConfigPaths, 0) end
	helpers.assert_true(ConfigPaths.init(base_dir))
	return ConfigPaths, observations
end

--- Asserts one injected FileSystem failure cannot publish the requested directory.
--- @param expected_reason string
local function assert_transaction_rejected(expected_reason)
	local ConfigPaths, observations = fresh_resolver(expected_reason)
	local old_dir = ConfigPaths.get_config_dir()
	local requested = make_tmp_dir()

	local changed, err = ConfigPaths.set_config_dir(requested)
	helpers.assert_true(changed == false,
		"an unconfirmed paths.toml write must never report a committed change")
	helpers.assert_true(type(err) == "string" and err:find(expected_reason, 1, true) ~= nil,
		"the concrete I/O reason must reach the caller, got: " .. tostring(err))
	helpers.assert_eq(ConfigPaths.get_config_dir(), old_dir,
		"a failed disk transaction must roll the in-memory resolver back")
	helpers.assert_eq(1, observations.writes,
		"the repro must reach exactly one replacement publication attempt")
end

helpers.describe("ConfigPaths publishes only confirmed paths.toml writes", function()
	helpers.it("rolls back when the target cannot be opened", function()
		assert_transaction_rejected("permission denied")
	end)

	helpers.it("rolls back when write returns disk-full without raising", function()
		assert_transaction_rejected("disk full")
	end)

	helpers.it("rolls back when close reports a late flush failure", function()
		assert_transaction_rejected("I/O error")
	end)
end)

helpers.describe("ConfigPaths protects the exact bootstrap snapshot", function()
	helpers.it("preserves and adopts a foreign edit that lands before publication", function()
		local base_dir = make_tmp_dir()
		local paths_path = base_dir .. "paths.toml"
		local source_a_dir = base_dir .. "source-a/"
		local foreign_b_dir = base_dir .. "foreign-b/"
		local source_a = 'ConfigDirPath = "' .. source_a_dir .. '"\n'
		local foreign_b = '# foreign exact bytes\nConfigDirPath = "' .. foreign_b_dir .. '"\n'
		write_exact(paths_path, source_a)

		local previous_file_system = package.loaded["adapters.file_system"]
		package.loaded["adapters.file_system"] = nil
		local real_file_system = require("adapters.file_system")
		local observations = { publications = 0 }
		local injected_file_system = setmetatable({
			write = function(path, content)
				observations.publications = observations.publications + 1
				write_exact(path, foreign_b)
				write_exact(path, content)
				return true
			end,
			write_if_unchanged = function(path, _, expected_source)
				observations.publications = observations.publications + 1
				helpers.assert_eq(expected_source.status, "ok")
				helpers.assert_eq(expected_source.content, source_a)
				write_exact(path, foreign_b)
				return false, "source changed before publication"
			end,
		}, { __index = real_file_system })
		package.loaded["adapters.file_system"] = injected_file_system
		local real_getenv = os.getenv
		os.getenv = function(name)
			if name == "ERGOPTI_PATHS_FILE" then return nil end
			return real_getenv(name)
		end
		package.loaded["infra.config_paths"] = nil
		local ConfigPaths = require("infra.config_paths")
		local init_ok = ConfigPaths.init(base_dir)
		os.getenv = real_getenv
		package.loaded["adapters.file_system"] = previous_file_system
		helpers.assert_true(init_ok)

		local changed, err = ConfigPaths.set_config_dir(make_tmp_dir())

		helpers.assert_eq(changed, false, "a stale bootstrap candidate must be refused")
		helpers.assert_true(type(err) == "string" and err:find("source changed", 1, true) ~= nil)
		helpers.assert_eq(observations.publications, 1, "a conflict must never retry publication")
		helpers.assert_eq(read_exact(paths_path), foreign_b, "foreign bytes must survive exactly")
		helpers.assert_eq(ConfigPaths.get_config_dir(), foreign_b_dir,
			"the in-memory resolver must safely adopt the concurrent winner")
	end)
end)
