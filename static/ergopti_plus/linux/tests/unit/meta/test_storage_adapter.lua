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

helpers.describe("storage exclusive temporary ownership", function()
	for _, method in ipairs({ "set", "set_many", "delete", "clear" }) do
		for _, alias in ipairs({ "regular", "symlink", "hardlink", "dangling" }) do
			helpers.it("linux-storage-exclusive-temp: " .. method .. " refuses foreign " .. alias .. " staging", function()
				local root = make_temp_config_root()
				local path, target = root .. "/ergopti_plus/storage.json", root .. "/foreign"
				local original, foreign = '{"value":"retained"}', "Retained foreign bytes"
				local function write(name, bytes)
					local file = assert(io.open(name, "wb")); assert(file:write(bytes) and file:close())
				end
				local function read(name)
					local file = assert(io.open(name, "rb")); local bytes = assert(file:read("*a")); assert(file:close()); return bytes
				end
				write(path, original)
				if alias ~= "dangling" then write(target, foreign) end
				local Shell = require("adapters.shell_runner")
				if alias == "regular" then write(path .. ".tmp", foreign)
				else helpers.assert_true(Shell.run("ln " .. (alias == "hardlink" and "" or "-s ") .. "-- " .. Shell.quote(target) .. " " .. Shell.quote(path .. ".tmp"))) end
				local real_getenv = os.getenv
				os.getenv = function(name) if name == "XDG_CONFIG_HOME" then return root end; return real_getenv(name) end
				local ok, err = xpcall(function()
					local storage = helpers.load_module("adapters.storage")
					helpers.assert_eq(storage.get("value"), "retained")
					local result
					if method == "set" then result = storage.set("value", "replacement")
					elseif method == "set_many" then result = storage.set_many({ candidate = true })
					elseif method == "delete" then result = storage.delete("value")
					else result = storage.clear() end
					helpers.assert_eq(result, false)
					helpers.assert_eq(storage.get("value"), "retained")
					helpers.assert_nil(storage.get("candidate"))
					helpers.assert_eq(read(path), original)
					if alias == "dangling" then helpers.assert_nil(io.open(target, "rb"))
					else helpers.assert_eq(read(target), foreign); helpers.assert_eq(read(path .. ".tmp"), foreign) end
				end, debug.traceback)
				os.getenv = real_getenv
				package.loaded["adapters.storage"] = nil
				os.remove(path .. ".tmp"); os.remove(path); os.remove(target)
				os.remove(root .. "/ergopti_plus"); os.remove(root)
				helpers.assert_true(ok, tostring(err))
			end)
		end
	end
end)

helpers.describe("storage native open receipts", function()
	for _, receipt in ipairs({ 13, 1, 20, 5, 24, 40, "unknown", "throw" }) do
		helpers.it("linux-storage-read-receipts: blocks mutation after " .. receipt, function()
			local root = make_temp_config_root()
			local path = root .. "/ergopti_plus/storage.json"
			local original = '{"preserve":"original"}'
			local file = assert(io.open(path, "wb"))
			assert(file:write(original) and file:close())
			local real_getenv, real_open = os.getenv, io.open
			local writes = 0
			os.getenv = function(name)
				if name == "XDG_CONFIG_HOME" then return root end
				return real_getenv(name)
			end
			io.open = function(target, mode)
				if target == path and mode == "r" then
					if receipt == "throw" then error("native open raised") end
					return nil, "native open refused", type(receipt) == "number" and receipt or nil
				end
				if target == path .. ".tmp" and mode == "wx" then writes = writes + 1 end
				return real_open(target, mode)
			end
			local ok, err = xpcall(function()
				local storage = helpers.load_module("adapters.storage")
				helpers.assert_eq(storage.set("replacement", true), false)
				helpers.assert_eq(storage.set_many({ replacement = true }), false)
				helpers.assert_eq(storage.delete("preserve"), false)
				helpers.assert_eq(storage.clear(), false)
				helpers.assert_eq(writes, 0, "unclassified source cannot start a write")
				local recovery = storage.recovery_status()
				helpers.assert_eq(recovery.reason, "read_failed")
				helpers.assert_eq(recovery.path, path)
				helpers.assert_eq(recovery.preserved, true)
			end, debug.traceback)
			os.getenv, io.open = real_getenv, real_open
			package.loaded["adapters.storage"] = nil
			file = assert(io.open(path, "rb"))
			local preserved = file:read("*a")
			assert(file:close())
			os.remove(path)
			os.remove(path .. ".tmp")
			os.remove(root .. "/ergopti_plus")
			os.remove(root)
			helpers.assert_true(ok, tostring(err))
			helpers.assert_eq(preserved, original)
		end)
	end
end)

helpers.describe("storage root JSON shape", function()
	for index, body in ipairs({ "[]", '["original"]', '[{"keep":"é","nested":[1,2]}]', '[null,"original"]' }) do
		helpers.it("linux-storage-shape-receipts: preserves array history " .. index, function()
			local root = make_temp_config_root()
			local path = root .. "/ergopti_plus/storage.json"
			local file = assert(io.open(path, "wb"))
			assert(file:write(body) and file:close())
			local real_getenv = os.getenv
			os.getenv = function(name)
				if name == "XDG_CONFIG_HOME" then return root end
				return real_getenv(name)
			end
			local ok, err = xpcall(function()
				local storage = helpers.load_module("adapters.storage")
				helpers.assert_eq(storage.get("any", "fallback"), "fallback")
				local recovery = storage.recovery_status()
				helpers.assert_true(recovery and recovery.preserved == true)
				file = assert(io.open(recovery.path, "rb"))
				local bytes = file:read("*a")
				assert(file:close())
				helpers.assert_eq(bytes, body)
				helpers.assert_true(storage.set("replacement", true))
				helpers.assert_eq(helpers.load_module("adapters.storage").get("replacement"), true)
			end, debug.traceback)
			os.getenv = real_getenv
			package.loaded["adapters.storage"] = nil
			os.remove(path)
			os.remove(path .. ".corrupt")
			os.remove(root .. "/ergopti_plus")
			os.remove(root)
			helpers.assert_true(ok, tostring(err))
		end)
	end
end)

helpers.describe("storage durable snapshot ownership", function()
	for _, method in ipairs({ "set", "set_many" }) do
		for _, source in ipairs({ "input", "returned", "refused" }) do
			helpers.it("linux-storage-snapshot-receipts: " .. method .. " detaches " .. source, function()
				local root = make_temp_config_root()
				local path = root .. "/ergopti_plus/storage.json"
				local real_getenv, real_rename = os.getenv, os.rename
				os.getenv = function(name)
					if name == "XDG_CONFIG_HOME" then return root end
					return real_getenv(name)
				end
				local ok, err = xpcall(function()
					local storage = helpers.load_module("adapters.storage")
					local profile = { title = "original", nested = { values = { "é", "original" } } }
					local function persist(value)
						if method == "set" then return storage.set("profile", value) end
						return storage.set_many({ profile = value, peer = { enabled = true } })
					end
					helpers.assert_true(persist(profile))
					local changed = source == "input" and profile or storage.get("profile")
					changed.title, changed.nested.values[2] = "changed", "changed"
					if source == "refused" then
						os.rename = function() return nil, "publication refused", 13 end
						helpers.assert_eq(persist(changed), false)
						os.rename = real_rename
					end
					local retained = storage.get("profile")
					helpers.assert_eq(retained.title, "original")
					helpers.assert_eq(retained.nested.values[2], "original")
					local reloaded = helpers.load_module("adapters.storage").get("profile")
					helpers.assert_eq(retained, reloaded, "live cache must equal its durable snapshot")
				end, debug.traceback)
				os.getenv, os.rename = real_getenv, real_rename
				package.loaded["adapters.storage"] = nil
				os.remove(path)
				os.remove(path .. ".tmp")
				os.remove(root .. "/ergopti_plus")
				os.remove(root)
				helpers.assert_true(ok, tostring(err))
			end)
		end
	end
end)

helpers.describe("storage backup open receipts", function()
	for _, receipt in ipairs({ 13, 5, "unknown", "throw" }) do
		helpers.it("linux-storage-backup-receipts: preserves prior backup after " .. receipt, function()
			local root = make_temp_config_root()
			local path = root .. "/ergopti_plus/storage.json"
			local backup = path .. ".corrupt"
			local originals = { [path] = "{ broken current bytes", [backup] = "{ older recovery bytes" }
			for target, bytes in pairs(originals) do
				local file = assert(io.open(target, "wb"))
				assert(file:write(bytes) and file:close())
			end
			local real_getenv, real_open = os.getenv, io.open
			os.getenv = function(name)
				if name == "XDG_CONFIG_HOME" then return root end
				return real_getenv(name)
			end
			io.open = function(target, mode)
				if target == backup and mode == "r" then
					if receipt == "throw" then error("native backup open raised") end
					return nil, "native backup open refused", type(receipt) == "number" and receipt or nil
				end
				return real_open(target, mode)
			end
			local ok, err = xpcall(function()
				local storage = helpers.load_module("adapters.storage")
				helpers.assert_eq(storage.get("any", "fallback"), "fallback")
				helpers.assert_eq(storage.set("replacement", true), false)
				local recovery = storage.recovery_status()
				helpers.assert_eq(recovery.path, path)
				helpers.assert_eq(recovery.preserved, false)
			end, debug.traceback)
			os.getenv, io.open = real_getenv, real_open
			package.loaded["adapters.storage"] = nil
			local preserved = {}
			for target in pairs(originals) do
				local file = io.open(target, "rb")
				if file then preserved[target] = file:read("*a"); assert(file:close()) end
				os.remove(target)
			end
			os.remove(path .. ".tmp")
			os.remove(root .. "/ergopti_plus")
			os.remove(root)
			helpers.assert_true(ok, tostring(err))
			helpers.assert_eq(preserved, originals, "both byte histories must remain intact")
		end)
	end
end)





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
						if path:match("storage%.json%.tmp$") and mode == "wx" then return nil, "missing dir" end
						return real_open(path, mode)
					end
				end,
				open = function()
					io.open = function(path, mode)
						if path:match("storage%.json%.tmp$") and mode == "wx" then return nil, "refused" end
						return real_open(path, mode)
					end
				end,
				write = function()
					io.open = function(path, mode)
						if path:match("storage%.json%.tmp$") and mode == "wx" then
							return { write = function() return nil, "short write" end, close = function() return true end }
						end
						return real_open(path, mode)
					end
				end,
				close = function()
					io.open = function(path, mode)
						if path:match("storage%.json%.tmp$") and mode == "wx" then
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
		-- Establish the precondition for real: a file where the directory
		-- must be makes the root genuinely unwritable on every platform. A
		-- bare tmpname only reserves a name, and a working mkdir -p would
		-- simply create the directories and let the mutation succeed.
		do
			local guard = assert(io.open(blocker, "w"))
			guard:close()
		end
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
