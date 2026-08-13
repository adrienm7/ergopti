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
