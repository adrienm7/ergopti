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
		storage_cohort_fixture('{"a":1}', function(storage, files, path, backup, _, read)
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
			local weak = setmetatable({ owner, receipt }, { __mode = "v" })
			owner, receipt, pending = nil, nil, nil
			collectgarbage("collect"); collectgarbage("collect")
			helpers.assert_nil(weak[1]); helpers.assert_nil(weak[2])
		end)
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
	helpers.it("script-storage-cohort unsafe future decimal tokens refuse before any native effect", function()
		local cases = {
			'{"a":false,"future":9007199254740993}',
			'{"a":false,"future":0.1}',
			'{"a":false,"future":1e-400}',
			'{"a":false,"future":[0.12345678901234567890123456789]}',
			'{"a":false,"future":{"nested":9007199254740993}}',
		}
		for _, source in ipairs(cases) do
			storage_cohort_fixture(source, function(storage, _, path, backup, _, read)
				local owner = { pending = function() return false end }
				helpers.assert_true(storage.acquire_owned(owner, { "a" }))
				helpers.assert_nil(storage.capture_owned(owner), "unsafe token source refuses untouched: " .. source)
				helpers.assert_eq(storage.set("a", true), false)
				helpers.assert_eq(storage.set("foreign", true), false, "held-cohort foreign writes must not reencode unsafe source")
				helpers.assert_eq(read(path), source); helpers.assert_nil(read(backup))
				helpers.assert_nil(read(path .. ".tmp")); helpers.assert_nil(read(path .. ".corrupt"))
				helpers.assert_nil(storage.recovery_status()); helpers.assert_true(storage.release_owned(owner))
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
