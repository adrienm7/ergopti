--- tests/unit/modules/keystats/storage/test_keystats_sqlite_writer_token_encoding.lua

--- ==============================================================================
--- MODULE: N-gram Key Migration Of The Linux Store
--- DESCRIPTION:
--- Linux keeps its derived keys in the database alone, so token encoding 2 is
--- written into them once. These cases run the real writer over a modelled CLI:
--- the backup comes before the one transaction, a store already moved is left
--- alone, and a refused backup changes nothing.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs the migration against modelled store answers.
--- @param answers table { version, keys = table name -> hex rows, refuse = pattern }
--- @return boolean result
--- @return table commands Every CLI script, in order.
local function migrate(answers)
	local writer = helpers.load_module("modules.keystats.sqlite_writer")
	local previous_execute, previous_popen = os.execute, io.popen
	local path = os.tmpname()
	local file = assert(io.open(path, "w"))
	assert(file:write("existing native database fixture") and file:close())
	local commands = {}
	local refused_once = false
	local uv = require("luv")
	local created_dirs, mkdtemp = {}, uv.fs_mkdtemp
	os.execute = function() return 0 end
	io.popen = function(command)
		local content, status = "", 0
		if command:find("SELECT sql FROM sqlite_master", 1, true) then
			content = "CREATE TABLE devices (os CHECK (os IN ('linux')))\n"
		elseif command:find("key='ngram_token_encoding'", 1, true) then
			if answers.version ~= nil then
				local hex = answers.version:gsub(".", function(ch) return string.format("%02X", ch:byte()) end)
				content = "version:" .. hex .. "\n"
			end
		else
			local family = command:match("SELECT DISTINCT hex%(token%) FROM ([%w_]+)")
			if family then content = (answers.keys or {})[family] or "" end
			commands[#commands + 1] = command
			if answers.refuse and command:find(answers.refuse, 1, true) then status = 7 end
			if answers.refuse_once and not refused_once and command:find("UPDATE OR ROLLBACK", 1, true) then
				status, refused_once = 7, true
			end
			local snapshot = command:match("VACUUM INTO '([^']+)';")
			if snapshot and status == 0 then
				local output = assert(io.open(snapshot, "wb"))
				if answers.bad_backup ~= "empty" then assert(output:write("synthetic SQLite backup")) end
				assert(output:close())
				assert(uv.fs_chmod(snapshot, answers.bad_backup == "mode" and 420 or 384))
				if answers.bad_backup == "replaced" then
					local directory = assert(snapshot:match("^(.*)/snapshot%.sqlite$"))
					assert(uv.fs_rename(directory, directory .. ".moved"))
					created_dirs[#created_dirs + 1] = directory .. ".moved"
					assert(uv.fs_mkdir(directory, 448))
					local replacement = assert(io.open(snapshot, "wb"))
					assert(replacement:write("foreign replacement") and replacement:close())
					assert(uv.fs_chmod(snapshot, 384))
				end
			end
		end
		return {
			read = function()
				if (answers.key_read_throw and command:find("SELECT DISTINCT hex(token)", 1, true))
					or (answers.version_read_throw and command:find("key='ngram_token_encoding'", 1, true)) then error("injected read failure") end
				return content .. "\nERGOPTI_SQL_EXIT_STATUS=" .. status .. "\n"
			end,
			lines = function() return content:gmatch("([^\n]*)\n") end,
			close = function()
				if answers.backup_close_false and command:find("VACUUM INTO", 1, true) then return false end
				if (answers.key_close_false and command:find("SELECT DISTINCT hex(token)", 1, true))
					or (answers.version_close_false and command:find("key='ngram_token_encoding'", 1, true)) then return false end
				return true
			end,
		}
	end
	local backup = path .. require("metrics.engine.privacy.token_encoding").BACKUP_SUFFIX
	local exited, process = false, nil
	local ok, result = xpcall(function()
		helpers.assert_true(writer.open_db(path))
		commands = {}
		if answers.existing_backup then
			local existing = assert(io.open(backup, "wb"))
			assert(existing:write("previous backup") and existing:close())
		end
		uv.fs_mkdtemp = function(template)
			if answers.backup_dir_throw then error("injected directory creation failure") end
			local created, detail, code = mkdtemp(template)
			if created then created_dirs[#created_dirs + 1] = created end
			return created, detail, code
		end
		if answers.fifo then
			local made = previous_execute("mkfifo '" .. backup .. "'")
			assert(made == 0 or made == true)
			process = assert(uv.spawn("sh", { args = { "-c", 'sleep 1; printf fake > "$1"', "fixture", backup } }, function()
				exited = true
				process:close()
			end))
		end
		local first = writer.ensure_token_encoding()
		if answers.refuse_once then
			assert(first == false, "first transaction must fail")
			return writer.ensure_token_encoding()
		end
		return first
	end, debug.traceback)
	os.execute, io.popen = previous_execute, previous_popen
	uv.fs_mkdtemp = mkdtemp
	local observations = { dirs = #created_dirs }
	if answers.existing_backup then
		local existing = assert(io.open(backup, "rb")); observations.old = existing:read("*a"); assert(existing:close())
	end
	if answers.fifo then local stat = uv.fs_lstat(backup); observations.fifo = stat and stat.type end
	for _, dir in ipairs(created_dirs) do os.remove(dir .. "/snapshot.sqlite"); os.remove(dir) end
	writer.close_db()
	os.remove(path)
	if answers.fifo then
		os.remove(backup)
		assert(uv.fs_mkdir(backup, 448))
		while not exited do uv.run("once") end
		os.remove(backup)
	end
	if answers.existing_backup then os.remove(backup) end
	if not ok then error(result, 0) end
	return result, commands, observations
end

local function position(commands, needle)
	for index, command in ipairs(commands) do
		if command:find(needle, 1, true) then return index end
	end
	return nil
end

helpers.describe("keystats sqlite writer: n-gram token encoding", function()
	helpers.it("token-encoding: the backup precedes the one rewriting transaction", function()
		local result, commands = migrate({ keys = { ngram_chars = "5B\n" } })
		helpers.assert_true(result)
		local backup = position(commands, "VACUUM INTO")
		local update = position(commands, "UPDATE OR ROLLBACK ngram_chars SET token=CAST(X'5B5B' AS TEXT)")
		helpers.assert_true(backup ~= nil and update ~= nil and backup < update)
		helpers.assert_true(commands[update]:find("BEGIN IMMEDIATE;", 1, true) ~= nil)
		helpers.assert_true(commands[update]:find("'ngram_token_encoding','2'", 1, true) ~= nil,
			"the version is recorded by the same transaction")
	end)

	helpers.it("token-encoding: a store with nothing to rewrite only records the version", function()
		local result, commands = migrate({})
		helpers.assert_true(result)
		helpers.assert_nil(position(commands, "VACUUM INTO"))
		helpers.assert_true(position(commands, "'ngram_token_encoding','2'") ~= nil)
	end)

	for index, version in ipairs({ "", "2\n3", "2\0tail" }) do
		helpers.it("token-encoding refuses a corrupted stored migration marker " .. index, function()
			local result, commands = migrate({ version = version, keys = { ngram_chars = "5B\n" } })
			helpers.assert_eq(result, false)
			helpers.assert_eq(#commands, 0)
		end)
	end

	for _, version in ipairs({ "3", "invalid", "0" }) do
		helpers.it("token-encoding refuses unsupported migration version " .. version, function()
			local result, commands = migrate({ version = version, keys = { ngram_chars = "5B\n" } })
			helpers.assert_eq(result, false)
			helpers.assert_eq(#commands, 0, "unknown encodings cannot be migrated as old keys")
		end)
	end

	helpers.it("token-encoding migrates the explicit legacy version", function()
		local result, commands = migrate({ version = "1", keys = { ngram_chars = "5B\n" } })
		helpers.assert_true(result)
		helpers.assert_true(position(commands, "VACUUM INTO") ~= nil)
		helpers.assert_true(position(commands, "UPDATE OR ROLLBACK") ~= nil)
	end)

	helpers.it("token-encoding: a store already moved is left alone", function()
		local result, commands = migrate({ version = "2" })
		helpers.assert_true(result)
		helpers.assert_eq(#commands, 0, "keys already escaped are never escaped twice")
	end)

	helpers.it("token-encoding: an existing backup cannot replace a fresh snapshot", function()
		local result, commands, observed = migrate({ keys = { ngram_chars = "5B\n" }, existing_backup = true })
		helpers.assert_true(result)
		helpers.assert_eq(observed.old, "previous backup", "existing backup bytes are never replaced")
		helpers.assert_eq(observed.dirs, 1)
		local backup = position(commands, "VACUUM INTO")
		local update = position(commands, "UPDATE OR ROLLBACK")
		helpers.assert_true(backup ~= nil and update ~= nil and backup < update,
			"every migration requires a fresh snapshot of this database")
	end)

	helpers.it("token-encoding refuses an unacknowledged backup process close", function()
		local result, commands = migrate({ keys = { ngram_chars = "5B\n" }, backup_close_false = true })
		helpers.assert_eq(result, false)
		helpers.assert_nil(position(commands, "UPDATE OR ROLLBACK"))
	end)

	helpers.it("token-encoding refuses a backup directory creation exception", function()
		local result, commands = migrate({ keys = { ngram_chars = "5B\n" }, existing_backup = true, backup_dir_throw = true })
		helpers.assert_eq(result, false)
		helpers.assert_nil(position(commands, "UPDATE OR ROLLBACK"))
	end)

	helpers.it("token-encoding: a FIFO at the old backup path is left untouched", function()
		local result, commands, observed = migrate({ keys = { ngram_chars = "5B\n" }, fifo = true })
		helpers.assert_eq(observed.fifo, "fifo", "the pre-existing FIFO is not opened or removed")
		helpers.assert_true(result)
		helpers.assert_true(position(commands, "VACUUM INTO") ~= nil)
		helpers.assert_true(position(commands, "UPDATE OR ROLLBACK") ~= nil)
	end)

	for _, fault in ipairs({ "version_read_throw", "version_close_false" }) do
		helpers.it("token-encoding refuses unknown migration version " .. fault, function()
			local result, commands = migrate({ version = "2", keys = { ngram_chars = "5B\n" }, [fault] = true })
			helpers.assert_eq(result, false)
			helpers.assert_eq(#commands, 0, "failed version read must not reinterpret migrated keys")
		end)
	end

	for _, fault in ipairs({ "key_read_throw", "key_close_false" }) do
		helpers.it("token-encoding refuses incomplete key query " .. fault, function()
			local result, commands = migrate({ keys = { ngram_chars = "5B\n" }, [fault] = true })
			helpers.assert_eq(result, false)
			helpers.assert_nil(position(commands, "VACUUM INTO"))
			helpers.assert_nil(position(commands, "UPDATE OR ROLLBACK"))
		end)
	end

	for _, failure in ipairs({ "empty", "mode", "replaced" }) do
		helpers.it("token-encoding refuses an unowned or incomplete backup " .. failure, function()
			local result, commands = migrate({ keys = { ngram_chars = "5B\n" }, bad_backup = failure })
			helpers.assert_eq(result, false)
			helpers.assert_nil(position(commands, "UPDATE OR ROLLBACK"))
		end)
	end

	helpers.it("token-encoding retries with a distinct fresh backup", function()
		local result, _, observed = migrate({ keys = { ngram_chars = "5B\n" }, refuse_once = true })
		helpers.assert_true(result)
		helpers.assert_eq(observed.dirs, 2, "each attempt retains its own private backup")
	end)

	helpers.it("token-encoding: a refused backup rewrites nothing", function()
		local result, commands = migrate({ keys = { ngram_chars = "5B\n" }, refuse = "VACUUM INTO" })
		helpers.assert_eq(result, false)
		helpers.assert_nil(position(commands, "UPDATE OR ROLLBACK"))
	end)
end)
