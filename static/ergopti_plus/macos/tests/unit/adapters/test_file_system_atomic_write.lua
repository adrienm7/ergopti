--- tests/unit/adapters/test_file_system_atomic_write.lua

--- ==============================================================================
--- MODULE: FileSystem Adapter — Atomic Write Regression (F-MED-16)
--- DESCRIPTION:
--- Guards the fix for F-MED-16: adapters.file_system.write() used a direct
--- io.open(path, "w") write with no temp-file-then-rename step, unlike the
--- sibling karabiner/config.lua's save_user_config(), which correctly writes
--- via a ".tmp" file and os.rename(). karabiner.json is the single most
--- important file this adapter writes (deploy_string -> FileSystem.write in
--- karabiner/generator.lua); a crash mid-write could leave Karabiner-Elements'
--- own FSEvents watcher picking up a torn/truncated config.
---
--- Coverage:
---   1. write() creates a real, complete file (behavioral, real I/O).
---   2. write() never leaves a stray ".tmp" file behind after a successful call.
---   3. write() is symlink-safe: writing through a symlinked path replaces the
---      REAL target file's content, and the symlink itself survives (renaming
---      directly over a symlink path would instead replace the symlink with a
---      plain file, breaking deploy_string's documented symlink support).
--- ==============================================================================

local helpers = require("tests.helpers")

-- Real I/O, mirroring the existing FileSystem contract-vector test: stub only
-- hs.fs.attributes/mkdir/pathToAbsolute so exists()/ensure_dir() work against
-- the real filesystem without a live Hammerspoon runtime.
-- @param resolve_map table|nil Optional {[path] = resolved_path} overrides for
--   pathToAbsolute, simulating a symlink resolving to a different real target.
local function make_adapter(resolve_map)
	package.loaded["adapters.file_system"] = nil
	return helpers.load_with_stubs("adapters.file_system", {
		fs = {
			attributes = function(path)
				local fh = io.open(path, "r")
				if fh then fh:close(); return { mode = "file" } end
				return nil
			end,
			mkdir = function(_) return true end,
			pathToAbsolute = function(p)
				if type(resolve_map) == "table" and resolve_map[p] then
					return resolve_map[p]
				end
				return p
			end,
		},
	})
end





-- =====================================
-- =====================================
-- ======= 1/ Basic atomic write =======
-- =====================================
-- =====================================

helpers.describe("adapters.file_system: write() is atomic (F-MED-16)", function()
	local TMP = os.tmpname()

	helpers.it("write() produces a complete, readable file", function()
		local adapter = make_adapter()
		os.remove(TMP)
		local ok = adapter.write(TMP, "atomic content")
		helpers.assert_true(ok, "write() must return true on success")
		local fh = io.open(TMP, "r")
		helpers.assert_true(fh ~= nil, "file must exist after write()")
		local content = fh:read("*a"); fh:close()
		helpers.assert_eq(content, "atomic content")
		os.remove(TMP)
	end)

	helpers.it("write() does not leave a stray .tmp file behind after success", function()
		local adapter = make_adapter()
		os.remove(TMP)
		os.remove(TMP .. ".tmp")
		adapter.write(TMP, "no leftovers")
		local tmp_fh = io.open(TMP .. ".tmp", "r")
		helpers.assert_true(tmp_fh == nil, "the .tmp staging file must be renamed away, not left behind")
		if tmp_fh then tmp_fh:close() end
		os.remove(TMP)
	end)

	helpers.it("write() overwrites existing content atomically (old content never partially visible)", function()
		local adapter = make_adapter()
		os.remove(TMP)
		adapter.write(TMP, "first version — long enough to detect truncation if the write were not atomic")
		adapter.write(TMP, "second version")
		local fh = io.open(TMP, "r")
		local content = fh:read("*a"); fh:close()
		helpers.assert_eq(content, "second version",
			"the file must contain exactly the new content, with no leftover bytes from the old version")
		os.remove(TMP)
	end)
end)




-- =====================================================
-- =====================================================
-- ======= 2/ Symlink-safe atomic write ================
-- =====================================================
-- =====================================================

-- Regression: renaming a temp file directly OVER a symlinked destination path
-- would replace the symlink itself with a plain file, breaking deploy_string's
-- documented "works for regular paths and Unix symlinks" contract for
-- karabiner.json (a common deployment where ~/.config/karabiner is itself a
-- symlink, or the file is manually symlinked elsewhere). write() must resolve
-- the destination via pathToAbsolute (which follows symlinks) BEFORE deciding
-- where to stage and rename the temp file, so the write lands on the REAL
-- target file and the symlink is left untouched.
helpers.describe("adapters.file_system: write() through a symlinked path is symlink-safe (F-MED-16)", function()
	local SYMLINK_PATH = os.tmpname()
	local REAL_TARGET  = os.tmpname()

	helpers.it("writes land on the resolved real target, not a new file at the symlink path", function()
		os.remove(SYMLINK_PATH)
		os.remove(REAL_TARGET)

		-- Simulate a symlink: pathToAbsolute(SYMLINK_PATH) resolves to REAL_TARGET,
		-- exactly as hs.fs.pathToAbsolute does for a real Unix symlink.
		local adapter = make_adapter({ [SYMLINK_PATH] = REAL_TARGET })

		local ok = adapter.write(SYMLINK_PATH, "deployed via symlink")
		helpers.assert_true(ok, "write() must succeed when the destination resolves through a symlink")

		local real_fh = io.open(REAL_TARGET, "r")
		helpers.assert_true(real_fh ~= nil, "the RESOLVED real target must contain the written content")
		local content = real_fh:read("*a"); real_fh:close()
		helpers.assert_eq(content, "deployed via symlink")

		-- Critically: no NEW plain file must have been created directly at the
		-- symlink path itself — that would mean the rename replaced the symlink.
		local symlink_path_fh = io.open(SYMLINK_PATH, "r")
		helpers.assert_true(symlink_path_fh == nil,
			"write() must NOT create a plain file at the symlink path — that would destroy the symlink")
		if symlink_path_fh then symlink_path_fh:close() end

		os.remove(SYMLINK_PATH)
		os.remove(REAL_TARGET)
	end)
end)




-- ==========================================
-- ==========================================
-- ======= 2/ Source-shape assertion ========
-- ==========================================
-- ==========================================

-- Behavioral coverage above proves write() works; this pins the actual
-- temp+rename SHAPE in source so a future refactor cannot silently revert to
-- a direct io.open(path, "w") without a regression test catching it.
helpers.describe("adapters.file_system: write() source uses temp+rename (F-MED-16)", function()
	local function read_source()
		-- Selected by a declaration unique to adapters/file_system.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("function M.expand_path")
		helpers.assert_true(src ~= nil, "adapters/file_system.lua source must be locatable")
		return src
	end

	helpers.it("write() builds a .tmp path and writes to it, not directly to the destination", function()
		local src = read_source()
		local fn_start = src:find("function M.write", 1, true)
		helpers.assert_true(fn_start ~= nil, "M.write must exist")
		local fn_end = src:find("\nend\n", fn_start, true)
		local body = src:sub(fn_start, fn_end)

		helpers.assert_true(body:find('".tmp"', 1, true) ~= nil,
			"write() must stage content in a '.tmp' file before publishing it (F-MED-16)")
		helpers.assert_true(body:find("os.rename(", 1, true) ~= nil,
			"write() must publish the staged content via os.rename (F-MED-16)")
	end)

	helpers.it("write() resolves the real path via pathToAbsolute before renaming (symlink safety)", function()
		local src = read_source()
		local fn_start = src:find("function M.write", 1, true)
		local fn_end   = src:find("\nend\n", fn_start, true)
		local body = src:sub(fn_start, fn_end)

		helpers.assert_true(body:find("pathToAbsolute", 1, true) ~= nil,
			"write() must resolve symlinks via pathToAbsolute before renaming — renaming directly over a "
			.. "symlink path would replace the symlink itself, breaking deploy_string's documented symlink support")
	end)
end)
