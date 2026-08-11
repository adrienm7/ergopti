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
--- The tests inject each real Lua I/O failure mode and assert the observable
--- transaction: false + reason, old resolver value retained, no success claim.
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

--- Loads and initializes a pristine source-tree resolver.
--- @return table config_paths
--- @return string paths_file
local function fresh_resolver()
	local base_dir = make_tmp_dir()
	local real_getenv = os.getenv
	os.getenv = function(name)
		if name == "ERGOPTI_PATHS_FILE" then return nil end
		return real_getenv(name)
	end
	local ok, ConfigPaths = pcall(helpers.load_with_stubs, "infra.config_paths")
	os.getenv = real_getenv
	if not ok then error(ConfigPaths, 0) end
	helpers.assert_true(ConfigPaths.init(base_dir))
	return ConfigPaths, base_dir .. "paths.toml"
end

--- Runs a body with a replacement io.open and always restores it.
--- @param replacement function
--- @param fn function
local function with_open(replacement, fn)
	local real_open = io.open
	io.open = replacement
	local ok, err = xpcall(fn, debug.traceback)
	io.open = real_open
	if not ok then error(err, 0) end
end

--- Asserts one injected write failure cannot publish the requested directory.
--- @param install fun(real_open:function, paths_file:string):function
--- @param expected_reason string
local function assert_transaction_rejected(install, expected_reason)
	local ConfigPaths, paths_file = fresh_resolver()
	local old_dir = ConfigPaths.get_config_dir()
	local requested = make_tmp_dir()
	local real_open = io.open

	with_open(install(real_open, paths_file), function()
		local changed, err = ConfigPaths.set_config_dir(requested)
		helpers.assert_true(changed == false,
			"an unconfirmed paths.toml write must never report a committed change")
		helpers.assert_true(type(err) == "string" and err:find(expected_reason, 1, true) ~= nil,
			"the concrete I/O reason must reach the caller, got: " .. tostring(err))
		helpers.assert_eq(ConfigPaths.get_config_dir(), old_dir,
			"a failed disk transaction must roll the in-memory resolver back")
	end)
end

helpers.describe("ConfigPaths publishes only confirmed paths.toml writes", function()
	helpers.it("rolls back when the target cannot be opened", function()
		assert_transaction_rejected(function(real_open, paths_file)
			return function(path, mode)
				if path:sub(1, #paths_file) == paths_file and mode == "w" then
					return nil, "permission denied"
				end
				return real_open(path, mode)
			end
		end, "permission denied")
	end)

	helpers.it("rolls back when write returns disk-full without raising", function()
		assert_transaction_rejected(function(real_open, paths_file)
			return function(path, mode)
				if path:sub(1, #paths_file) == paths_file and mode == "w" then
					return {
						write = function() return nil, "disk full" end,
						close = function() return true end,
					}
				end
				return real_open(path, mode)
			end
		end, "disk full")
	end)

	helpers.it("rolls back when close reports a late flush failure", function()
		assert_transaction_rejected(function(real_open, paths_file)
			return function(path, mode)
				if path:sub(1, #paths_file) == paths_file and mode == "w" then
					return {
						write = function(self) return self end,
						close = function() return nil, "I/O error" end,
					}
				end
				return real_open(path, mode)
			end
		end, "I/O error")
	end)
end)
