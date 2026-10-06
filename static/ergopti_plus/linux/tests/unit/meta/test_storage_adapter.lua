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

helpers.describe("storage concurrent backup ownership", function()
	for _, result in ipairs({ "EEXIST", "EACCES", "unlink-refused", "success" }) do
		helpers.it("linux-storage-backup-link: checks native fallback " .. result .. " receipts", function()
			local real_ffi, real_preload, real_uv = package.loaded.ffi, package.preload.ffi, package.loaded.luv
			local links, removals = 0, 0
			package.loaded.ffi = nil
			package.preload.ffi = function() error("stock Lua fixture has no FFI") end
			package.loaded.luv = {
				fs_link = function(source, destination)
					helpers.assert_eq(source, "source"); helpers.assert_eq(destination, "backup")
					links = links + 1
					if result == "EEXIST" or result == "EACCES" then return nil, "refused", result end
					return true
				end,
				fs_unlink = function(source)
					helpers.assert_eq(source, "source")
					removals = removals + 1
					if result == "unlink-refused" then return nil, "refused", "EACCES" end
					return true
				end,
			}
			local ok, err = xpcall(function()
				local mover = assert(loadfile("infra/no_replace_move.lua"))()
				local moved, failure = mover.move("source", "backup")
				helpers.assert_eq(moved, result == "success")
				local expected_failure
				if result ~= "success" then expected_failure = result == "unlink-refused" and "EACCES" or result end
				helpers.assert_eq(failure, expected_failure)
				helpers.assert_eq(links, 1)
				helpers.assert_eq(removals, (result == "success" or result == "unlink-refused") and 1 or 0)
			end, debug.traceback)
			package.loaded.ffi, package.preload.ffi, package.loaded.luv = real_ffi, real_preload, real_uv
			helpers.assert_true(ok, tostring(err))
		end)
	end
	for _, alias in ipairs({ "regular", "dangling" }) do
		for _, depth in ipairs({ 0, 1 }) do
			helpers.it("linux-storage-backup-race: retains concurrent " .. alias .. " at suffix " .. depth, function()
				local root = make_temp_config_root()
				local path = root .. "/ergopti_plus/storage.json"
				local backup = path .. ".corrupt" .. (depth == 0 and "" or ".1")
				local original, history = "{Malformed original bytes", "Retained concurrent backup bytes"
				local real_open, real_getenv = io.open, os.getenv
				local function write(name, bytes)
					local file = assert(real_open(name, "wb")); assert(file:write(bytes) and file:close())
				end
				local function read(name)
					local file = assert(real_open(name, "rb")); local bytes = assert(file:read("*a")); assert(file:close()); return bytes
				end
				write(path, original)
				if depth == 1 then write(path .. ".corrupt", history) end
				os.getenv = function(name) if name == "XDG_CONFIG_HOME" then return root end; return real_getenv(name) end
				local claimed = false
				io.open = function(name, mode)
					if name == backup and mode == "r" and not claimed then
						claimed = true
						if alias == "regular" then write(backup, history)
						else
							local Shell = require("adapters.shell_runner")
							helpers.assert_true(Shell.run("ln -s -- " .. Shell.quote(root .. "/missing") .. " " .. Shell.quote(backup)))
						end
						return nil, "No such file or directory", 2
					end
					return real_open(name, mode)
				end
				local next_backup = path .. ".corrupt." .. (depth + 1)
				local ok, err = xpcall(function()
					local storage = helpers.load_module("adapters.storage")
					helpers.assert_eq(storage.get("value", "default"), "default")
					helpers.assert_true(claimed)
					local recovery = storage.recovery_status()
					helpers.assert_true(recovery and recovery.preserved)
					helpers.assert_eq(recovery.path, next_backup)
					helpers.assert_eq(read(next_backup), original)
					if alias == "regular" then helpers.assert_eq(read(backup), history)
					else
						local Shell = require("adapters.shell_runner")
						helpers.assert_true(Shell.run("test -L " .. Shell.quote(backup)))
						helpers.assert_nil(real_open(root .. "/missing", "r"))
					end
					if depth == 1 then helpers.assert_eq(read(path .. ".corrupt"), history) end
					helpers.assert_true(storage.set("value", "replacement"))
				end, debug.traceback)
				io.open, os.getenv = real_open, real_getenv
				package.loaded["adapters.storage"] = nil
				os.remove(backup); os.remove(next_backup); os.remove(path .. ".corrupt"); os.remove(path)
				os.remove(root .. "/ergopti_plus"); os.remove(root)
				helpers.assert_true(ok, tostring(err))
			end)
		end
	end
end)

helpers.describe("storage backup path inspection", function()
	for _, alias in ipairs({ "dangling", "directory", "symlink", "regular" }) do
		for _, depth in ipairs({ 0, 1 }) do
			helpers.it("linux-storage-backup-type: skips occupied " .. alias .. " at suffix " .. depth, function()
				local root = make_temp_config_root()
				local path = root .. "/ergopti_plus/storage.json"
				local backup = path .. ".corrupt" .. (depth == 0 and "" or ".1")
				local target, original, history = root .. "/foreign", "{malformed original bytes", "Retained previous bytes"
				local function write(name, bytes)
					local file = assert(io.open(name, "wb")); assert(file:write(bytes) and file:close())
				end
				local function read(name)
					local file = assert(io.open(name, "rb")); local bytes = assert(file:read("*a")); assert(file:close()); return bytes
				end
				write(path, original)
				if depth == 1 then write(path .. ".corrupt", history) end
				local Shell = require("adapters.shell_runner")
				if alias == "regular" then write(backup, history)
				elseif alias == "directory" then helpers.assert_true(Shell.run("mkdir -- " .. Shell.quote(backup)))
				else
					if alias == "symlink" then write(target, history) end
					helpers.assert_true(Shell.run("ln -s -- " .. Shell.quote(target) .. " " .. Shell.quote(backup)))
				end
				local real_getenv = os.getenv
				os.getenv = function(name) if name == "XDG_CONFIG_HOME" then return root end; return real_getenv(name) end
				local next_backup = path .. ".corrupt." .. (depth + 1)
				local ok, err = xpcall(function()
					local storage = helpers.load_module("adapters.storage")
					helpers.assert_nil(storage.get("value"))
					local recovery = storage.recovery_status()
					helpers.assert_true(recovery and recovery.preserved)
					helpers.assert_eq(recovery.path, next_backup)
					helpers.assert_eq(read(next_backup), original)
					helpers.assert_true(storage.set("value", "replacement"))
					if depth == 1 then helpers.assert_eq(read(path .. ".corrupt"), history) end
					if alias == "dangling" or alias == "symlink" then helpers.assert_true(Shell.run("test -L " .. Shell.quote(backup))) end
					if alias == "dangling" then helpers.assert_nil(io.open(target, "rb"))
					elseif alias == "symlink" then helpers.assert_eq(read(target), history)
					elseif alias == "regular" then helpers.assert_eq(read(backup), history) end
				end, debug.traceback)
				os.getenv = real_getenv
				package.loaded["adapters.storage"] = nil
				os.remove(backup); os.remove(next_backup); os.remove(path .. ".corrupt")
				os.remove(path); os.remove(target); os.remove(root .. "/ergopti_plus"); os.remove(root)
				helpers.assert_true(ok, tostring(err))
			end)
		end
	end
	for _, kind in ipairs({ "refused", "empty", "unknown", "raised" }) do
		helpers.it("linux-storage-backup-type: refuses " .. kind .. " native inspection", function()
			local root = make_temp_config_root()
			local path, original = root .. "/ergopti_plus/storage.json", "{malformed original bytes"
			local file = assert(io.open(path, "wb")); assert(file:write(original) and file:close())
			local Shell = require("adapters.shell_runner")
			local real_checked, real_getenv = Shell.exec_checked, os.getenv
			os.getenv = function(name) if name == "XDG_CONFIG_HOME" then return root end; return real_getenv(name) end
			Shell.exec_checked = function()
				if kind == "raised" then error("Synthetic private inspection error") end
				return kind ~= "refused", kind == "unknown" and "unknown" or "", "inspection refused"
			end
			local ok, err = xpcall(function()
				local storage = helpers.load_module("adapters.storage")
				helpers.assert_nil(storage.get("value"))
				helpers.assert_eq(storage.recovery_status().preserved, false)
				helpers.assert_eq(storage.set("value", "replacement"), false)
				local retained = assert(io.open(path, "rb")); helpers.assert_eq(retained:read("*a"), original); assert(retained:close())
			end, debug.traceback)
			Shell.exec_checked, os.getenv = real_checked, real_getenv
			package.loaded["adapters.storage"] = nil
			os.remove(path .. ".corrupt"); os.remove(path); os.remove(root .. "/ergopti_plus"); os.remove(root)
			helpers.assert_true(ok, tostring(err))
		end)
	end
end)

helpers.describe("storage regular-source descriptor receipts", function()
	local cases = {
		{ kind = "file", accepted = true },
		{ kind = "fifo" },
		{ kind = "directory" },
		{ kind = "socket" },
		{ stat_throws = true },
		{ open_throws = true, kind = "file" },
		{ close_refused = true, kind = "file" },
		{ missing = true },
		{},
	}
	for number, case in ipairs(cases) do
		helpers.it("linux-storage-special-source: descriptor receipt " .. number, function()
			local Reader = require("infra.regular_file_reader")
			local real_uv, real_open = package.loaded.luv, io.open
			local closes, stream_opens, stream_closes = 0, 0, 0
			local stream = { close = function() stream_closes = stream_closes + 1; return true end }
			package.loaded.luv = {
				fs_open = function(path, flags)
					helpers.assert_eq(path, "/synthetic/storage.json")
					helpers.assert_true(flags % 4096 >= 2048, "native open must not wait on a FIFO")
					helpers.assert_true(math.floor(flags / 524288) % 2 == 1, "the owned descriptor must not survive exec")
					if case.missing then return nil, "absent", "ENOENT" end
					return 42
				end,
				fs_fstat = function(fd)
					helpers.assert_eq(fd, 42)
					if case.stat_throws then error("native metadata raised") end
					return case.kind and { type = case.kind } or nil
				end,
				fs_close = function(fd) helpers.assert_eq(fd, 42); closes = closes + 1; return not case.close_refused end,
			}
			io.open = function(path, mode)
				helpers.assert_eq(path, "/proc/self/fd/42", "reopen the pinned inode, not a replaceable filename")
				helpers.assert_eq(mode, "r")
				stream_opens = stream_opens + 1
				if case.open_throws then error("native stream open raised") end
				return stream
			end
			local ok, opened, _, errno = pcall(Reader.open, "/synthetic/storage.json")
			package.loaded.luv, io.open = real_uv, real_open
			helpers.assert_true(ok, tostring(opened))
			if case.accepted then helpers.assert_eq(opened, stream) else helpers.assert_nil(opened) end
			helpers.assert_eq(closes, case.missing and 0 or 1)
			helpers.assert_eq(stream_opens, case.kind == "file" and 1 or 0)
			helpers.assert_eq(stream_closes, case.close_refused and 1 or 0)
			if case.missing then helpers.assert_eq(errno, 2) end
		end)
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
				if mode == "r" and (target == path or target:match("^/proc/self/fd/%d+$")) then
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
		local native_uv = _VERSION ~= "Lua 5.1" and require("luv") or nil
		local uv_open = native_uv and native_uv.fs_open
		local uv_write = native_uv and native_uv.fs_write
		local uv_close = native_uv and native_uv.fs_close
		local Shell = require("adapters.shell_runner")
		os.getenv = function(name)
			if name == "XDG_CONFIG_HOME" then return temp_root end
			return real_getenv(name)
		end

		local function restore_faults()
			Shell._reset_runner()
			io.open = real_open
			os.rename = real_rename
			if native_uv then
				native_uv.fs_open, native_uv.fs_write, native_uv.fs_close = uv_open, uv_write, uv_close
			end
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
					if native_uv then
						native_uv.fs_open = function(path, mode, permissions)
							if path:match("storage%.json%.tmp$") and mode == "wx" then return nil, "missing dir" end
							return uv_open(path, mode, permissions)
						end
					end
				end,
				open = function()
					io.open = function(path, mode)
						if path:match("storage%.json%.tmp$") and mode == "wx" then return nil, "refused" end
						return real_open(path, mode)
					end
					if native_uv then
						native_uv.fs_open = function(path, mode, permissions)
							if path:match("storage%.json%.tmp$") and mode == "wx" then return nil, "refused" end
							return uv_open(path, mode, permissions)
						end
					end
				end,
				write = function()
					io.open = function(path, mode)
						if path:match("storage%.json%.tmp$") and mode == "wx" then
							return { write = function() return nil, "short write" end, close = function() return true end }
						end
						return real_open(path, mode)
					end
					if native_uv then native_uv.fs_write = function() return nil, "short write" end end
				end,
				close = function()
					io.open = function(path, mode)
						if path:match("storage%.json%.tmp$") and mode == "wx" then
							return { write = function() return true end, close = function() return nil, "refused" end }
						end
						return real_open(path, mode)
					end
					if native_uv then
						native_uv.fs_close = function(fd)
							uv_close(fd)
							return nil, "refused"
						end
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

--- Runs actual native files under an isolated XDG root and restores the fixture.
--- @param source string|nil Independent initial JSON bytes.
--- @param callback function
local function storage_cohort_fixture(source, callback)
	local root = make_temp_config_root()
	local path = root .. "/ergopti_plus/storage.json"
	local function write(name, bytes) local file = assert(io.open(name, "wb")); assert(file:write(bytes)); assert(file:close()) end
	local function read(name)
		local file = io.open(name, "rb"); if not file then return nil end
		local bytes = assert(file:read("*a")); assert(file:close()); return bytes
	end
	if source ~= nil then write(path, source) end
	local getenv, previous = os.getenv, package.loaded["adapters.storage"]
	os.getenv = function(name) if name == "XDG_CONFIG_HOME" then return root end; return getenv(name) end
	local okay, detail = xpcall(function()
		callback(helpers.load_module("adapters.storage"), require("adapters.file_system"), path, root .. "/snapshot", write, read)
	end, debug.traceback)
	os.getenv, package.loaded["adapters.storage"] = getenv, previous
	local Shell = require("adapters.shell_runner"); assert(Shell.run("rm -rf -- " .. Shell.quote(root)))
	if not okay then error(detail, 0) end
end

helpers.describe("native script storage cohorts", function()
	helpers.it("script-storage-cohort exact alias gates and primary pending admission", function()
		storage_cohort_fixture('{"a":false,"foreign":4}', function(storage, _, path, _, _, read)
			local owner, other = { pending = function() return false end }, {}
			for _, keys in ipairs({ {}, { "a", "a" }, { [2] = "a" }, { "" }, { "a\0b" } }) do helpers.assert_eq(storage.acquire_owned(owner, keys), false) end
			helpers.assert_true(storage.acquire_owned(owner, { "a", "missing" }))
			helpers.assert_eq(storage.acquire_owned(owner, { "a" }), false)
			helpers.assert_eq(storage.acquire_owned(other, { "a", "foreign" }), false)
			helpers.assert_true(storage.acquire_owned(other, { "foreign" }))
			local receipt = assert(storage.capture_owned(owner)); helpers.assert_eq(storage.pending_owned(owner, receipt), false)
			helpers.assert_eq(storage.set("a", true), false); helpers.assert_eq(storage.delete("missing"), false)
			helpers.assert_eq(storage.set_many({ a = true, untouched = 1 }), false); helpers.assert_eq(storage.clear(), false)
			helpers.assert_eq(read(path), '{"a":false,"foreign":4}')
			owner.pending = function() return true end; helpers.assert_eq(storage.release_owned(owner), false)
			owner.pending = function() return nil end; helpers.assert_eq(storage.release_owned(owner), false)
			owner.pending = function() return false end; helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.release_owned(other))
		end)
	end)

	helpers.it("script-storage-cohort detached private capture refuses forged and unowned updates", function()
		storage_cohort_fixture('{"a":{"list":[1,2]},"b":false}', function(storage, files, path, backup, _, read)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a", "b", "absent" }))
			local receipt, cells = storage.capture_owned(owner)
			helpers.assert_true(cells.a.present); helpers.assert_eq(cells.b.value, false); helpers.assert_eq(cells.absent.present, false)
			cells.a.value.list[1], cells.b.present = 99, false
			helpers.assert_eq(storage.publish_owned(owner, {}, { b = { present = true, value = true } }, backup, files), false)
			helpers.assert_eq(storage.publish_owned(owner, receipt, { foreign = { present = true, value = 1 } }, backup, files), false); helpers.assert_nil(read(backup))
			helpers.assert_true(storage.publish_owned(owner, receipt, { b = { present = true, value = 0 } }, backup, files))
			helpers.assert_eq(storage.get("a").list[1], 1); helpers.assert_eq(storage.get("b"), 0)
			helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_eq(read(path), '{"a":{"list":[1,2]},"b":false}')
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)

	helpers.it("script-storage-cohort actual backup order and retained inverse preserve foreign JSON kinds", function()
		storage_cohort_fixture('{"a":false,"future":null,"empty":[],"foreign":1}', function(storage, files, path, backup, write, read)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a", "new" })); local receipt = assert(storage.capture_owned(owner))
			write(path, '{"a":false,"future":null,"empty":[],"foreign":2}')
			local calls = {}
			local observed = { delete = files.delete, write_if_unchanged = function(name, bytes, expected)
				calls[#calls + 1] = name
				if name == path then
					local snapshot = assert(require("json").decode_lossless(read(backup)))
					helpers.assert_eq(snapshot.source.content, '{"a":false,"future":null,"empty":[],"foreign":2}')
					helpers.assert_eq(storage.set("foreign", 88), false, "actual same-file publication reentry refuses")
				end
				return files.write_if_unchanged(name, bytes, expected)
			end }
			helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = true }, new = { present = true, value = { 3, 4 } } }, backup, observed))
			helpers.assert_eq(calls, { backup, path }); helpers.assert_eq(storage.pending_owned(owner, receipt), false)
			helpers.assert_true(storage.set("foreign", 3)); helpers.assert_true(storage.release_owned(owner))
			helpers.assert_true(storage.acquire_owned(owner, { "new", "a" })); helpers.assert_true(storage.restore_owned(owner, receipt))
			local actual = assert(require("json").decode_lossless(read(path)))
			helpers.assert_eq(actual.a, false); helpers.assert_nil(actual.new); helpers.assert_eq(actual.foreign, 3)
			helpers.assert_true(require("json").is_null(actual.future)); helpers.assert_true(require("json").is_array(actual.empty))
			helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_true(storage.release_owned(owner))
		end)
	end)

	helpers.it("script-storage-cohort backup-time foreign source edit refuses before actual effect", function()
		storage_cohort_fixture('{"a":1,"foreign":2}', function(storage, files, path, backup, write, read)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" })); local receipt = assert(storage.capture_owned(owner))
			local racing = { delete = files.delete, write_if_unchanged = function(name, bytes, expected)
				local result = files.write_if_unchanged(name, bytes, expected)
				if name == backup then write(path, '{"a":1,"foreign":99}') end
				return result
			end }
			helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = 3 } }, backup, racing), false)
			helpers.assert_eq(read(path), '{"a":1,"foreign":99}'); helpers.assert_eq(storage.pending_owned(owner, receipt), false)
			helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_eq(read(path), '{"a":1,"foreign":99}'); helpers.assert_true(storage.release_owned(owner))
		end)
	end)

	helpers.it("script-storage-cohort source change and same-value cooperating successor refuse stale inverse", function()
		storage_cohort_fixture('{"a":1}', function(storage, files, path, backup, write, read)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" })); local receipt = assert(storage.capture_owned(owner))
			write(path, '{"a":2}'); helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = 3 } }, backup, files), false)
			helpers.assert_nil(read(backup)); helpers.assert_eq(read(path), '{"a":2}')
			write(path, '{"a":1}'); local current = assert(storage.capture_owned(owner))
			helpers.assert_true(storage.publish_owned(owner, current, { a = { present = true, value = 3 } }, backup, files))
			helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.set("a", 3)); helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			helpers.assert_eq(storage.restore_owned(owner, current), false); helpers.assert_eq(storage.get("a"), 3)
			helpers.assert_true(storage.pending_owned(owner, current)); helpers.assert_eq(storage.release_owned(owner), false)
		end)
	end)

	helpers.it("script-storage-cohort exact present bytes and real absence restore", function()
		for _, source in ipairs({ false, ' { "a" : 1, "foreign" : false }\n' }) do
			storage_cohort_fixture(source or nil, function(storage, files, path, backup, _, read)
				local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a", "new" })); local receipt = assert(storage.capture_owned(owner))
				helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = false }, new = { present = true, value = 0 } }, backup, files))
				helpers.assert_eq(storage.get("a"), false); helpers.assert_eq(storage.get("new"), 0)
				helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_eq(read(path), source or nil); helpers.assert_true(storage.release_owned(owner))
			end)
		end
	end)

	helpers.it("script-storage-cohort false native ACK retains actual compensation and blocks release", function()
		storage_cohort_fixture('{"a":1}', function(storage, files, path, backup, _, read)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" })); local receipt = assert(storage.capture_owned(owner)); local first = true
			local failed = { delete = files.delete, write_if_unchanged = function(name, bytes, expected)
				local result = files.write_if_unchanged(name, bytes, expected)
				if name == path and first then first = false; return false end
				return result
			end }
			helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = 2 } }, backup, failed), false)
			helpers.assert_eq(read(path), '{"a":2}'); helpers.assert_true(storage.pending_owned(owner, receipt)); helpers.assert_eq(storage.release_owned(owner), false)
			helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_eq(read(path), '{"a":1}')
			helpers.assert_eq(storage.pending_owned(owner, receipt), false); helpers.assert_true(storage.release_owned(owner))
		end)
	end)

	helpers.it("script-storage-cohort same-value live module and backup callback method replacements refuse", function()
		storage_cohort_fixture('{"a":1}', function(storage, files, path, backup, _, read)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" })); local receipt = assert(storage.capture_owned(owner))
			local successor = helpers.load_module("adapters.storage"); helpers.assert_eq(successor.get("a"), 1)
			helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = 2 } }, backup, files), false)
			helpers.assert_nil(read(backup)); helpers.assert_eq(read(path), '{"a":1}'); package.loaded["adapters.storage"] = storage
			local previous_set = storage.set
			local replacing = { delete = files.delete, write_if_unchanged = function(name, bytes, expected)
				local okay = files.write_if_unchanged(name, bytes, expected); if name == backup then storage.set = function() return true end end; return okay
			end }
			helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = 2 } }, backup, replacing), false)
			helpers.assert_eq(read(path), '{"a":1}'); storage.set = previous_set; helpers.assert_true(storage.release_owned(owner))
		end)
	end)

	helpers.it("script-storage-cohort strict capture refuses malformed and nonobject bytes without recovery", function()
		for _, source in ipairs({ '[1,2]', '{"a":', '{"a":1,"a":2}', '{"a":01}', 'null', 'true', '{"a":1} trailing' }) do
			storage_cohort_fixture(source, function(storage, _, path, _, _, read)
				local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" })); helpers.assert_eq(storage.capture_owned(owner), nil)
				helpers.assert_eq(read(path), source); helpers.assert_nil(read(path .. ".corrupt")); helpers.assert_nil(storage.recovery_status()); helpers.assert_true(storage.release_owned(owner))
			end)
		end
	end)

	helpers.it("script-storage-cohort native FIFO and symlink source kinds refuse without mutation", function()
		for _, kind in ipairs({ "fifo", "symlink" }) do
			storage_cohort_fixture(nil, function(storage, _, path, backup, write, read)
				local Shell = require("adapters.shell_runner")
				if kind == "fifo" then helpers.assert_true(Shell.run("mkfifo -- " .. Shell.quote(path)))
				else write(backup, '{"a":1}'); helpers.assert_true(Shell.run("ln -s -- " .. Shell.quote(backup) .. " " .. Shell.quote(path))) end
				local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" })); helpers.assert_eq(storage.capture_owned(owner), nil)
				helpers.assert_true(Shell.run("test " .. (kind == "fifo" and "-p " or "-L ") .. Shell.quote(path)))
				if kind == "symlink" then helpers.assert_eq(read(backup), '{"a":1}') end
				helpers.assert_nil(storage.recovery_status()); helpers.assert_true(storage.release_owned(owner))
			end)
		end
	end)
end)

helpers.describe("script storage receipt finalization", function()
	helpers.it("script-storage-cohort explicit forget finalizes without IO and breaks native owner cycles", function()
		local retained_storage, retained_receipt, weak
		storage_cohort_fixture('{"a":1}', function(storage, files, path, backup, _, read)
			retained_storage = storage
			local owner, receipt = {}, nil
			owner.pending = function() local retained = receipt; return retained == nil end
			helpers.assert_true(storage.acquire_owned(owner, { "a" })); receipt = assert(storage.capture_owned(owner))
			helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = 2 } }, backup, files))
			helpers.assert_eq(storage.forget_owned(owner, receipt), false, "held alias gates forbid journal finalization"); helpers.assert_true(storage.release_owned(owner)); local source, snapshot = read(path), read(backup)
			local pending = owner.pending; owner.pending = function() return true end
			helpers.assert_eq(storage.forget_owned(owner, receipt), false)
			owner.pending = pending; helpers.assert_true(storage.forget_owned(owner, receipt)); helpers.assert_true(storage.forget_owned(owner, receipt))
			helpers.assert_eq(storage.forget_owned({}, receipt), false); helpers.assert_eq(read(path), source); helpers.assert_eq(read(backup), snapshot)
			helpers.assert_true(storage.acquire_owned(owner, { "a" })); helpers.assert_eq(storage.restore_owned(owner, receipt), false); helpers.assert_true(storage.release_owned(owner))
			weak = setmetatable({ owner, receipt }, { __mode = "v" })
			retained_receipt = receipt
			owner, receipt, pending = nil, nil, nil
		end)
		collectgarbage("collect")
		helpers.assert_nil(weak[1], "a finalized journal must not retain its native owner while its receipt stays reachable")
		helpers.assert_eq(weak[2], retained_receipt, "the first collection still observes the actual rooted receipt")
		retained_receipt = nil
		collectgarbage("collect")
		helpers.assert_nil(weak[1]); helpers.assert_nil(weak[2])
		helpers.assert_eq(type(retained_storage.forget_owned), "function", "the native producer remains reachable during the collection proof")
	end)
	helpers.it("script-storage-cohort foreign ordinary writes remain admitted during a distinct backup publication", function()
		storage_cohort_fixture('{"a":1,"foreign":2}', function(storage, files, path, backup, _, read)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" })); local receipt = assert(storage.capture_owned(owner))
			local racing = { delete = files.delete, write_if_unchanged = function(name, bytes, expected)
				local result = files.write_if_unchanged(name, bytes, expected)
				if name == backup then helpers.assert_true(storage.set("foreign", 99)) end
				return result
			end }
			helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = 3 } }, backup, racing), false)
			helpers.assert_eq(require("json").decode_lossless(read(path)), { a = 1, foreign = 99 })
			helpers.assert_eq(storage.pending_owned(owner, receipt), false); helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_true(storage.release_owned(owner))
		end)
	end)
end)

helpers.describe("script storage fake contract", function()
	helpers.it("script-storage-cohort in-memory fake rejects owned writes and preserves foreign cells on retained inverse", function()
		storage_cohort_fixture(nil, function(_, files, _, backup)
			local storage = require("tests.fakes").storage({ initial = { a = false, foreign = 1 } })
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a", "missing" }))
			local receipt, cells = storage.capture_owned(owner); helpers.assert_eq(cells.a.value, false); cells.a.present = false
			helpers.assert_eq(storage.set("a", true), false); helpers.assert_eq(storage.set_many({ a = true, foreign = 4 }), false)
			helpers.assert_eq(storage.delete("missing"), false); helpers.assert_eq(storage.clear(), false)
			helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = true }, missing = { present = true, value = 0 } }, backup, files))
			helpers.assert_true(storage.set("foreign", 9)); helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.acquire_owned(owner, { "missing", "a" }))
			helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_eq(storage.get("a"), false); helpers.assert_eq(storage.get("foreign"), 9); helpers.assert_nil(storage.get("missing"))
			helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.forget_owned(owner, receipt)); helpers.assert_true(storage.forget_owned(owner, receipt))
		end)
	end)
end)

helpers.describe("script storage opaque owner identity", function()
	helpers.it("script-storage-cohort table equality metamethod cannot forge receipt owner or update alias ownership", function()
		storage_cohort_fixture('{"a":1,"foreign":2}', function(storage, files, _, backup)
			local mt = { __eq = function() return true end }
			local owner, foreign = setmetatable({}, mt), setmetatable({}, mt)
			helpers.assert_true(storage.acquire_owned(owner, { "a" })); helpers.assert_true(storage.acquire_owned(foreign, { "foreign" }))
			local receipt = assert(storage.capture_owned(owner))
			helpers.assert_eq(storage.publish_owned(owner, receipt, { foreign = { present = true, value = 99 } }, backup, files), false)
			helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = 3 } }, backup, files)); helpers.assert_true(storage.release_owned(owner))
			helpers.assert_eq(storage.forget_owned(foreign, receipt), false); helpers.assert_true(storage.release_owned(foreign)); helpers.assert_true(storage.acquire_owned(foreign, { "a" }))
			helpers.assert_eq(storage.restore_owned(foreign, receipt), false); helpers.assert_true(storage.release_owned(foreign))
			helpers.assert_true(storage.acquire_owned(owner, { "a" })); helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.forget_owned(owner, receipt))
			helpers.assert_eq(storage.forget_owned(foreign, receipt), false)
		end)
	end)
end)

helpers.describe("script storage numeric source admission", function()
	helpers.it("script-storage-cohort unsafe future decimal tokens survive source-bound owned effects", function()
		local cases = {
			'{"a":false,"future":9007199254740993}',
			'{"a":false,"future":0.1}',
			'{"a":false,"future":1e-400}',
			'{"a":false,"future":[0.12345678901234567890123456789]}',
			'{"a":false,"future":{"nested":9007199254740993}}',
		}
		for _, source in ipairs(cases) do
			storage_cohort_fixture(source, function(storage, files, path, backup, _, read)
				local owner = { pending = function() return false end }
				helpers.assert_true(storage.acquire_owned(owner, { "a" }))
				local receipt, cells = storage.capture_owned(owner)
				helpers.assert_true(type(receipt) == "table"); helpers.assert_eq(cells.a.value, false)
				helpers.assert_eq(storage.set("a", true), false)
				helpers.assert_eq(read(path), source); helpers.assert_nil(read(backup))
				helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files))
				local expected = source:gsub('"a":false', '"a":true', 1)
				helpers.assert_eq(read(path), expected)
				helpers.assert_eq(require("json").decode_lossless(read(backup)).source.content, source)
				helpers.assert_true(storage.set("foreign", true))
				helpers.assert_eq(read(path), expected:sub(1, -2) .. ',"foreign":true}')
				helpers.assert_true(storage.restore_owned(owner, receipt))
				helpers.assert_eq(read(path), source:sub(1, -2) .. ',"foreign":true}')
				helpers.assert_nil(read(path .. ".tmp")); helpers.assert_nil(read(path .. ".corrupt"))
				helpers.assert_nil(storage.recovery_status()); helpers.assert_true(storage.release_owned(owner))
				helpers.assert_true(storage.forget_owned(owner, receipt))
				helpers.assert_eq(helpers.load_module("adapters.storage").get("a"), false)
			end)
		end
	end)

	helpers.it("script-storage-cohort representable tokens and escaped numeric strings preserve native source", function()
		local source = [[{"a":false,"fraction":0.125,"padded":16.50e+1,"exponent":1e3,"zero":0e9999,"future":null,"empty":[],"9007199254740993":"1e-400 0.1","escaped":"\\\"9007199254740993"}]]
		storage_cohort_fixture(source, function(storage, files, path, backup, _, read)
			local json = require("json"); local owner = {}
			helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			local receipt, cells = storage.capture_owned(owner); helpers.assert_true(type(receipt) == "table"); helpers.assert_eq(cells.a.value, false)
			helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files))
			local current = json.decode_lossless(read(path)); local saved = json.decode_lossless(read(backup))
			helpers.assert_eq(current.a, true); helpers.assert_eq(current.fraction, 0.125)
			helpers.assert_eq(current.padded, 165); helpers.assert_eq(current.exponent, 1000); helpers.assert_eq(current.zero, 0)
			helpers.assert_true(json.is_null(current.future)); helpers.assert_true(json.is_array(current.empty))
			helpers.assert_eq(current["9007199254740993"], "1e-400 0.1"); helpers.assert_eq(current.escaped, '\\"9007199254740993')
			helpers.assert_eq(saved.source.content, source); helpers.assert_eq(saved.cells.a.value, false)
			helpers.assert_eq(storage.pending_owned(owner, receipt), false)
			helpers.assert_true(storage.set("foreign", 0.5)); helpers.assert_true(storage.restore_owned(owner, receipt))
			current = json.decode_lossless(read(path)); helpers.assert_eq(current.a, false); helpers.assert_eq(current.foreign, 0.5)
			helpers.assert_eq(current.fraction, 0.125); helpers.assert_eq(current["9007199254740993"], "1e-400 0.1")
			helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.forget_owned(owner, receipt))
		end)
	end)

	helpers.it("script-storage-cohort numeric backup refusal leaves the native owner unspent", function()
		storage_cohort_fixture('{"a":false}', function(storage, files, path, backup, _, read)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" })); local receipt = assert(storage.capture_owned(owner))
			local integer = 9007199254740993
			-- Only Lua5.4 supplies this exact integer to the actual native adapter;
			-- LuaJIT has rounded it before the call and cannot prove this premise.
			if type(integer) == "number" and integer % 1 == 0 and integer - 9007199254740992 == 1 then
				helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = integer } }, backup, files), false)
				helpers.assert_eq(read(path), '{"a":false}'); helpers.assert_nil(read(backup)); helpers.assert_eq(storage.pending_owned(owner, receipt), false)
			end
			helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = 0.125 } }, backup, files))
			helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_eq(read(path), '{"a":false}')
			helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.forget_owned(owner, receipt))
		end)
	end)
end)

helpers.describe("script storage raw producer identity", function()
	helpers.it("script-storage-cohort forged module equality cannot authorize actual native publication", function()
		for _, stage in ipairs({ "capture", "publish", "backup", "readback" }) do
			storage_cohort_fixture('{"a":false,"future":[]}', function(storage, files, path, backup, _, read)
				local comparisons = 0
				local mt = { __index = function(_, key) return rawget(storage, key) end, __eq = function() comparisons = comparisons + 1; return true end }
				setmetatable(storage, mt)
				local successor = setmetatable({}, mt)
				helpers.assert_true(not rawequal(successor, storage))
				local owner = { pending = function() return false end }; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
				if stage == "capture" then
					package.loaded["adapters.storage"] = successor
					helpers.assert_nil(storage.capture_owned(owner)); helpers.assert_nil(read(backup))
				else
					local receipt = assert(storage.capture_owned(owner)); local producer, replaced = files, false
					if stage == "publish" then package.loaded["adapters.storage"] = successor
					else producer = { delete = files.delete, write_if_unchanged = function(name, bytes, expected)
						local result = files.write_if_unchanged(name, bytes, expected)
						if not replaced and name == (stage == "backup" and backup or path) then replaced = true; package.loaded["adapters.storage"] = successor end
						return result
					end } end
					helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, producer), false)
					if stage == "readback" then
						helpers.assert_eq(require("json").decode_lossless(read(path)).a, true, "actual effect requires retained compensation")
						helpers.assert_true(storage.pending_owned(owner, receipt)); helpers.assert_eq(storage.release_owned(owner), false)
					else helpers.assert_eq(read(path), '{"a":false,"future":[]}'); helpers.assert_eq(storage.pending_owned(owner, receipt), false) end
					if stage == "publish" then helpers.assert_nil(read(backup)) end
					helpers.assert_eq(storage.restore_owned(owner, receipt), false)
					package.loaded["adapters.storage"] = storage
					helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_eq(read(path), '{"a":false,"future":[]}')
				end
				helpers.assert_eq(comparisons, 0, "authority must never invoke producer equality metamethods")
				package.loaded["adapters.storage"] = storage; setmetatable(storage, nil)
				helpers.assert_eq(read(path), '{"a":false,"future":[]}'); helpers.assert_true(storage.release_owned(owner))
			end)
		end
	end)
end)

helpers.describe("native storage exact root-member source publication", function()
	local source = ' \n{ "a" : false, "future" : [0.1,{"i":9223372036854775807,"empty":[],"map":{},"n":null,"e":1.230000e-20}], "\\u0066oreign" : 1 }\t'
	helpers.it("preserves full handwritten bytes through owned effect, held writes and inverse", function()
		storage_cohort_fixture(source, function(storage, files, path, backup, _, read)
			local owner = { pending = function() return false end }
			helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			local receipt = assert(storage.capture_owned(owner))
			helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files))
			helpers.assert_eq(read(path), ' \n{ "a" : true, "future" : [0.1,{"i":9223372036854775807,"empty":[],"map":{},"n":null,"e":1.230000e-20}], "\\u0066oreign" : 1 }\t')
			helpers.assert_true(storage.set("foreign", 2))
			helpers.assert_eq(read(path), ' \n{ "a" : true, "future" : [0.1,{"i":9223372036854775807,"empty":[],"map":{},"n":null,"e":1.230000e-20}], "\\u0066oreign" : 2 }\t')
			helpers.assert_true(storage.set_many({ appended = false, other = "x" }))
			helpers.assert_eq(read(path), ' \n{ "a" : true, "future" : [0.1,{"i":9223372036854775807,"empty":[],"map":{},"n":null,"e":1.230000e-20}], "\\u0066oreign" : 2 ,"appended":false,"other":"x"}\t')
			helpers.assert_true(storage.delete("other")); helpers.assert_true(storage.delete("missing"))
			helpers.assert_true(storage.restore_owned(owner, receipt))
			helpers.assert_eq(read(path), ' \n{ "a" : false, "future" : [0.1,{"i":9223372036854775807,"empty":[],"map":{},"n":null,"e":1.230000e-20}], "\\u0066oreign" : 2 ,"appended":false}\t')
			helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.forget_owned(owner, receipt))
		end)
	end)
	for _, token in ipairs({ "0.1", "9007199254740993", "1e-400", "-0" }) do
		helpers.it("refuses an unsafe captured numeric cell " .. token .. " before native effects", function()
			local input = '{"a":' .. token .. ',"future":0.1}'
			storage_cohort_fixture(input, function(storage, _, path, backup, _, read)
				local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
				local receipt = storage.capture_owned(owner)
				local decoded = require("json").decode_lossless(token)
				if token == "-0" and 1 / decoded == -math.huge then
					helpers.assert_true(type(receipt) == "table", "runtime retains exact negative-zero inverse")
				else helpers.assert_nil(receipt) end
				helpers.assert_eq(read(path), input)
				helpers.assert_nil(read(backup)); helpers.assert_nil(read(path .. ".tmp"))
				helpers.assert_true(storage.release_owned(owner))
			end)
		end)
	end
	helpers.it("rejects actual codec instance or method replacement without equality callbacks", function()
		for _, mode in ipairs({ "instance", "method" }) do
			storage_cohort_fixture('{"a":false,"future":0.1}', function(storage, files, path, backup, _, read)
				local json = require("json"); local owner = {}
				helpers.assert_true(storage.acquire_owned(owner, { "a" }))
				local receipt = assert(storage.capture_owned(owner))
				local original = json.splice_root_object_source
				if mode == "instance" then package.loaded["json"] = setmetatable({}, { __eq = function() error("forged equality") end })
				else json.splice_root_object_source = function() return '{}', {}, {} end end
				local result = storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files)
				package.loaded["json"], json.splice_root_object_source = json, original
				helpers.assert_eq(result, false); helpers.assert_eq(read(path), '{"a":false,"future":0.1}')
				helpers.assert_nil(read(backup)); helpers.assert_eq(storage.pending_owned(owner, receipt), false)
				helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files))
				helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_true(storage.release_owned(owner))
			end)
		end
	end)
end)

helpers.describe("storage source-read foreign publication fences", function()
	helpers.it("retains alias ownership and refuses source-read writer reentry", function()
		storage_cohort_fixture('{"a":false,"future":0.1}', function(storage, _, path, _, _, read)
			local owner, competing = {}, {}
			helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			local reader = require("infra.regular_file_reader")
			local open, observed, entered = reader.open, {}, false
			reader.open = function(name, ...)
				if name == path and not entered then
					entered = true
					observed.set = storage.set("reentered", true)
					observed.claim = storage.acquire_owned(competing, { "foreign" })
				end
				return open(name, ...)
			end
			local okay, committed = pcall(storage.set, "foreign", true)
			reader.open = open
			helpers.assert_true(okay); helpers.assert_true(committed)
			helpers.assert_eq(observed.set, false); helpers.assert_eq(observed.claim, false)
			helpers.assert_eq(read(path), '{"a":false,"future":0.1,"foreign":true}')
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)
	helpers.it("refuses a codec successor inserted by actual classified source read", function()
		storage_cohort_fixture('{"a":false,"future":0.1}', function(storage, _, path, _, _, read)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			local json, reader = require("json"), require("infra.regular_file_reader")
			local open = reader.open
			reader.open = function(name, ...)
				local handle, detail, errno = open(name, ...)
				if name == path then package.loaded["json"] = {} end
				return handle, detail, errno
			end
			local okay, committed = pcall(storage.set, "foreign", true)
			reader.open, package.loaded["json"] = open, json
			helpers.assert_true(okay); helpers.assert_eq(committed, false)
			helpers.assert_eq(read(path), '{"a":false,"future":0.1}')
			helpers.assert_true(storage.set("foreign", true))
			helpers.assert_eq(read(path), '{"a":false,"future":0.1,"foreign":true}')
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)
end)

helpers.describe("storage native backup transitive codec authority", function()
	helpers.it("rejects source-read quote replacement before backup and permits the repaired same owner", function()
		local source = '{"a":false,"future":0.1}'
		storage_cohort_fixture(source, function(storage, files, path, backup, _, read)
			local json, reader = require("json"), require("infra.regular_file_reader")
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			local receipt = assert(storage.capture_owned(owner))
			local open, quote, replaced = reader.open, json.quote, false
			reader.open = function(name, ...)
				local handle, detail, errno = open(name, ...)
				if name == path and not replaced then
					replaced = true
					json.quote = function(value)
						return quote(value == source and "tampered" or value)
					end
				end
				return handle, detail, errno
			end
			local okay, result = pcall(storage.publish_owned, owner, receipt, { a = { present = true, value = true } }, backup, files)
			reader.open, json.quote = open, quote
			helpers.assert_true(okay); helpers.assert_true(replaced); helpers.assert_eq(result, false)
			helpers.assert_eq(read(path), source); helpers.assert_nil(read(backup))
			helpers.assert_eq(storage.pending_owned(owner, receipt), false)
			helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files))
			helpers.assert_eq(require("json").decode_lossless(read(backup)).source.content, source)
			helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_eq(read(path), source)
			helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.forget_owned(owner, receipt))
		end)
	end)
end)

-- These controls retain actual native Reader/Writer/FileSystem publication. The
-- wrapper changes only its terminal receipt after an independently observed file
-- effect; assertions run outside protected native callbacks.
local function ordinary_debt_fixture(mode, callback)
	storage_cohort_fixture('{"a":false,"future":0.1,"huge":9007199254740993}', function(storage, files, path, backup, write, read)
		local native = files.write_if_unchanged
		local state = { writes = 0, cleanups = 0, mode = mode, effect = true, native_effect = true }
		files.write_if_unchanged = function(name, content, expected)
			if name ~= path then return native(name, content, expected) end
			state.writes = state.writes + 1
			if state.native_effect then
				local result, detail = native(name, content, expected)
				if result ~= true then return result, detail end
			end
			if state.mode == "normal" then return true end
			if state.mode == "no_receipt" then return false, "unacknowledged native effect" end
			return false, "retained native cleanup", function()
				state.cleanups = state.cleanups + 1
				if state.observe then state.observe() end
				if state.mode == "raise" then error("native cleanup raised") end
				if state.mode == "refuse" then return false, "cleanup refused" end
				return true, nil, state.effect
			end
		end
		local okay, detail = xpcall(function() callback(storage, files, path, backup, write, read, state) end, debug.traceback)
		files.write_if_unchanged = native
		if not okay then error(detail, 0) end
	end)
end

helpers.describe("storage ordinary native cleanup journal", function()
	for _, failure in ipairs({ "refuse", "raise" }) do
		helpers.it("ordinary-native-debt: retains " .. failure .. " cleanup and retries only its terminal", function()
			ordinary_debt_fixture(failure, function(storage, files, path, backup, _, read, state)
				local owner, competitor = {}, {}
				helpers.assert_true(storage.acquire_owned(owner, { "a" }))
				local receipt = assert(storage.capture_owned(owner))
				helpers.assert_eq(storage.set("foreign", false), false)
				helpers.assert_eq(read(path), '{"a":false,"future":0.1,"huge":9007199254740993,"foreign":false}')
				helpers.assert_eq(storage.get("foreign", "old"), "old")
				helpers.assert_eq(state.writes, 1); helpers.assert_eq(state.cleanups, 1)
				helpers.assert_nil(storage.capture_owned(owner))
				helpers.assert_eq(storage.acquire_owned(competitor, { "other" }), false)
				helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files), false)
				helpers.assert_eq(storage.restore_owned(owner, receipt), false)
				helpers.assert_eq(storage.delete("foreign"), false)
				helpers.assert_eq(state.writes, 1); helpers.assert_nil(read(backup))
				state.mode = "settle"
				helpers.assert_true(storage.set("foreign", false))
				helpers.assert_eq(storage.get("foreign"), false)
				helpers.assert_eq(state.writes, 1)
				helpers.assert_true(storage.release_owned(owner))
			end)
		end)
	end
	helpers.it("ordinary-native-debt: settles an unrelated request without acknowledging or replaying it", function()
		ordinary_debt_fixture("refuse", function(storage, _, path, _, _, read, state)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			helpers.assert_eq(storage.set_many({ foreign = true, second = false }), false)
			state.mode = "settle"
			helpers.assert_eq(storage.set("third", true), false)
			helpers.assert_eq(state.writes, 1); helpers.assert_eq(storage.get("second"), false)
			helpers.assert_eq(read(path), '{"a":false,"future":0.1,"huge":9007199254740993,"foreign":true,"second":false}')
			state.mode = "normal"
			helpers.assert_true(storage.set("third", true)); helpers.assert_eq(state.writes, 2)
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)
	helpers.it("ordinary-native-debt: preserves a foreign successor and retires only the old settled intent", function()
		ordinary_debt_fixture("refuse", function(storage, _, path, _, write, read, state)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			helpers.assert_eq(storage.set("foreign", true), false)
			local successor = '{"a":false,"future":0.1,"huge":9007199254740993,"foreign":"external","neighbor":[]}'
			write(path, successor); state.mode = "settle"
			helpers.assert_eq(storage.set("foreign", true), false)
			helpers.assert_eq(read(path), successor); helpers.assert_eq(state.writes, 1)
			helpers.assert_eq(storage.get("foreign"), "external")
			state.mode = "normal"
			helpers.assert_true(storage.set("fresh", true)); helpers.assert_eq(state.writes, 2)
			helpers.assert_eq(read(path), '{"a":false,"future":0.1,"huge":9007199254740993,"foreign":"external","neighbor":[],"fresh":true}')
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)
	for _, invalid in ipairs({ "missing", "string" }) do
		helpers.it("ordinary-native-debt: retains cleanup after " .. invalid .. " effect receipt and requires actual repair", function()
			ordinary_debt_fixture("settle", function(storage, _, path, _, _, read, state)
				local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
				if invalid == "missing" then state.effect = nil else state.effect = "true" end
				helpers.assert_eq(storage.set("foreign", true), false)
				helpers.assert_eq(storage.set("foreign", true), false)
				helpers.assert_eq(state.writes, 1)
				state.effect = true
				helpers.assert_true(storage.set("foreign", true))
				helpers.assert_eq(state.writes, 1)
				helpers.assert_eq(read(path), '{"a":false,"future":0.1,"huge":9007199254740993,"foreign":true}')
				helpers.assert_true(storage.release_owned(owner))
			end)
		end)
	end
	helpers.it("ordinary-native-debt: refuses candidate acknowledgement when the native effect flag is false", function()
		ordinary_debt_fixture("settle", function(storage, _, path, _, write, read, state)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			state.effect = false
			helpers.assert_eq(storage.set("foreign", true), false)
			helpers.assert_eq(storage.set("foreign", true), false)
			helpers.assert_eq(state.writes, 1)
			-- A fresh external source can retire the old proven nonpublication;
			-- it cannot retroactively turn a false native effect into success.
			write(path, '{"a":false,"future":0.1,"huge":9007199254740993,"foreign":"other"}')
			helpers.assert_eq(storage.set("foreign", true), false)
			helpers.assert_eq(storage.get("foreign"), "other"); helpers.assert_eq(state.writes, 1)
			state.mode = "normal"
			helpers.assert_true(storage.delete("foreign"))
			helpers.assert_eq(read(path), '{"a":false,"future":0.1,"huge":9007199254740993}')
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)
	helpers.it("ordinary-native-debt: starts a fresh explicit retry only after proven no-effect settlement", function()
		ordinary_debt_fixture("refuse", function(storage, _, _, _, _, _, state)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			state.native_effect = false; state.effect = false
			helpers.assert_eq(storage.set("foreign", true), false); helpers.assert_eq(state.writes, 1)
			state.mode = "normal"; state.native_effect = true
			helpers.assert_true(storage.set("foreign", true)); helpers.assert_eq(state.writes, 2)
			helpers.assert_eq(storage.get("foreign"), true)
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)
	helpers.it("ordinary-native-debt: does not infer publication from unacknowledged partial native effects", function()
		ordinary_debt_fixture("no_receipt", function(storage, _, path, _, write, read, state)
			local source = read(path); local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			helpers.assert_eq(storage.set("foreign", true), false)
			helpers.assert_eq(storage.set("foreign", true), false); helpers.assert_eq(state.writes, 1)
			helpers.assert_nil(storage.capture_owned(owner))
			-- Unknown native acknowledgement retains the attempt. Restoring its
			-- exact prior source is an explicit repair, not an automatic inverse.
			write(path, source); state.mode = "normal"
			helpers.assert_true(storage.set("foreign", true)); helpers.assert_eq(state.writes, 2)
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)
	helpers.it("ordinary-native-debt: keeps native terminal identity across actual method successors", function()
		ordinary_debt_fixture("refuse", function(storage, files, _, _, _, _, state)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			helpers.assert_eq(storage.set("foreign", true), false)
			local method, count = files.write_if_unchanged, state.cleanups
			files.write_if_unchanged = function() error("successor must not publish") end
			state.mode = "settle"
			local result = storage.set("foreign", true)
			files.write_if_unchanged = method
			helpers.assert_eq(result, false); helpers.assert_eq(state.cleanups, count)
			helpers.assert_true(storage.set("foreign", true)); helpers.assert_eq(state.writes, 1)
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)
	helpers.it("ordinary-native-debt: refuses source-read and native-cleanup owned reentry without effects", function()
		ordinary_debt_fixture("refuse", function(storage, files, path, backup, _, _, state)
			local owner, competitor = {}, {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			local receipt = assert(storage.capture_owned(owner)); local observed = {}
			local function observe()
				observed.capture = storage.capture_owned(owner)
				observed.publish = storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files)
				observed.restore = storage.restore_owned(owner, receipt)
				observed.acquire = storage.acquire_owned(competitor, { "neighbor" })
				observed.set = storage.set("neighbor", true)
			end
			local reader = require("infra.regular_file_reader"); local open, entered = reader.open, false
			reader.open = function(name, ...)
				if name == path and not entered then entered = true; observe() end
				return open(name, ...)
			end
			local okay, result = pcall(storage.set, "foreign", true)
			reader.open = open
			helpers.assert_true(okay); helpers.assert_eq(result, false); helpers.assert_true(entered)
			helpers.assert_nil(observed.capture)
			for _, key in ipairs({ "publish", "restore", "acquire", "set" }) do helpers.assert_eq(observed[key], false) end
			observed = {}; state.observe = observe; state.mode = "settle"
			helpers.assert_true(storage.set("foreign", true))
			helpers.assert_nil(observed.capture)
			for _, key in ipairs({ "publish", "restore", "acquire", "set" }) do helpers.assert_eq(observed[key], false) end
			helpers.assert_eq(state.writes, 1); helpers.assert_true(storage.release_owned(owner))
		end)
	end)
	helpers.it("ordinary-native-debt: blocks released ordinary effects until prior held cleanup settles", function()
		ordinary_debt_fixture("refuse", function(storage, _, path, _, _, read, state)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			helpers.assert_eq(storage.set("foreign", true), false); helpers.assert_true(storage.release_owned(owner))
			helpers.assert_eq(storage.clear(), false); helpers.assert_eq(state.writes, 1)
			state.mode = "settle"
			helpers.assert_eq(storage.clear(), false); helpers.assert_eq(state.writes, 1)
			helpers.assert_eq(read(path), '{"a":false,"future":0.1,"huge":9007199254740993,"foreign":true}')
			helpers.assert_eq(storage.get("foreign"), true)
		end)
	end)
end)

helpers.describe("storage final ordinary publication admission", function()
	helpers.it("ordinary-native-debt: refuses a codec replacement during Writer final source read", function()
		storage_cohort_fixture('{"a":false,"future":0.1}', function(storage, _, path, _, _, read)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			local json, reader = require("json"), require("infra.regular_file_reader")
			local open, samples = reader.open, 0
			reader.open = function(name, ...)
				local handle, detail, errno = open(name, ...)
				if name == path then samples = samples + 1; if samples == 2 then package.loaded["json"] = {} end end
				return handle, detail, errno
			end
			local okay, committed = pcall(storage.set, "foreign", true)
			reader.open, package.loaded["json"] = open, json
			helpers.assert_true(okay); helpers.assert_eq(committed, false); helpers.assert_eq(samples, 2)
			helpers.assert_eq(read(path), '{"a":false,"future":0.1}')
			helpers.assert_true(storage.set("foreign", true))
			helpers.assert_eq(read(path), '{"a":false,"future":0.1,"foreign":true}')
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)
end)

helpers.describe("storage released ordinary source publication", function()
	helpers.it("released-source: preserves full foreign precision and kinds across ordinary mutations and restart", function()
		local source = ' \n{ "future" : [0.1,{"i":9223372036854775807,"long":1.234567890123456789,"empty":[],"map":{},"n":null,"e":1.2300e-20}], "\\u0061" : false }\t'
		storage_cohort_fixture(source, function(storage, _, path, _, _, read)
			helpers.assert_true(storage.set("a", true))
			helpers.assert_eq(read(path), ' \n{ "future" : [0.1,{"i":9223372036854775807,"long":1.234567890123456789,"empty":[],"map":{},"n":null,"e":1.2300e-20}], "\\u0061" : true }\t')
			helpers.assert_true(storage.set_many({ new = false, other = "x" }))
			helpers.assert_true(storage.delete("other"))
			local expected = ' \n{ "future" : [0.1,{"i":9223372036854775807,"long":1.234567890123456789,"empty":[],"map":{},"n":null,"e":1.2300e-20}], "\\u0061" : true ,"new":false}\t'
			helpers.assert_eq(read(path), expected)
			local restarted = helpers.load_module("adapters.storage")
			helpers.assert_eq(restarted.get("a"), true); helpers.assert_eq(restarted.get("new"), false)
			helpers.assert_true(restarted.set("a", false))
			helpers.assert_eq(read(path), ' \n{ "future" : [0.1,{"i":9223372036854775807,"long":1.234567890123456789,"empty":[],"map":{},"n":null,"e":1.2300e-20}], "\\u0061" : false ,"new":false}\t')
		end)
	end)
	for _, vector in ipairs({
		{ key = "a", expected = ' \n{\t"b":0.1,\n"c":9007199254740993 }\t' },
		{ key = "b", expected = ' \n{  "a" :1 ,\n"c":9007199254740993 }\t' },
		{ key = "c", expected = ' \n{  "a" :1 ,\t"b":0.1}\t' },
	}) do
		helpers.it("released-source: deletes " .. vector.key .. " while retaining complete adjacent bytes", function()
			storage_cohort_fixture(' \n{  "a" :1 ,\t"b":0.1,\n"c":9007199254740993 }\t', function(storage, _, path, _, _, read)
				helpers.assert_true(storage.delete(vector.key)); helpers.assert_eq(read(path), vector.expected)
			end)
		end)
	end
	helpers.it("released-source: keeps decoded case and escaped literal key identities", function()
		storage_cohort_fixture('{"Key":1,"key":2,"\\u0061":false,"literal.dot":[],"future":0.1}', function(storage, _, path, _, _, read)
			helpers.assert_true(storage.set_many({ Key = false, a = true }))
			helpers.assert_eq(read(path), '{"Key":false,"key":2,"\\u0061":true,"literal.dot":[],"future":0.1}')
			helpers.assert_true(storage.delete("literal.dot"))
			helpers.assert_eq(read(path), '{"Key":false,"key":2,"\\u0061":true,"future":0.1}')
		end)
	end)
	helpers.it("released-source: samples a fresh external source rather than stale loaded cache", function()
		storage_cohort_fixture('{"a":false,"future":0.1}', function(storage, _, path, _, write, read)
			helpers.assert_eq(storage.get("a"), false)
			write(path, '{"a":false,"future":0.1,"external":9007199254740993,"empty":[]}')
			helpers.assert_true(storage.set("a", true))
			helpers.assert_eq(read(path), '{"a":true,"future":0.1,"external":9007199254740993,"empty":[]}')
			write(path, '{"a":true,"future":0.1,"external":9007199254740993,"empty":[],"new":false}')
			helpers.assert_true(storage.delete("new"))
			helpers.assert_eq(read(path), '{"a":true,"future":0.1,"external":9007199254740993,"empty":[]}')
		end)
	end)
	helpers.it("released-source: clear owns all actual root members and keeps outside trivia", function()
		storage_cohort_fixture(' \n{ "future":0.1, "empty":[], "map":{}, "null":null }\t', function(storage, _, path, _, _, read)
			helpers.assert_true(storage.clear()); helpers.assert_eq(read(path), ' \n{}\t')
			helpers.assert_true(storage.clear()); helpers.assert_eq(read(path), ' \n{}\t')
		end)
	end)
	helpers.it("released-source: actual final source change refuses publication and safely admits a later explicit request", function()
		storage_cohort_fixture('{"a":false,"future":0.1}', function(storage, _, path, _, write, read)
			storage.get("a")
			local reader = require("infra.regular_file_reader"); local open, samples = reader.open, 0
			local successor = '{"a":false,"future":0.1,"external":9007199254740993}'
			reader.open = function(name, ...)
				if name == path then samples = samples + 1; if samples == 2 then write(path, successor) end end
				return open(name, ...)
			end
			local okay, result = pcall(storage.set, "a", true)
			reader.open = open
			helpers.assert_true(okay); helpers.assert_eq(result, false); helpers.assert_true(samples >= 2)
			helpers.assert_eq(read(path), successor); helpers.assert_nil(read(path .. ".tmp"))
			-- Native admission proved no call to rename; its Boolean false receipt
			-- retires the old intent but cannot acknowledge its value.
			helpers.assert_true(storage.set("a", true))
			helpers.assert_eq(read(path), '{"a":true,"future":0.1,"external":9007199254740993}')
		end)
	end)
	helpers.it("released-source: refuses codec changes during final read and permits exact capability repair", function()
		storage_cohort_fixture('{"a":false,"future":0.1}', function(storage, _, path, _, _, read)
			storage.get("a")
			local json, reader = require("json"), require("infra.regular_file_reader")
			local open, samples = reader.open, 0
			reader.open = function(name, ...)
				local handle, detail, errno = open(name, ...)
				if name == path then samples = samples + 1; if samples == 2 then package.loaded["json"] = {} end end
				return handle, detail, errno
			end
			local okay, result = pcall(storage.set, "a", true)
			reader.open, package.loaded["json"] = open, json
			helpers.assert_true(okay); helpers.assert_eq(result, false)
			helpers.assert_eq(read(path), '{"a":false,"future":0.1}')
			helpers.assert_nil(read(path .. ".tmp")); helpers.assert_true(storage.set("a", true))
		end)
	end)
	helpers.it("released-source: retains an exclusive temporary inode claimed by another writer", function()
		storage_cohort_fixture('{"a":false,"future":0.1}', function(storage, _, path, _, write, read)
			write(path .. ".tmp", "foreign staging bytes")
			helpers.assert_eq(storage.set("a", true), false)
			helpers.assert_eq(read(path), '{"a":false,"future":0.1}')
			helpers.assert_eq(read(path .. ".tmp"), "foreign staging bytes")
		end)
	end)
	helpers.it("released-source: rejects decoded duplicate-key sources before ordinary effects", function()
		for _, source in ipairs({ '{"a":false,"\\u0061":true}', '{"a":{"x":1,"x":2},"future":0.1}' }) do
			storage_cohort_fixture(source, function(storage, _, path, _, _, read)
				helpers.assert_eq(storage.set("new", true), false); helpers.assert_eq(read(path), source)
				helpers.assert_nil(read(path .. ".tmp"))
			end)
		end
	end)
	helpers.it("released-source: native rename reentry cannot acquire or mutate another alias", function()
		storage_cohort_fixture('{"a":false,"future":0.1}', function(storage, _, path, _, _, read)
			local rename, observed = os.rename, {}
			os.rename = function(from, to)
				if to == path then
					observed.claim = storage.acquire_owned({}, { "neighbor" })
					observed.set = storage.set("neighbor", true)
				end
				return rename(from, to)
			end
			local okay, result = pcall(storage.set, "a", true)
			os.rename = rename
			helpers.assert_true(okay); helpers.assert_true(result)
			helpers.assert_eq(observed.claim, false); helpers.assert_eq(observed.set, false)
			helpers.assert_eq(read(path), '{"a":true,"future":0.1}')
		end)
	end)
end)

helpers.describe("storage released ordinary native receipt recovery", function()
	helpers.it("released-source: unknown partial rename acknowledgement cannot be replayed or inferred", function()
		local source = '{"a":false,"future":0.1}'
		storage_cohort_fixture(source, function(storage, _, path, _, write, read)
			storage.get("a")
			local rename, calls = os.rename, 0
			os.rename = function(from, to)
				local result, detail, errno = rename(from, to)
				if to == path then calls = calls + 1; return false, "native effect without ACK" end
				return result, detail, errno
			end
			local okay, result = pcall(storage.set, "a", true)
			os.rename = rename
			helpers.assert_true(okay); helpers.assert_eq(result, false); helpers.assert_eq(calls, 1)
			helpers.assert_eq(read(path), '{"a":true,"future":0.1}'); helpers.assert_eq(storage.get("a"), false)
			helpers.assert_eq(storage.set("a", true), false); helpers.assert_eq(calls, 1)
			helpers.assert_eq(storage.acquire_owned({}, { "neighbor" }), false)
			write(path, source) -- Explicit actual-source repair, never an automatic inverse.
			helpers.assert_true(storage.set("a", true)); helpers.assert_eq(read(path), '{"a":true,"future":0.1}')
		end)
	end)
	helpers.it("released-source: acknowledged native rename retries only failed readback", function()
		storage_cohort_fixture('{"a":false,"future":0.1}', function(storage, _, path, _, _, read)
			storage.get("a")
			local reader = require("infra.regular_file_reader")
			local rename, open, effect, renames = os.rename, reader.open, false, 0
			os.rename = function(from, to)
				local result, detail, errno = rename(from, to)
				if to == path and result == true then effect = true; renames = renames + 1 end
				return result, detail, errno
			end
			reader.open = function(name, ...)
				if name == path and effect then return nil, "readback EACCES", 13 end
				return open(name, ...)
			end
			local okay, result = pcall(storage.set, "a", true)
			reader.open, os.rename = open, rename
			helpers.assert_true(okay); helpers.assert_eq(result, false); helpers.assert_eq(renames, 1)
			helpers.assert_eq(read(path), '{"a":true,"future":0.1}'); helpers.assert_eq(storage.get("a"), false)
			helpers.assert_true(storage.set("a", true)); helpers.assert_eq(renames, 1)
			helpers.assert_eq(storage.get("a"), true); helpers.assert_nil(read(path .. ".tmp"))
		end)
	end)
end)

helpers.describe("storage lazy recovery permission under native ownership", function()
	for _, vector in ipairs({
		{ label = "valid", source = '{"a":false,"future":0.1}' },
		{ label = "malformed", source = '{malformed foreign bytes' },
		{ label = "absent" },
	}) do
		helpers.it("held-read: claim-only " .. vector.label .. " source refuses every lazy reader without effects", function()
			storage_cohort_fixture(vector.source, function(storage, _, path, _, _, read)
				local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
				local reader = require("infra.regular_file_reader"); local open, calls = reader.open, 0
				reader.open = function(name, ...)
					if name == path then calls = calls + 1 end
					return open(name, ...)
				end
				local called, value, present, keys = pcall(function()
					return storage.get("a", "guarded-default"), storage.has("a"), storage.keys()
				end)
				reader.open = open
				helpers.assert_true(called); helpers.assert_eq(value, "guarded-default")
				helpers.assert_eq(present, false); helpers.assert_eq(keys, {})
				helpers.assert_eq(calls, 0); helpers.assert_eq(read(path), vector.source)
				helpers.assert_nil(read(path .. ".corrupt")); helpers.assert_nil(read(path .. ".tmp"))
				helpers.assert_nil(storage.recovery_status()); helpers.assert_true(storage.release_owned(owner))
			end)
		end)
	end
	helpers.it("held-read: refused claim initialization permits later source repair and released ordinary initialization", function()
		storage_cohort_fixture('{malformed original source', function(storage, _, path, _, write, read)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			helpers.assert_eq(storage.get("a", "refused"), "refused")
			helpers.assert_true(storage.release_owned(owner))
			write(path, '{"a":false,"future":0.1}')
			helpers.assert_true(storage.set("a", true))
			helpers.assert_eq(read(path), '{"a":true,"future":0.1}')
			helpers.assert_eq(storage.get("a"), true); helpers.assert_nil(read(path .. ".corrupt"))
		end)
	end)
	helpers.it("held-read: active ordinary cleanup preserves a malformed successor during all lazy reads", function()
		ordinary_debt_fixture("refuse", function(storage, _, path, _, write, read, state)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			helpers.assert_eq(storage.set("foreign", true), false)
			local malformed = '{malformed external successor'
			write(path, malformed)
			helpers.assert_eq(storage.get("foreign", "refused"), "refused")
			helpers.assert_eq(storage.has("foreign"), false); helpers.assert_eq(storage.keys(), {})
			helpers.assert_eq(read(path), malformed); helpers.assert_nil(read(path .. ".corrupt"))
			helpers.assert_nil(storage.recovery_status()); helpers.assert_eq(state.writes, 1)
			helpers.assert_true(storage.release_owned(owner))
			helpers.assert_eq(storage.get("foreign", "still-refused"), "still-refused")
			helpers.assert_eq(read(path), malformed); helpers.assert_nil(read(path .. ".corrupt"))
			local candidate = '{"a":false,"future":0.1,"huge":9007199254740993,"foreign":true}'
			write(path, candidate); state.mode = "settle"
			helpers.assert_true(storage.set("foreign", true))
			helpers.assert_eq(state.writes, 1); helpers.assert_eq(read(path), candidate)
			helpers.assert_eq(storage.get("foreign"), true)
		end)
	end)
	helpers.it("held-read: ordinary boot initialization does not grant reentrant readers its private permission", function()
		storage_cohort_fixture('{"a":false,"future":0.1}', function(storage, _, path, _, _, read)
			local reader = require("infra.regular_file_reader"); local open, entered, observed = reader.open, false, {}
			reader.open = function(name, ...)
				if name == path and not entered then
					entered = true
					observed.get = storage.get("a", "refused")
					observed.has = storage.has("a")
					observed.keys = storage.keys()
				end
				return open(name, ...)
			end
			local called, result = pcall(storage.set, "a", true)
			reader.open = open
			helpers.assert_true(called); helpers.assert_true(result); helpers.assert_true(entered)
			helpers.assert_eq(observed.get, "refused"); helpers.assert_eq(observed.has, false); helpers.assert_eq(observed.keys, {})
			helpers.assert_eq(read(path), '{"a":true,"future":0.1}'); helpers.assert_nil(read(path .. ".corrupt"))
		end)
	end)
	helpers.it("held-read: cached reads remain read-only while ownership is active", function()
		storage_cohort_fixture('{"a":false,"future":0.1}', function(storage, _, path, _, write, read)
			helpers.assert_eq(storage.get("a"), false)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			write(path, '{malformed external bytes')
			helpers.assert_eq(storage.get("a"), false); helpers.assert_eq(storage.has("a"), true)
			local keys = storage.keys(); table.sort(keys)
			helpers.assert_eq(keys, { "a", "future" })
			helpers.assert_eq(read(path), '{malformed external bytes'); helpers.assert_nil(read(path .. ".corrupt"))
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)
end)

helpers.describe("storage ordinary initialization lifetime", function()
	for _, vector in ipairs({
		{ label = "valid", source = '{"a":false,"future":0.1}' },
		{ label = "malformed", source = '{malformed actual recovery source' },
	}) do
		helpers.it("held-load: " .. vector.label .. " native read callbacks cannot acquire overlapping ownership", function()
			storage_cohort_fixture(vector.source, function(storage, _, path, _, _, read)
				local reader = require("infra.regular_file_reader"); local open, entered = reader.open, false
				local owner, observed = {}, {}
				reader.open = function(name, ...)
					if name == path and not entered then
						entered = true
						observed.acquire = storage.acquire_owned(owner, { "a" })
						observed.get = storage.get("a", "reentry-refused")
						observed.set = storage.set("foreign", true)
					end
					return open(name, ...)
				end
				local called, value = pcall(storage.get, "a", "ordinary-default")
				reader.open = open
				helpers.assert_true(called); helpers.assert_true(entered)
				helpers.assert_eq(observed.acquire, false); helpers.assert_eq(observed.set, false)
				helpers.assert_eq(observed.get, "reentry-refused")
				if vector.label == "valid" then
					helpers.assert_eq(value, false); helpers.assert_eq(read(path), vector.source)
					helpers.assert_nil(storage.recovery_status())
				else
					helpers.assert_eq(value, "ordinary-default"); helpers.assert_nil(read(path))
					helpers.assert_eq(read(path .. ".corrupt"), vector.source)
					helpers.assert_eq(storage.recovery_status().preserved, true)
				end
				helpers.assert_true(storage.acquire_owned(owner, { "a" }))
				helpers.assert_true(storage.release_owned(owner))
			end)
		end)
	end
	helpers.it("held-load: throwing recovery logger releases initialization lifetime without hiding the exception", function()
		storage_cohort_fixture('{malformed unclaimed source', function(storage, _, path, _, _, read)
			local logger = require("logger.shim"); local error_log = logger.error
			local owner, observed = {}, {}
			logger.error = function()
				observed.acquire = storage.acquire_owned(owner, { "a" })
				observed.set = storage.set("foreign", true)
				error("controlled actual recovery logger failure")
			end
			local called, failure = pcall(storage.get, "a")
			logger.error = error_log
			helpers.assert_eq(called, false)
			helpers.assert_true(tostring(failure):find("controlled actual recovery logger failure", 1, true) ~= nil)
			helpers.assert_eq(observed.acquire, false); helpers.assert_eq(observed.set, false)
			helpers.assert_eq(read(path .. ".corrupt"), '{malformed unclaimed source')
			helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)
end)

helpers.describe("first owned native storage publication", function()
	local function missing_parent(body)
		storage_cohort_fixture(nil, function(storage, files, path, backup, write, read)
			local directory = path:match("^(.*)/[^/]+$")
			assert(os.remove(directory), "the actual storage parent starts absent")
			local Shell = require("adapters.shell_runner")
			local native_run, commands = Shell.run, {}
			local hook
			Shell.run = function(command)
				if command:find("mkdir -p ", 1, true) then
					commands[#commands + 1] = command
					if hook then return hook(command, native_run) end
				end
				return native_run(command)
			end
			local ok, err = xpcall(function()
				body(storage, files, path, backup, write, read, commands,
					function(callback) hook = callback end)
			end, debug.traceback)
			Shell.run = native_run
			if not ok then error(err, 0) end
		end)
	end
	helpers.it("owned-storage-parent: first native effect creates the real parent and restores exact absence", function()
		missing_parent(function(storage, files, path, backup, _, read, commands, inject)
			local owner = { pending = function() return false end }
			helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			local receipt, cells = storage.capture_owned(owner)
			helpers.assert_eq(cells, { a = { present = false } })
			local calls, reentry = {}, {}
			inject(function(command, native)
				reentry = { storage.set("foreign", true), storage.release_owned(owner), storage.capture_owned(owner) }
				return native(command)
			end)
			local observed = { delete = files.delete, write_if_unchanged = function(target, bytes, expected)
				calls[#calls + 1] = target
				if target == path then
					helpers.assert_eq(expected, { status = "absent" })
					helpers.assert_not_nil(read(backup), "the verified backup precedes the first effect")
				end
				return files.write_if_unchanged(target, bytes, expected)
			end }
			helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, observed))
			helpers.assert_eq(#commands, 1)
			helpers.assert_eq(reentry[1], false); helpers.assert_eq(reentry[2], false); helpers.assert_nil(reentry[3])
			helpers.assert_eq(calls, { backup, path })
			helpers.assert_eq(read(path), '{"a":true}')
			local saved = require("json").decode_lossless(read(backup))
			helpers.assert_eq(saved.source, { status = "absent" }); helpers.assert_eq(saved.cells, { a = { present = false } })
			helpers.assert_eq(storage.pending_owned(owner, receipt), false)
			helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_nil(read(path))
			helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.forget_owned(owner, receipt))
		end)
	end)
	for _, refusal in ipairs({
		{ "false", function() return false end }, { "nil", function() return nil end },
		{ "truthy string", function() return "true" end }, { "wrong object", function() return {} end },
		{ "exception", function() error("native directory preparation refused") end },
	}) do
		helpers.it("owned-storage-parent: strict native preparation " .. refusal[1] .. " leaves the receipt unspent", function()
			missing_parent(function(storage, files, path, backup, _, read, commands, inject)
				local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
				local receipt = assert(storage.capture_owned(owner))
				inject(refusal[2])
				helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files), false)
				helpers.assert_eq(#commands, 1); helpers.assert_nil(read(path)); helpers.assert_nil(read(backup))
				helpers.assert_eq(storage.pending_owned(owner, receipt), false)
				inject(nil)
				helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files))
				helpers.assert_eq(read(path), '{"a":true}'); helpers.assert_eq(#commands, 2)
				helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_nil(read(path))
				helpers.assert_true(storage.release_owned(owner))
			end)
		end)
	end
	helpers.it("owned-storage-parent: a claimed preparation success never fabricates a native file effect", function()
		missing_parent(function(storage, files, path, backup, _, read, _, inject)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			local receipt = assert(storage.capture_owned(owner)); inject(function() return true end)
			helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files), false)
			helpers.assert_nil(read(path)); helpers.assert_eq(storage.pending_owned(owner, receipt), false)
			helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_nil(read(path))
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)
	helpers.it("owned-storage-parent: a source successor during real preparation is never adopted before staging", function()
		missing_parent(function(storage, files, path, backup, write, read, _, inject)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			local receipt = assert(storage.capture_owned(owner)); local successor = ' {"foreign":[]}\n'
			inject(function(command, native)
				local prepared = native(command); assert(prepared == true); write(path, successor); return prepared
			end)
			helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files), false)
			helpers.assert_eq(read(path), successor); helpers.assert_nil(read(backup)); helpers.assert_eq(storage.pending_owned(owner, receipt), false)
			inject(nil)
			helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files))
			helpers.assert_true(require("json").is_array(require("json").decode_lossless(read(path)).foreign))
			helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_eq(read(path), successor)
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)
	helpers.it("owned-storage-parent: native producer withdrawal during preparation refuses before backup", function()
		missing_parent(function(storage, files, path, backup, _, read, _, inject)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			local receipt = assert(storage.capture_owned(owner)); local comparisons = 0
			local mt = { __eq = function() comparisons = comparisons + 1; return true end }
			setmetatable(storage, mt); local successor = setmetatable({}, mt)
			inject(function(command, native)
				local prepared = native(command); package.loaded["adapters.storage"] = successor; return prepared
			end)
			local accepted = storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files)
			package.loaded["adapters.storage"] = storage; setmetatable(storage, nil)
			helpers.assert_eq(accepted, false); helpers.assert_eq(comparisons, 0)
			helpers.assert_nil(read(path)); helpers.assert_nil(read(backup)); helpers.assert_eq(storage.pending_owned(owner, receipt), false)
			inject(nil)
			helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files))
			helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_true(storage.release_owned(owner))
		end)
	end)
	helpers.it("owned-storage-parent: native file callback replacement during preparation refuses before staging", function()
		missing_parent(function(storage, files, path, backup, _, read, _, inject)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			local receipt = assert(storage.capture_owned(owner)); local calls = 0
			local producer = { delete = files.delete, write_if_unchanged = files.write_if_unchanged }
			inject(function(command, native)
				local prepared = native(command)
				producer.write_if_unchanged = function() calls = calls + 1; return true end
				return prepared
			end)
			helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, producer), false)
			helpers.assert_eq(calls, 0); helpers.assert_nil(read(path)); helpers.assert_nil(read(backup))
			helpers.assert_eq(storage.pending_owned(owner, receipt), false)
			producer.write_if_unchanged = files.write_if_unchanged; inject(nil)
			helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, producer))
			helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_true(storage.release_owned(owner))
		end)
	end)
	for _, method in ipairs({ "write_if_unchanged", "delete" }) do
		helpers.it("owned-storage-parent: source reread withdrawal of " .. method .. " refuses before staging", function()
			missing_parent(function(storage, files, path, backup, _, read, _, inject)
				local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
				local receipt = assert(storage.capture_owned(owner))
				local producer = { delete = files.delete, write_if_unchanged = files.write_if_unchanged }
				local reader = require("infra.regular_file_reader")
				local original_open, prepared, replaced, calls = reader.open, false, false, 0
				inject(function(command, native)
					local accepted = native(command); prepared = accepted == true; return accepted
				end)
				reader.open = function(target, ...)
					if prepared and target == path and not replaced then
						replaced = true
						producer[method] = function(...)
							calls = calls + 1; return files[method](...)
						end
					end
					return original_open(target, ...)
				end
				local called, accepted = pcall(storage.publish_owned, owner, receipt,
					{ a = { present = true, value = true } }, backup, producer)
				reader.open = original_open
				-- Observe receipts/effects outside the protected publication callback.
				helpers.assert_eq(called, true); helpers.assert_eq(replaced, true)
				helpers.assert_eq(accepted, false); helpers.assert_eq(calls, 0)
				helpers.assert_nil(read(path)); helpers.assert_nil(read(backup))
				helpers.assert_eq(storage.pending_owned(owner, receipt), false)
				producer[method] = files[method]; inject(nil)
				helpers.assert_true(storage.publish_owned(owner, receipt,
					{ a = { present = true, value = true } }, backup, producer))
				helpers.assert_eq(read(path), '{"a":true}')
				helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_nil(read(path))
				helpers.assert_true(storage.release_owned(owner))
			end)
		end)
	end

end)

helpers.describe("storage released regular-file link admission", function()
	local source = ' {"a":false,"foreign":[9007199254740993,{},[],null]} '
	local function linked(body, dangling)
		storage_cohort_fixture(nil, function(storage, files, path, target, write, read)
			local Shell = require("adapters.shell_runner")
			if not dangling then write(target, source) end
			helpers.assert_true(Shell.run("ln -s -- " .. Shell.quote(target) .. " " .. Shell.quote(path)))
			body(storage, files, path, target, write, read, Shell)
		end)
	end
	for _, vector in ipairs({
		{ name = "set", mutate = function(storage) return storage.set("a", true) end,
			expected = ' {"a":true,"foreign":[9007199254740993,{},[],null]} ' },
		{ name = "set_many", mutate = function(storage) return storage.set_many({ a = true }) end,
			expected = ' {"a":true,"foreign":[9007199254740993,{},[],null]} ' },
		{ name = "delete", mutate = function(storage) return storage.delete("a") end,
			expected = ' {"foreign":[9007199254740993,{},[],null]} ' },
		{ name = "clear", mutate = function(storage) return storage.clear() end, expected = ' {} ' },
	}) do
		helpers.it("released-link: " .. vector.name .. " replaces only the link and preserves foreign source tokens", function()
			linked(function(storage, _, path, target, _, read, Shell)
				helpers.assert_eq(storage.get("a"), false)
				helpers.assert_true(vector.mutate(storage))
				helpers.assert_eq(read(path), vector.expected); helpers.assert_eq(read(target), source)
				helpers.assert_eq(Shell.run("test -L " .. Shell.quote(path)), false)
				helpers.assert_nil(read(path .. ".tmp")); helpers.assert_nil(storage.recovery_status())
				local restarted = helpers.load_module("adapters.storage")
				helpers.assert_eq(restarted.get("a", "absent"), (vector.name == "delete" or vector.name == "clear") and "absent" or true)
			end)
		end)
	end
	helpers.it("released-link: owned capture and foreign cohort publication retain strict source-kind refusal", function()
		linked(function(storage, _, path, target, _, read, Shell)
			helpers.assert_eq(storage.get("a"), false)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			helpers.assert_nil(storage.capture_owned(owner))
			helpers.assert_eq(storage.set("neighbor", true), false)
			helpers.assert_eq(read(path), source); helpers.assert_eq(read(target), source)
			helpers.assert_true(Shell.run("test -L " .. Shell.quote(path)))
			helpers.assert_nil(read(path .. ".tmp")); helpers.assert_nil(storage.recovery_status())
			helpers.assert_true(storage.release_owned(owner))
			helpers.assert_true(storage.set("a", true)); helpers.assert_eq(read(target), source)
		end)
	end)
	helpers.it("released-link: dangling source remains refused rather than treated as an absent regular file", function()
		linked(function(storage, _, path, target, _, read, Shell)
			helpers.assert_eq(storage.set("a", true), false)
			helpers.assert_true(Shell.run("test -L " .. Shell.quote(path)))
			helpers.assert_nil(read(target)); helpers.assert_nil(read(path .. ".tmp"))
		end, true)
	end)
	for _, failure in ipairs({ "read", "close" }) do
		helpers.it("released-link: actual descriptor " .. failure .. " refusal preserves the link and cache", function()
			linked(function(storage, _, path, target, _, read, Shell)
				helpers.assert_eq(storage.get("a"), false)
				local reader = require("infra.regular_file_reader"); local open, calls = reader.open, 0
				reader.open = function(name, ...)
					local handle, detail, errno = open(name, ...)
					if name ~= path or not handle then return handle, detail, errno end
					calls = calls + 1
					return {
						read = function(_, ...) if failure == "read" then return nil, "controlled native read refusal" end; return handle:read(...) end,
						close = function() local closed = handle:close(); if failure == "close" then return false end; return closed end,
					}
				end
				local called, accepted = pcall(storage.set, "a", true)
				reader.open = open
				helpers.assert_true(called); helpers.assert_eq(accepted, false); helpers.assert_true(calls > 0)
				helpers.assert_eq(storage.get("a"), false); helpers.assert_eq(read(target), source)
				helpers.assert_true(Shell.run("test -L " .. Shell.quote(path))); helpers.assert_nil(read(path .. ".tmp"))
				helpers.assert_true(storage.set("a", true)); helpers.assert_eq(read(target), source)
			end)
		end)
	end
	helpers.it("released-link: final source callback withdrawal refuses publication until exact capability repair", function()
		linked(function(storage, _, path, target, _, read, Shell)
			storage.get("a")
			local reader = require("infra.regular_file_reader"); local open, samples, set = reader.open, 0, storage.set
			reader.open = function(name, ...)
				local handle, detail, errno = open(name, ...)
				if name == path then samples = samples + 1; if samples == 2 then storage.set = function() return false end end end
				return handle, detail, errno
			end
			local called, accepted = pcall(set, "a", true)
			reader.open, storage.set = open, set
			helpers.assert_true(called); helpers.assert_eq(accepted, false); helpers.assert_true(samples >= 2)
			helpers.assert_eq(read(target), source); helpers.assert_eq(read(path), source)
			helpers.assert_true(Shell.run("test -L " .. Shell.quote(path))); helpers.assert_nil(read(path .. ".tmp"))
			helpers.assert_true(storage.set("a", true)); helpers.assert_eq(read(target), source)
		end)
	end)
	helpers.it("released-link: source-read and native-rename reentry cannot mutate or acquire another alias", function()
		linked(function(storage, _, path, target, _, read)
			storage.get("a")
			local reader = require("infra.regular_file_reader"); local open, rename, observed = reader.open, os.rename, {}
			reader.open = function(name, ...)
				if name == path and observed.read_set == nil then
					observed.read_set = storage.set("neighbor", true); observed.read_claim = storage.acquire_owned({}, { "neighbor" })
				end
				return open(name, ...)
			end
			os.rename = function(from, to)
				if to == path then observed.rename_set = storage.set("neighbor", true); observed.rename_claim = storage.acquire_owned({}, { "neighbor" }) end
				return rename(from, to)
			end
			local called, accepted = pcall(storage.set, "a", true)
			reader.open, os.rename = open, rename
			helpers.assert_true(called); helpers.assert_true(accepted)
			for _, name in ipairs({ "read_set", "read_claim", "rename_set", "rename_claim" }) do helpers.assert_eq(observed[name], false) end
			helpers.assert_eq(read(target), source); helpers.assert_eq(read(path), ' {"a":true,"foreign":[9007199254740993,{},[],null]} ')
		end)
	end)
	helpers.it("released-link: acknowledged rename retries only failed physical readback", function()
		linked(function(storage, _, path, target, _, read)
			storage.get("a")
			local reader = require("infra.regular_file_reader"); local open, rename, effect, calls = reader.open, os.rename, false, 0
			os.rename = function(from, to)
				local accepted, detail, errno = rename(from, to)
				if to == path and accepted == true then effect = true; calls = calls + 1 end
				return accepted, detail, errno
			end
			reader.open = function(name, ...)
				if name == path and effect then return nil, "controlled readback EACCES", 13 end
				return open(name, ...)
			end
			local called, accepted = pcall(storage.set, "a", true)
			reader.open = open
			local cached, target_bytes = storage.get("a"), read(target)
			local retry_called, retry = pcall(storage.set, "a", true)
			os.rename = rename
			helpers.assert_true(called); helpers.assert_eq(accepted, false); helpers.assert_eq(calls, 1)
			helpers.assert_eq(target_bytes, source); helpers.assert_eq(cached, false)
			helpers.assert_true(retry_called); helpers.assert_true(retry); helpers.assert_eq(calls, 1)
			helpers.assert_eq(storage.get("a"), true); helpers.assert_nil(read(path .. ".tmp"))
		end)
	end)
	helpers.it("released-link: a refused native rename retires no effect without replacing the link", function()
		linked(function(storage, _, path, target, _, read, Shell)
			storage.get("a")
			local rename, calls = os.rename, 0
			os.rename = function(from, to)
				if to == path then calls = calls + 1; return false, "controlled refusal before native effect" end
				return rename(from, to)
			end
			local called, accepted = pcall(storage.set, "a", true)
			os.rename = rename
			helpers.assert_true(called); helpers.assert_eq(accepted, false); helpers.assert_eq(calls, 1)
			helpers.assert_true(Shell.run("test -L " .. Shell.quote(path)))
			helpers.assert_eq(read(path), source); helpers.assert_eq(read(target), source)
			helpers.assert_eq(storage.get("a"), false); helpers.assert_nil(read(path .. ".tmp"))
			helpers.assert_true(storage.set("a", true)); helpers.assert_eq(read(target), source)
			helpers.assert_eq(Shell.run("test -L " .. Shell.quote(path)), false)
		end)
	end)
end)


helpers.describe("script storage retired journal roots", function()
	helpers.it("script-storage-cohort successful forget releases a retained authentic journal owner", function()
		storage_cohort_fixture('{"a":1,"future":0.1}', function(storage, files, path, backup, _, read)
			local owner = { pending = function() return false end }
			helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			local receipt = assert(storage.capture_owned(owner))
			helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = 2 } }, backup, files))
			-- Retain the exact private journal that the native publication closure
			-- keeps as a JIT constant; no synthetic journal is substituted.
			local records, slot = nil, 1
			while true do
				local name, value = debug.getupvalue(storage.forget_owned, slot)
				if name == nil then break end
				if name == "_owned_receipts" then records = value; break end
				slot = slot + 1
			end
			helpers.assert_type(records, "table", "the real native receipt map must be reachable")
			local retained_journal = records[receipt]
			helpers.assert_true(rawequal(retained_journal.owner, owner))
			local source, snapshot = read(path), read(backup)
			helpers.assert_eq(storage.forget_owned(owner, receipt), false)
			helpers.assert_true(rawequal(retained_journal.owner, owner), "held refusal preserves inverse ownership")
			helpers.assert_true(storage.release_owned(owner))
			for _, pending in ipairs({ function() return true end, function() error("native pending refusal") end }) do
				owner.pending = pending
				helpers.assert_eq(storage.forget_owned(owner, receipt), false)
				helpers.assert_true(rawequal(records[receipt], retained_journal))
				helpers.assert_true(rawequal(retained_journal.owner, owner), "refused finalization must not detach the owner")
			end
			owner.pending = function() return false end
			local native_setmetatable = setmetatable
			setmetatable = function() error("native tombstone allocation refused") end
			local completed = pcall(storage.forget_owned, owner, receipt)
			setmetatable = native_setmetatable
			helpers.assert_eq(completed, false, "tombstone construction must finish before retiring inverse ownership")
			helpers.assert_true(rawequal(records[receipt], retained_journal))
			helpers.assert_true(rawequal(retained_journal.owner, owner))
			helpers.assert_eq(storage.forget_owned({}, receipt), false)
			helpers.assert_true(rawequal(retained_journal.owner, owner))
			helpers.assert_true(storage.forget_owned(owner, receipt))
			helpers.assert_nil(retained_journal.owner, "successful finalization detaches even a rooted retired journal")
			helpers.assert_true(storage.forget_owned(owner, receipt), "the weak tombstone keeps exact idempotence")
			helpers.assert_eq(storage.forget_owned({}, receipt), false)
			helpers.assert_eq(read(path), source); helpers.assert_eq(read(backup), snapshot)
			helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			helpers.assert_eq(storage.restore_owned(owner, receipt), false, "a retained old closure cannot revive its forgotten receipt")
			local fresh = assert(storage.capture_owned(owner))
			helpers.assert_true(fresh ~= receipt)
			helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.forget_owned(owner, fresh))
			helpers.assert_eq(read(path), source); helpers.assert_eq(read(backup), snapshot)
		end)
	end)
end)
