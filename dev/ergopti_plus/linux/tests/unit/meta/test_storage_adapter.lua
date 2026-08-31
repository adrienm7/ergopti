--- tests/unit/meta/test_storage_adapter.lua

--- ==============================================================================
--- MODULE: Storage Adapter JSON Round-Trip Regression Guard
--- DESCRIPTION:
--- Verifies that the Linux storage adapter persists and reloads structured
--- values without loss. The adapter serialises its key-value store to
--- storage.json; a value stored with nested tables, arrays, and non-ASCII text
--- must survive a full persist -> reload -> read cycle byte-for-byte.
---
--- ROOT CAUSE ENCODED:
--- storage.lua used a bespoke JSON encoder/decoder. The decoder matched
--- top-level "key":value pairs with a single flat pattern whose value stopped
--- at the first "," or "}", so it could not parse nested objects or arrays: the
--- nested value was dropped and its inner keys leaked to the top level. The
--- encoder also serialised Lua arrays as string-keyed objects. Any non-flat
--- stored value was therefore corrupted on reload. The fix routes encode/decode
--- through the shared _shared/lua/json.lua codec; this test fails (nested/array
--- fields come back nil) against the bespoke codec and passes against json.lua.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Creates a throwaway XDG config root under the system temp directory and
--- ensures its ergopti_plus/ subdirectory exists so the storage adapter can
--- write there instead of the developer's real config.
--- @return string Absolute path to inject as XDG_CONFIG_HOME.
local function make_temp_config_root()
	local base = os.tmpname()
	os.remove(base)
	base = base:gsub("\\", "/"):gsub("/+$", "")
	if package.config:sub(1, 1) == "\\" then
		os.execute(string.format('mkdir "%s" 2>nul', (base .. "/ergopti_plus"):gsub("/", "\\")))
	else
		os.execute(string.format('mkdir -p "%s"', base .. "/ergopti_plus"))
	end
	return base
end





-- ===================================================
-- ===================================================
-- ======= 1/ JSON codec round-trip regression =======
-- ===================================================
-- ===================================================

helpers.describe("storage adapter uses the shared JSON codec", function()
	helpers.it("preserves nested tables, arrays, and unicode across a persist/reload cycle", function()
		-- Redirect the adapter at a hermetic temp store: os.getenv is patched so
		-- the module resolves XDG_CONFIG_HOME to a fresh temp dir at load time,
		-- keeping the developer's real storage.json untouched.
		local temp_root   = make_temp_config_root()
		local real_getenv = os.getenv
		os.getenv = function(name)
			if name == "XDG_CONFIG_HOME" then return temp_root end
			return real_getenv(name)
		end

		local ok, err = pcall(function()
			local storage = helpers.load_module("adapters.storage")
			local original = {
				name   = "café",
				nested = { inner = "résumé", count = 3 },
				list   = { 1, 2, 3 },
			}
			helpers.assert_true(storage.set("profile", original), "set() returns true")

			-- Reloading the module clears its in-memory cache, forcing get() to
			-- decode the value from disk rather than returning the live table.
			storage = helpers.load_module("adapters.storage")
			helpers.assert_eq(storage.get("profile"), original,
				"persisted value must round-trip through the JSON codec")
		end)

		-- Always restore global state so later suites see the real config path
		-- and a fresh storage module; the temp-path instance must not leak.
		os.getenv = real_getenv
		package.loaded["adapters.storage"] = nil
		os.remove(temp_root .. "/ergopti_plus/storage.json")
		os.remove(temp_root .. "/ergopti_plus/storage.json.tmp")
		if not ok then error(err, 0) end
	end)
end)





-- ===================================================
-- ===================================================
-- ======= 2/ Durable mutation transaction ===========
-- ===================================================
-- ===================================================

helpers.describe("storage adapter publishes only durable mutations", function()
	helpers.it("rolls memory back on mkdir, open, write, close, and rename failures", function()
		local temp_root = make_temp_config_root()
		local real_getenv = os.getenv
		local real_open = io.open
		local real_rename = os.rename
		local Shell = require("adapters.shell_runner")
		os.getenv = function(name)
			if name == "XDG_CONFIG_HOME" then return temp_root end
			return real_getenv(name)
		end

		local function restore_faults()
			Shell._reset_runner()
			io.open = real_open
			os.rename = real_rename
		end

		local ok, err = pcall(function()
			local storage = helpers.load_module("adapters.storage")
			helpers.assert_true(storage.set("baseline", "durable"))

			local faults = {
				mkdir = function()
					Shell._set_runner(function() return false end)
					io.open = function(path, mode)
						if path:match("storage%.json%.tmp$") and mode == "w" then return nil, "missing dir" end
						return real_open(path, mode)
					end
				end,
				open = function()
					io.open = function(path, mode)
						if path:match("storage%.json%.tmp$") and mode == "w" then return nil, "refused" end
						return real_open(path, mode)
					end
				end,
				write = function()
					io.open = function(path, mode)
						if path:match("storage%.json%.tmp$") and mode == "w" then
							return { write = function() return nil, "short write" end, close = function() return true end }
						end
						return real_open(path, mode)
					end
				end,
				close = function()
					io.open = function(path, mode)
						if path:match("storage%.json%.tmp$") and mode == "w" then
							return { write = function() return true end, close = function() return nil, "refused" end }
						end
						return real_open(path, mode)
					end
				end,
				rename = function()
					os.rename = function(from, to)
						if from:match("storage%.json%.tmp$") then return nil, "refused" end
						return real_rename(from, to)
					end
				end,
			}

			for _, name in ipairs({ "mkdir", "open", "write", "close", "rename" }) do
				faults[name]()
				helpers.assert_eq(storage.set("candidate", name), false,
					name .. " failure must be reported")
				helpers.assert_eq(storage.get("candidate", "absent"), "absent",
					name .. " failure must not publish to the cache")
				helpers.assert_eq(storage.get("baseline"), "durable",
					name .. " failure must preserve the previous value")
				restore_faults()
			end

			storage = helpers.load_module("adapters.storage")
			helpers.assert_eq(storage.get("baseline"), "durable",
				"a fresh module must see the last durable snapshot")
			helpers.assert_eq(storage.get("candidate", "absent"), "absent")
		end)

		restore_faults()
		os.getenv = real_getenv
		package.loaded["adapters.storage"] = nil
		os.remove(temp_root .. "/ergopti_plus/storage.json")
		os.remove(temp_root .. "/ergopti_plus/storage.json.tmp")
		if not ok then error(err, 0) end
	end)

	helpers.it("commits a related preference set with one durable snapshot", function()
		local temp_root = make_temp_config_root()
		local real_getenv = os.getenv
		os.getenv = function(name)
			if name == "XDG_CONFIG_HOME" then return temp_root end
			return real_getenv(name)
		end

		local storage = helpers.load_module("adapters.storage")
		helpers.assert_true(storage.set_many({ first = "one", second = "two" }))
		storage = helpers.load_module("adapters.storage")
		local first, second = storage.get("first"), storage.get("second")

		os.getenv = real_getenv
		package.loaded["adapters.storage"] = nil
		os.remove(temp_root .. "/ergopti_plus/storage.json")
		helpers.assert_eq(first, "one")
		helpers.assert_eq(second, "two",
			"related preferences must survive together rather than one rename apart")
	end)

	helpers.it("reports failure under an unwritable config root without a memory-only success", function()
		local blocker = os.tmpname()
		local real_getenv = os.getenv
		os.getenv = function(name)
			if name == "XDG_CONFIG_HOME" then return blocker end
			return real_getenv(name)
		end

		local ok, err = pcall(function()
			local storage = helpers.load_module("adapters.storage")
			helpers.assert_eq(storage.set("ephemeral", true), false)
			helpers.assert_eq(storage.get("ephemeral", "absent"), "absent")
			storage = helpers.load_module("adapters.storage")
			helpers.assert_eq(storage.get("ephemeral", "absent"), "absent",
				"restart must agree with the failed mutation result")
		end)

		os.getenv = real_getenv
		package.loaded["adapters.storage"] = nil
		os.remove(blocker)
		if not ok then error(err, 0) end
	end)
end)





-- ===================================================
-- ===================================================
-- ======= 3/ Corrupt-store recovery =================
-- ===================================================
-- ===================================================

helpers.describe("storage adapter preserves corrupt input for recovery", function()
	helpers.it("moves invalid JSON aside before creating a new durable store", function()
		local temp_root = make_temp_config_root()
		local store_path = temp_root .. "/ergopti_plus/storage.json"
		local raw = assert(io.open(store_path, "w"))
		raw:write("{ definitely not JSON")
		raw:close()
		local real_getenv = os.getenv
		os.getenv = function(name)
			if name == "XDG_CONFIG_HOME" then return temp_root end
			return real_getenv(name)
		end

		local recovery_path = nil
		local ok, err = pcall(function()
			local storage = helpers.load_module("adapters.storage")
			helpers.assert_eq(storage.get("missing", "fallback"), "fallback")
			local status = storage.recovery_status()
			helpers.assert_true(type(status) == "table" and status.preserved == true)
			helpers.assert_eq(status.reason, "invalid_json")
			recovery_path = status.path
			local preserved = assert(io.open(recovery_path, "r"))
			helpers.assert_eq(preserved:read("*a"), "{ definitely not JSON")
			preserved:close()

			helpers.assert_true(storage.set("after_recovery", true))
			storage = helpers.load_module("adapters.storage")
			helpers.assert_eq(storage.get("after_recovery"), true)
		end)

		os.getenv = real_getenv
		package.loaded["adapters.storage"] = nil
		os.remove(store_path)
		os.remove(store_path .. ".tmp")
		if recovery_path then os.remove(recovery_path) end
		if not ok then error(err, 0) end
	end)
end)
