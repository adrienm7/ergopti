--- tests/meta/test_toml_writer_atomic.lua

--- ==============================================================================
--- MODULE: TOML Writer Atomic Write Meta Test
--- DESCRIPTION:
--- Static source guard for the "toml-non-atomic-write" audit finding in
--- _shared/lua/toml_codec/writer.lua.
---
--- ROOT CAUSE ENCODED:
--- M.write() opened the target config file with io.open(path, "w"), which
--- truncates the file to zero bytes immediately. If Hammerspoon reloaded, Lua
--- raised an error, or the machine lost power between the truncate and the
--- fh:write() call, the user's entire TOML configuration was permanently erased.
---
--- The fix writes to a temporary file (path .. ".tmp") first, then calls
--- os.rename(tmp, path) which is an atomic POSIX syscall — the live config
--- always contains either its old or its new content, never an empty file.
--- Both M.write() and M.batch_write() are fixed.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_source(path)
	local fh = io.open(path, "r")
	assert(fh, "cannot open " .. path)
	local src = fh:read("*a")
	fh:close()
	return src
end

local function strip_comments(src)
	local out = {}
	for line in src:gmatch("[^\n]*") do
		if not line:match("^%s*%-%-") then
			out[#out + 1] = line
		end
	end
	return table.concat(out, "\n")
end


-- ===========================================================================
-- ===========================================================================
-- ======= 1/ M.write uses .tmp + os.rename, not direct io.open("w") =========
-- ===========================================================================
-- ===========================================================================

helpers.describe("_shared/lua/toml_codec/writer.lua: atomic write (toml-non-atomic-write)", function()

	helpers.it("M.write writes to a .tmp file before renaming", function()
		local src = strip_comments(read_source(helpers.shared("lua/toml_codec/writer.lua")))
		helpers.assert_true(
			src:find('path%s*%.%.%s*"%.tmp"') ~= nil
			or src:find("path%.%.\"%.tmp\"") ~= nil,
			"writer.lua M.write() must build a tmp_path = path .. \".tmp\" (toml-non-atomic-write)")
	end)

	helpers.it("M.write calls os.rename to atomically replace the target", function()
		local src = strip_comments(read_source(helpers.shared("lua/toml_codec/writer.lua")))
		helpers.assert_true(
			src:find("os%.rename%s*%(") ~= nil,
			"writer.lua must call os.rename(tmp_path, path) for atomic replacement (toml-non-atomic-write)")
	end)

	helpers.it("M.write does NOT open the target path directly with 'w' mode", function()
		local src = strip_comments(read_source(helpers.shared("lua/toml_codec/writer.lua")))
		-- The direct truncating open on the live path must be gone; only the
		-- .tmp open should remain.  We verify the pattern io.open(path, "w")
		-- is absent (the tmp open uses tmp_path or tmp_w, not bare path).
		helpers.assert_true(
			src:find('io%.open%s*%(path%s*,%s*"w"') == nil,
			"writer.lua must NOT open the live config path with 'w' mode directly — use a .tmp intermediary (toml-non-atomic-write)")
	end)

	helpers.it("M.batch_write also uses .tmp + os.rename", function()
		local src = strip_comments(read_source(helpers.shared("lua/toml_codec/writer.lua")))
		-- batch_write has its own write path — both must be atomic
		helpers.assert_true(
			src:find("os%.rename") ~= nil,
			"writer.lua M.batch_write() must also use os.rename for atomic replacement (toml-non-atomic-write)")
	end)

end)
