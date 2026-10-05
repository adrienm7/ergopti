--- tests/unit/meta/test_file_system_adapter.lua
---
--- Native Linux integration tests for the file_system adapter. Reads admit
--- regular files through pinned kernel descriptors; the other methods retain
--- their filesystem receipts. POSIX descriptor tests require a Linux host.
---
--- Uses a temp directory in the system temp folder.

local helpers = require("tests.helpers")
local fs      = helpers.load_module("adapters.file_system")

helpers.describe("generic file write admission", function()
	for _, method in ipairs({ "write", "append" }) do
		local mode = method == "write" and "w" or "a"
		for _, backend in ipairs({ "luv", "ffi" }) do
			for _, receipt in ipairs({ "regular", "fifo", "missing-type", "stat-failure", "stat-throw", "open-failure", "stream-throw", "close-failure" }) do
				helpers.it("linux-file-write-special: " .. method .. " " .. backend .. " " .. receipt, function()
					local Writer = require("infra.regular_file_writer")
					local previous_uv, previous_ffi, previous_open = package.loaded.luv, package.loaded.ffi, io.open
					local admissions, queries, closes, streams, stream_closes = 0, 0, 0, 0, 0
					local flags_seen, creation_mode
					local stream = { close = function() stream_closes = stream_closes + 1; return true end }
					local function admit(path, flags, permissions)
						helpers.assert_eq(path, "/synthetic/destination")
						admissions = admissions + 1; flags_seen, creation_mode = flags, permissions
						if receipt == "open-failure" then return nil, "permission denied", "EACCES" end
						return 42
					end
					local function inspect()
						queries = queries + 1
						if receipt == "stat-throw" then error("native metadata failed") end
						return receipt ~= "fifo" and receipt ~= "missing-type" and receipt ~= "stat-failure"
					end
					local function close()
						closes = closes + 1; return receipt ~= "close-failure"
					end
					if backend == "luv" then
						package.loaded.luv = {
							fs_open = admit,
							fs_fstat = function(fd)
								helpers.assert_eq(fd, 42)
								local regular = inspect()
								if receipt == "stat-failure" then return nil, "metadata denied" end
								return { type = regular and "file" or (receipt == "fifo" and "fifo" or nil) }
							end,
							fs_close = close,
						}
					else
						package.loaded.luv = {}
						package.loaded.ffi = {
							os = "Linux", cdef = function() end,
							new = function(kind, value)
								if kind == "unsigned int" then return value end
								return { mode = receipt == "fifo" and 4480 or 33152, mask = receipt == "missing-type" and 0 or 1 }
							end,
							-- Linux statx has a fixed UAPI, unlike struct stat.
							sizeof = function() return 256 end, offsetof = function() return 28 end,
							C = {
									ergopti_write_open = function(path, flags, permissions)
									local fd = admit(path, flags, permissions); return fd or -1
								end,
								statx = function(fd, path, flags, mask)
									helpers.assert_eq(fd, 42); helpers.assert_eq(path, "")
									helpers.assert_eq(flags, 4096); helpers.assert_eq(mask, 1)
									inspect(); return receipt == "stat-failure" and -1 or 0
								end,
								close = function(fd) helpers.assert_eq(fd, 42); return close() and 0 or -1 end,
							},
							errno = function() return 13 end,
						}
					end
					io.open = function(path, stream_mode)
						helpers.assert_eq(path, "/proc/self/fd/42", "a competing path edit cannot redirect the admitted inode")
						helpers.assert_eq(stream_mode, mode)
						streams = streams + 1
						if receipt == "stream-throw" then error("stdio open failed") end
						return stream
					end
					local ok, result = pcall(Writer.open, "/synthetic/destination", mode)
					package.loaded.luv, package.loaded.ffi, io.open = previous_uv, previous_ffi, previous_open
					helpers.assert_true(ok, tostring(result))
					helpers.assert_eq(result, receipt == "regular" and stream or nil)
					helpers.assert_eq(admissions, 1)
					helpers.assert_eq(flags_seen, 1 + 64 + 2048 + 524288 + (mode == "a" and 1024 or 0),
						"admission must be nonblocking, append-aware and have no O_TRUNC")
					helpers.assert_eq(creation_mode, 438, "creation permissions retain native umask policy")
					helpers.assert_eq(queries, receipt == "open-failure" and 0 or 1)
					helpers.assert_eq(closes, receipt == "open-failure" and 0 or 1)
					local admitted = receipt == "regular" or receipt == "stream-throw" or receipt == "close-failure"
					helpers.assert_eq(streams, admitted and 1 or 0, "nonregular or unproven descriptors cannot reach buffered stdio")
					helpers.assert_eq(stream_closes, receipt == "close-failure" and 1 or 0)
				end)
			end
		end
		helpers.it("linux-file-write-special: " .. method .. " contains admission refusal", function()
			local Writer = require("infra.regular_file_writer")
			local previous = Writer.open
			local admissions = 0
			Writer.open = function(path, stream_mode)
				admissions = admissions + 1
				helpers.assert_eq(path, "/synthetic/fifo"); helpers.assert_eq(stream_mode, mode)
				return nil, "destination is not a regular file", 22
			end
			local ok, result = pcall(fs[method], "/synthetic/fifo", "payload")
			Writer.open = previous
			helpers.assert_true(ok, tostring(result))
			helpers.assert_eq(result, false)
			helpers.assert_eq(admissions, 1, "every write/append must pass descriptor admission")
		end)
	end
end)

helpers.describe("generic file read admission", function()
	local metadata_cases = {
		{ mode = 33152, mask = 1, status = 0, accepted = true },
		{ mode = 4480, mask = 1, status = 0 },
		{ mode = 33152, mask = 0, status = 0 },
		{ mode = 33152, mask = 1, status = -1 },
	}
	for number, case in ipairs(metadata_cases) do
		helpers.it("linux-file-read-special: libc descriptor metadata receipt " .. number, function()
			local Reader = require("infra.regular_file_reader")
			local original_ffi, original_uv, original_open = package.loaded.ffi, package.loaded.luv, io.open
			local queries, closes, opens = 0, 0, 0
			local stream = { close = function() return true end }
			package.loaded.luv = {}
			package.loaded.ffi = {
				os = "Linux", cdef = function() end,
				new = function() return { mode = case.mode, mask = case.mask } end,
				sizeof = function() return 256 end, offsetof = function() return 28 end,
				C = {
					open = function() return 42 end,
					close = function(fd) helpers.assert_eq(fd, 42); closes = closes + 1; return 0 end,
					statx = function(fd, path, flags, mask)
						helpers.assert_eq(fd, 42); helpers.assert_eq(path, "")
						helpers.assert_eq(flags, 4096); helpers.assert_eq(mask, 1)
						queries = queries + 1
						return case.status
					end,
				},
			}
			io.open = function(path)
				helpers.assert_eq(path, "/proc/self/fd/42")
				opens = opens + 1; return stream
			end
			local ok, result = pcall(Reader.open, "/synthetic/source")
			package.loaded.ffi, package.loaded.luv, io.open = original_ffi, original_uv, original_open
			helpers.assert_true(ok, tostring(result))
			helpers.assert_eq(result, case.accepted and stream or nil)
			helpers.assert_eq(queries, 1)
			helpers.assert_eq(closes, 1)
			helpers.assert_eq(opens, case.accepted and 1 or 0)
		end)
	end
	for _, kind in ipairs({ "fifo", "directory", "socket" }) do
		helpers.it("linux-file-read-special: rejects " .. kind .. " before stdio opens", function()
			local Reader = require("infra.regular_file_reader")
			local real_reader, real_open = Reader.open, io.open
			local inspected, opened = 0, 0
			Reader.open = function(path)
				inspected = inspected + 1
				helpers.assert_eq(path, "/synthetic/" .. kind)
				return nil, "source is not a regular file", 22
			end
			io.open = function()
				opened = opened + 1
				return { read = function() return "unclassified stream bytes" end, close = function() return true end }
			end
			local ok, content = pcall(fs.read, "/synthetic/" .. kind)
			Reader.open, io.open = real_reader, real_open
			helpers.assert_true(ok, tostring(content))
			helpers.assert_nil(content)
			helpers.assert_eq(inspected, 1)
			helpers.assert_eq(opened, 0)
		end)
	end
end)

helpers.describe("file read and close receipts", function()
	local cases = {
		{ name = "healthy", content = "payload", closed = true, expected = "payload" },
		{ name = "read refusal", closed = true },
		{ name = "read exception", read_throws = true, closed = true },
		{ name = "close nil", content = "payload" },
		{ name = "close false", content = "payload", closed = false },
		{ name = "close exception", content = "payload", close_throws = true },
	}
	for _, case in ipairs(cases) do
		helpers.it("linux-file-read-receipts: settles " .. case.name, function()
			local Reader = require("infra.regular_file_reader")
			local original_open = Reader.open
			local reads, closes = 0, 0
			Reader.open = function()
				return {
					read = function(_, mode)
						reads = reads + 1; helpers.assert_eq(mode, "*a")
						if case.read_throws then error("native read raised") end
						return case.content, "native read refused"
					end,
					close = function()
						closes = closes + 1
						if case.close_throws then error("native close raised") end
						return case.closed, "native close refused"
					end,
				}
			end
			local ok, content = pcall(fs.read, "/synthetic/source")
			Reader.open = original_open
			helpers.assert_true(ok, tostring(content))
			helpers.assert_eq(content, case.expected)
			helpers.assert_eq(reads, 1)
			helpers.assert_eq(closes, 1, "read exceptions must still close the owned stream")
		end)
	end
end)

--- Selects a metadata backend while preserving the production adapter itself.
local function with_exists_backend(backend, result, test)
	local previous_require, previous_open = require, io.open
	local previous_files = package.loaded["adapters.file_system"]
	local Shell = require("adapters.shell_runner")
	local previous_run = Shell.run
	local state = { stats = 0, opens = 0, commands = {} }
	local function stat(path)
		state.stats = state.stats + 1
		state.path = path
		if result == "raise" then error("metadata refused") end
		return result == "present" and { mode = "file" } or nil, "native refusal"
	end
	local function access(fd, path, mode, flags)
		state.stats = state.stats + 1
		state.fd, state.path, state.mode, state.flags = fd, path, mode, flags
		if result == "raise" then error("native access refused") end
		return result == "present" and 0 or -1
	end
	require = function(name)
		if name == "lfs" then
			if backend == "lfs" then return { attributes = stat } end
			error("optional lfs unavailable")
		end
		if name == "luv" then
			if backend == "luv" then return { fs_stat = stat } end
			error("optional luv unavailable")
		end
		if name == "ffi" then
			if backend == "ffi" then return { cdef = function() end, C = { faccessat = access } } end
			error("optional ffi unavailable")
		end
		return previous_require(name)
	end
	local loaded, Files = pcall(helpers.load_module, "adapters.file_system")
	require = previous_require
	package.loaded["adapters.file_system"] = previous_files
	if not loaded then error(Files, 0) end
	io.open = function() state.opens = state.opens + 1; return nil, "no readable stream" end
	Shell.run = function(command)
		state.commands[#state.commands + 1] = command
		if result == "raise" then error("native test refused") end
		return result == "present"
	end
	local ok, err = xpcall(function() test(Files, state, Shell) end, debug.traceback)
	io.open, Shell.run = previous_open, previous_run
	if not ok then error(err, 0) end
end

helpers.describe("linux-file-exists-receipts", function()
	for _, backend in ipairs({ "lfs", "luv", "ffi" }) do
		for _, result in ipairs({ "present", "absent", "denied", "raise" }) do
			helpers.it("linux-file-exists-receipts: " .. backend .. " " .. result .. " uses metadata without a stream", function()
				with_exists_backend(backend, result, function(Files, state)
					helpers.assert_eq(Files.exists("/metadata-owned"), result == "present")
					helpers.assert_eq(state.stats, 1)
					helpers.assert_eq(state.path, "/metadata-owned")
					if backend == "ffi" then
						helpers.assert_eq(state.fd, -100)
						helpers.assert_eq(state.mode, 0)
						helpers.assert_eq(state.flags, 512, "existence must use effective credentials")
					end
					helpers.assert_eq(state.opens, 0, "exists cannot need read permission or wait on a FIFO")
					helpers.assert_eq(#state.commands, 0, "an available stat backend owns the receipt")
				end)
			end)
		end
	end
	for _, result in ipairs({ "present", "absent", "raise" }) do
		helpers.it("linux-file-exists-receipts: shell fallback " .. result .. " quotes one literal path", function()
			with_exists_backend("shell", result, function(Files, state, Shell)
				local path = "/owned/é漢-'quote\nline"
				helpers.assert_eq(Files.exists(path), result == "present")
				helpers.assert_eq(state.opens, 0)
				helpers.assert_eq(state.stats, 0)
				helpers.assert_eq(#state.commands, 1)
				helpers.assert_eq(state.commands[1], "test -e " .. Shell.quote(path) .. " 2>/dev/null")
			end)
		end)
	end
	helpers.it("linux-file-exists-receipts: invalid NUL path cannot reach any backend", function()
		with_exists_backend("luv", "present", function(Files, state)
			helpers.assert_eq(Files.exists("/owned\0suffix"), false)
			helpers.assert_eq(state.stats + state.opens + #state.commands, 0)
		end)
	end)
end)

-- Create a temp file path for tests that mutate the filesystem.
local tmp_base = os.tmpname and os.tmpname() or (os.getenv("TEMP") or "/tmp") .. "/ergopti_fs_test"
-- os.tmpname() actually creates a file — remove it and use it as a directory marker
os.remove(tmp_base)
local tmp_file = tmp_base .. "_test.txt"
local tmp_utf8 = tmp_base .. "_utf8.txt"

helpers.describe("linux-native-path-receipts", function()
	for _, method in ipairs({ "read", "write", "append", "exists", "delete" }) do
		for index, path in ipairs({ "\0owned", "owned\0suffix", "owned\0", "owned\0suffix\0" }) do
			helpers.it("linux-native-path-receipts: " .. method .. " refuses NUL case " .. index, function()
				local original_open, original_remove = io.open, os.remove
				local native_calls = 0
				local lfs = package.loaded["lfs"]
				local original_attributes = type(lfs) == "table" and lfs.attributes or nil
				io.open = function() native_calls = native_calls + 1; return nil, "not found", 2 end
				os.remove = function() native_calls = native_calls + 1; return true end
				if original_attributes then
					lfs.attributes = function() native_calls = native_calls + 1; return nil, "not found", 2 end
				end
				local ok, result = pcall(fs[method], path, "replacement")
				io.open, os.remove = original_open, original_remove
				if original_attributes then lfs.attributes = original_attributes end
				helpers.assert_true(ok)
				if method == "read" then helpers.assert_eq(result, nil)
				else helpers.assert_eq(result, false) end
				helpers.assert_eq(native_calls, 0, "invalid path must not reach a C-string API")
			end)
		end
	end
end)

helpers.describe("linux-native-delete-receipts", function()
	for _, case in ipairs({
		{ name = "deleted file", result = true, accepted = true },
		{ name = "proven ENOENT", errno = 2, accepted = true },
		{ name = "permission denied", errno = 13, accepted = false },
		{ name = "operation forbidden", errno = 1, accepted = false },
		{ name = "non-directory ancestor", errno = 20, accepted = false },
		{ name = "nonempty directory", errno = 39, accepted = false },
		{ name = "read-only filesystem", errno = 30, accepted = false },
		{ name = "unclassified refusal", accepted = false },
		{ name = "native throw", raises = true, accepted = false },
	}) do
		helpers.it("linux-native-delete-receipts: " .. case.name .. " requires native evidence", function()
			local original_remove, original_exists = os.remove, fs.exists
			local removals = 0
			fs.exists = function() return false end
			os.remove = function(path)
				if path ~= "owned-delete-receipt" then return original_remove(path) end
				removals = removals + 1
				if case.raises then error("native remove failed") end
				if case.result then return true end
				return nil, "native refusal", case.errno
			end
			local ok, result = pcall(fs.delete, "owned-delete-receipt")
			os.remove, fs.exists = original_remove, original_exists
			helpers.assert_eq(result, case.accepted, "deletion must follow the native receipt")
			helpers.assert_true(ok, "native errors are contained")
			helpers.assert_eq(removals, 1, "an ambiguous existence probe cannot bypass native deletion")
		end)
	end
end)

helpers.describe("linux-native-write-receipts", function()
	for _, method in ipairs({ "write", "append" }) do
		for _, failure in ipairs({ "write_return", "write_throw", "close_return", "close_throw" }) do
			helpers.it("linux-native-write-receipts: " .. method .. " rejects " .. failure .. " and closes its file", function()
				local Writer = require("infra.regular_file_writer")
				local original_open = Writer.open
				local closes = 0
				local handle = {}
				function handle:write()
					if failure == "write_return" then return nil, "No space left on device" end
					if failure == "write_throw" then error("write failed") end
					return self
				end
				function handle:close()
					closes = closes + 1
					if failure == "close_return" then return nil, "No space left on device" end
					if failure == "close_throw" then error("close failed") end
					return true
				end
				Writer.open = function(path, mode)
					if path == "native-write-receipt" then return handle end
					return original_open(path, mode)
				end
				local ok, result = pcall(fs[method], "native-write-receipt", "payload")
				Writer.open = original_open
				helpers.assert_true(ok, "native errors do not escape the adapter")
				helpers.assert_eq(result, false, "a failed native receipt cannot report success")
				helpers.assert_eq(closes, 1, "the file is closed even after a failed write")
			end)
		end
	end
end)

helpers.describe("file_system adapter", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports read", function()
      helpers.assert_true(type(fs.read) == "function", "read is a function")
    end)
    helpers.it("exports write", function()
      helpers.assert_true(type(fs.write) == "function", "write is a function")
    end)
    helpers.it("exports append", function()
      helpers.assert_true(type(fs.append) == "function", "append is a function")
    end)
    helpers.it("exports exists", function()
      helpers.assert_true(type(fs.exists) == "function", "exists is a function")
    end)
    helpers.it("exports delete", function()
      helpers.assert_true(type(fs.delete) == "function", "delete is a function")
    end)
  end)

  -- ==========================================================================
  -- 2. exists() — path existence check
  -- ==========================================================================

  helpers.describe("exists()", function()
    helpers.it("returns false for a nonexistent path", function()
      local result = fs.exists("/tmp/ergopti_nonexistent_file_" .. math.random(100000, 999999))
      helpers.assert_eq(result, false, "nonexistent file returns false")
    end)

    helpers.it("returns false for empty string path", function()
      helpers.assert_eq(fs.exists(""), false, "empty path returns false")
    end)

    helpers.it("returns false for nil path", function()
      helpers.assert_eq(fs.exists(nil), false, "nil path returns false")
    end)
  end)

  -- ==========================================================================
  -- 3. write() + read() — round-trip
  -- ==========================================================================

  helpers.describe("write + read round-trip", function()
    -- Clean up any leftover from previous failed runs
    os.remove(tmp_file)

    helpers.it("write returns true on success", function()
      local ok = fs.write(tmp_file, "hello world")
      helpers.assert_true(ok, "write returns true")
    end)

    helpers.it("exists returns true after write", function()
      helpers.assert_true(fs.exists(tmp_file), "file exists after write")
    end)

    helpers.it("read returns exact content written", function()
      local content = fs.read(tmp_file)
      helpers.assert_eq(content, "hello world", "read returns written content")
    end)

    helpers.it("write overwrites existing content", function()
      fs.write(tmp_file, "overwritten")
      local content = fs.read(tmp_file)
      helpers.assert_eq(content, "overwritten", "overwrite works")
    end)

    helpers.it("write empty string succeeds", function()
      local ok = fs.write(tmp_file, "")
      helpers.assert_true(ok, "write empty string returns true")
      local content = fs.read(tmp_file)
      helpers.assert_eq(content, "", "read returns empty string")
    end)
  end)

  -- ==========================================================================
  -- 4. append() — append to file
  -- ==========================================================================

  helpers.describe("append()", function()
    helpers.it("append to new file creates it", function()
      local append_file = tmp_base .. "_append_new.txt"
      os.remove(append_file)
      local ok = fs.append(append_file, "line 1")
      helpers.assert_true(ok, "append creates new file")
      helpers.assert_eq(fs.read(append_file), "line 1", "content matches")
      os.remove(append_file)
    end)

    helpers.it("append adds to existing content", function()
      local append_file = tmp_base .. "_append.txt"
      fs.write(append_file, "first\n")
      fs.append(append_file, "second\n")
      helpers.assert_eq(fs.read(append_file), "first\nsecond\n", "appended correctly")
      os.remove(append_file)
    end)

    helpers.it("append empty string does not corrupt file", function()
      local append_file = tmp_base .. "_append_empty.txt"
      fs.write(append_file, "original")
      local ok = fs.append(append_file, "")
      helpers.assert_true(ok, "append empty string returns true")
      helpers.assert_eq(fs.read(append_file), "original", "content unchanged")
      os.remove(append_file)
    end)
  end)

  -- ==========================================================================
  -- 5. read() — edge cases
  -- ==========================================================================

  helpers.describe("read() edge cases", function()
    helpers.it("read nonexistent file returns nil", function()
      helpers.assert_nil(fs.read("/tmp/ergopti_nonexistent_98765"), "nonexistent returns nil")
    end)

    helpers.it("read empty path returns nil", function()
      helpers.assert_nil(fs.read(""), "empty path returns nil")
    end)

    helpers.it("read nil path returns nil", function()
      helpers.assert_nil(fs.read(nil), "nil path returns nil")
    end)
  end)

  -- ==========================================================================
  -- 6. delete() — file deletion
  -- ==========================================================================

  helpers.describe("delete()", function()
    helpers.it("delete existing file returns true", function()
      local del_file = tmp_base .. "_delete.txt"
      fs.write(del_file, "temp")
      local ok = fs.delete(del_file)
      helpers.assert_true(ok, "delete returns true")
      helpers.assert_eq(fs.exists(del_file), false, "file no longer exists")
    end)

    helpers.it("delete nonexistent file returns true (already absent)", function()
      local ok = fs.delete("/tmp/ergopti_does_not_exist_" .. math.random(200000, 299999))
      helpers.assert_true(ok, "delete nonexistent returns true (contract)")
    end)

    helpers.it("delete empty path returns false", function()
      helpers.assert_eq(fs.delete(""), false, "delete empty path returns false")
    end)

    helpers.it("delete nil path returns false", function()
      helpers.assert_eq(fs.delete(nil), false, "delete nil path returns false")
    end)
  end)

  -- ==========================================================================
  -- 7. write() edge cases
  -- ==========================================================================

  helpers.describe("write() edge cases", function()
    helpers.it("write empty path returns false", function()
      helpers.assert_eq(fs.write("", "content"), false, "write empty path returns false")
    end)

    helpers.it("write nil path returns false", function()
      helpers.assert_eq(fs.write(nil, "content"), false, "write nil path returns false")
    end)

    helpers.it("write nil content writes empty string", function()
      local nil_file = tmp_base .. "_nil_content.txt"
      local ok = fs.write(nil_file, nil)
      helpers.assert_true(ok, "write nil content returns true")
      helpers.assert_eq(fs.read(nil_file), "", "nil content stored as empty string")
      os.remove(nil_file)
    end)
  end)

  -- ==========================================================================
  -- 8. UTF-8 content round-trip
  -- ==========================================================================

  helpers.describe("UTF-8 content", function()
    helpers.it("write + read Unicode preserves content", function()
      local utf8_content = "café résumé — 日本語テスト 🎉"
      fs.write(tmp_utf8, utf8_content)
      local result = fs.read(tmp_utf8)
      helpers.assert_eq(result, utf8_content, "UTF-8 round-trip preserves content")
      os.remove(tmp_utf8)
    end)

    helpers.it("append + read Unicode preserves content", function()
      fs.write(tmp_utf8, "café")
      fs.append(tmp_utf8, " résumé")
      helpers.assert_eq(fs.read(tmp_utf8), "café résumé", "UTF-8 append preserves content")
      os.remove(tmp_utf8)
    end)
  end)

  -- ==========================================================================
  -- 9. Cleanup
  -- ==========================================================================

  helpers.describe("cleanup", function()
    helpers.it("remove temp files", function()
      -- "Mark as pass regardless" was literally the comment. A cleanup case that
      -- cannot fail is worse than none: the suite writes into the user's tmp on
      -- every run, and a remove that silently stops working leaves a growing
      -- pile nobody notices — while this line reports success.
      os.remove(tmp_file)
      local leftover = io.open(tmp_file, "r")
      if leftover then leftover:close() end
      helpers.assert_true(leftover == nil,
        "the temp file this suite created must be gone: " .. tostring(tmp_file))
    end)
  end)

end)

local write_has_ffi = pcall(require, "ffi")
if write_has_ffi or pcall(require, "luv") then
	helpers.describe("native regular-file write admission", function()
		helpers.it("linux-file-write-special: actual file endpoints and partial-write receipts retain no owned descriptors", function()
			local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
			local backend = write_has_ffi and "ffi" or "luv"
			local fixture = helpers.driver_root() .. "/tests/hardware/run_file_write_special_receipts.py"
			local command = "ERGOPTI_WRITE_BACKEND=" .. backend .. " ERGOPTI_FILE_WRITE_TEST_LUA="
				.. quote(assert(arg[-1])) .. " python3 " .. quote(fixture)
			local result = os.execute(command)
			helpers.assert_true(result == true or result == 0, "all twenty-four native/resource-seam checks must pass")
		end)
	end)
end
