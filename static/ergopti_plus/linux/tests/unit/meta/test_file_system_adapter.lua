--- tests/unit/meta/test_file_system_adapter.lua
---
--- Integration tests for the file_system adapter.
--- (lfs + io.open wrapper). Tests ALL methods (read/write/append/exists/delete)
--- against the real filesystem — these tests work on Windows, macOS, and Linux
--- because io.open is platform-agnostic.
---
--- Uses a temp directory in the system temp folder.

local helpers = require("tests.helpers")
local fs      = helpers.load_module("adapters.file_system")

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
				local original_open = io.open
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
				io.open = function(path, mode)
					if path == "native-write-receipt" then return handle end
					return original_open(path, mode)
				end
				local ok, result = pcall(fs[method], "native-write-receipt", "payload")
				io.open = original_open
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
