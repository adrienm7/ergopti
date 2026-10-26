--- tests/hardware/run_sqlite_private_files.lua
--- ==============================================================================
--- MODULE: Native SQLite File Privacy
--- DESCRIPTION:
--- Exercises genuine database creation and inode admission under a shared parent.
--- Chmod refusal is injected at its native seam; files and descriptors stay real.
--- ==============================================================================

local root = assert(arg[1])
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. root .. "/../_shared/lua/?.lua;"
	.. root .. "/../_shared/lua/?/init.lua;" .. package.path
require("compat.utf8").install()
local uv = require("luv")
local Fixture = require("tests.support.keystats_native_fixture")
local Private
local directory = assert(uv.fs_mkdtemp(assert(uv.os_tmpdir()) .. "/sqlite-private-XXXXXX"))
assert(uv.fs_chmod(directory, 493)) -- 0755 is intentional user-selected directory policy.
local database, token = directory .. "/metrics.sqlite", "private-sqlite-fixture"

--- Reads only fixture-owned bytes through a checked actual stream.
local function read(path)
	local file = assert(io.open(path, "rb"))
	local bytes = assert(file:read("*a"))
	assert(file:close())
	return bytes
end

--- Counts retained kernel descriptors whose target is this fixture's database.
local function descriptors()
	local count = 0
	for name in uv.fs_scandir_next, assert(uv.fs_scandir("/proc/self/fd")) do
		if uv.fs_readlink("/proc/self/fd/" .. name) == database then count = count + 1 end
	end
	return count
end

-- A terminal close-refusal vector owns a separate process: the exact refused
-- descriptor remains live until process exit and never earns a shutdown ACK.
if arg[2] == "close-refusal" then
	Private = require("infra.private_sqlite_file")
	require("tests.support.metrics_preferences_fixture").with(function()
		local writer = require("modules.keystats.sqlite_writer")
		local collector = require("modules.keystats.keystats")
		local open, close = uv.fs_open, uv.fs_close
		local owned, opens, closes = nil, 0, 0
		uv.fs_open = function(path, ...)
			local descriptor, detail, code = open(path, ...)
			if path == database and descriptor then owned = descriptor; opens = opens + 1 end
			return descriptor, detail, code
		end
		uv.fs_close = function(descriptor)
			if descriptor == owned then closes = closes + 1; return nil, "controlled close refusal", "EIO" end
			return close(descriptor)
		end
		collector.init({ sqlite_path = database, log_dir = directory })
		uv.fs_open, uv.fs_close = open, close
		assert(owned and uv.fs_fstat(owned).type == "file", "refusal must retain a genuine live descriptor")
		assert(opens == 1 and closes == 1 and not Private.is_settled() and writer.has_private_file_debt())
		assert(writer.open_db(database) == false and Private.admit(database) == false)
		assert(writer.close_db() == false and collector.stop() == false and collector.stop() == false)
		assert(opens == 1 and closes == 1 and descriptors() == 1, "terminal debt cannot reacquire or retry its ambiguous close")
		assert(uv.fs_unlink(database))
	end)
	assert(uv.fs_rmdir(directory))
	print("PASS native SQLite terminal close debt: one retained FD, no reopen/retry, no shutdown ACK")
	os.exit(0)
end

local ok, failure = xpcall(function()
	require("tests.support.metrics_preferences_fixture").with(function()
		Fixture.with(function(k)
			k.init({ sqlite_path = database, log_dir = directory })
			require("tests.support.metrics_consent_fixture").enable(k)
			local writer = require("modules.keystats.sqlite_writer")
			assert(writer.is_available())
			assert(uv.fs_stat(database).mode % 4096 == 384, "new SQLite database must be private under ambient umask")
			Private = require("infra.private_sqlite_file")
			k.on_keydown(token, math.floor(require("infra.monotonic").now_ms()), "private-app")
			Fixture.flush(k)
			assert(writer.query_rows("SELECT text FROM events_typing;")[1] == token)
			local original = read(database)
			local before = uv.fs_stat(database)
			assert(Private.admit(database))
			local after = uv.fs_stat(database)
			assert(before.ino == after.ino and read(database) == original, "private admission cannot replace or truncate existing data")
			assert(uv.fs_chmod(database, 420)) -- A legacy overly-open owner must be tightened explicitly.
			assert(Private.admit(database) and uv.fs_stat(database).mode % 4096 == 384)
			assert(read(database) == original)
			for _, suffix in ipairs({ "-journal", "-wal", "-shm" }) do
				local file = assert(io.open(database .. suffix, "w"))
				assert(file:write(token) and file:close())
				assert(uv.fs_chmod(database .. suffix, 420))
			end
			assert(Private.admit(database))
			for _, suffix in ipairs({ "-journal", "-wal", "-shm" }) do
				assert(uv.fs_stat(database .. suffix).mode % 4096 == 384 and read(database .. suffix) == token)
				assert(uv.fs_unlink(database .. suffix))
			end
			writer.close_db()
			assert(uv.fs_chmod(database, 420))
			local fchmod, calls = uv.fs_fchmod, 0
			uv.fs_fchmod = function() calls = calls + 1; return nil, "controlled chmod refusal", "EPERM" end
			local admitted, detail = pcall(writer.open_db, database)
			uv.fs_fchmod = fchmod
			assert(admitted and detail == false and calls == 1, "chmod refusal must be an explicit failed database admission")
			assert(not writer.is_available() and descriptors() == 0 and read(database) == original)
			assert(uv.fs_chmod(database, 256))
			assert(Private.admit(database) == false and uv.fs_stat(database).mode % 4096 == 256,
				"read-only owner policy cannot silently become writable")
			assert(uv.fs_chmod(database, 384))
			assert(writer.open_db(database))
			assert(writer.query_rows("SELECT text FROM events_typing;")[1] == token)
			-- Observe real companion creation while the native CLI transaction is
			-- still open; the canonical command boundary owns its original umask.
			local Command = require("modules.keystats.sqlite_command")
			local quote = require("text_utils").shell_quote
			local function sql_output(sql)
				local command = assert(Command.build(database, sql, { capture_stderr = true, capture_exit = true }))
				local pipe = assert(io.popen(command, "r"))
				local output = assert(pipe:read("*a"))
				assert(pipe:close())
				local accepted, body = Command.read_exit_receipt(output)
				assert(accepted, "native companion probe must retain its actual SQLite exit receipt")
				return body
			end
			local transaction = "BEGIN IMMEDIATE;\nCREATE TABLE private_fixture(x);\nINSERT INTO private_fixture VALUES (1);\n"
			assert(sql_output(transaction .. ".shell stat -c %a " .. quote(database .. "-journal") .. "\nROLLBACK;\n") == "600\n")
			assert(sql_output("PRAGMA journal_mode=WAL;\n" .. transaction .. ".shell stat -c %a "
				.. quote(database .. "-wal") .. " " .. quote(database .. "-shm") .. "\nROLLBACK;\n") == "wal\n600\n600\n")
			assert(sql_output("PRAGMA journal_mode=DELETE;\n") == "delete\n")
			local race, retired = directory .. "/race.sqlite", directory .. "/retired.sqlite"
			local file = assert(io.open(race, "w")); assert(file:write(token) and file:close())
			assert(uv.fs_chmod(race, 420))
			local actual_chmod = uv.fs_fchmod
			uv.fs_fchmod = function(descriptor, mode)
				assert(actual_chmod(descriptor, mode))
				assert(uv.fs_rename(race, retired))
				local replacement = assert(io.open(race, "w"))
				assert(replacement:write("Replacement fixture bytes") and replacement:close())
				assert(uv.fs_chmod(race, 420))
				return true
			end
			local called, admitted = pcall(Private.admit, race)
			uv.fs_fchmod = actual_chmod
			assert(called and admitted == false, "replaced path cannot acknowledge the pinned inode")
			assert(uv.fs_stat(retired).mode % 4096 == 384 and read(retired) == token)
			assert(uv.fs_stat(race).mode % 4096 == 420 and read(race) == "Replacement fixture bytes",
				"descriptor chmod cannot alter the replacement path")
			assert(uv.fs_stat(directory).mode % 4096 == 493, "database privacy cannot change the shared parent policy")
		end)
	end)
end, debug.traceback)
for name in uv.fs_scandir_next, assert(uv.fs_scandir(directory)) do assert(uv.fs_unlink(directory .. "/" .. name)) end
assert(uv.fs_rmdir(directory))
assert(ok, failure)
print("PASS native SQLite privacy: creation, legacy repair, companions, refusal, bytes and descriptor cleanup")
