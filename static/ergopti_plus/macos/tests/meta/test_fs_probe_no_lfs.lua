--- tests/meta/test_fs_probe_no_lfs.lua

--- ==============================================================================
--- MODULE: Regression — hs.fs stub resolves directories without LuaFileSystem
--- DESCRIPTION:
--- When lfs is unavailable (a Windows dev box running the macOS Lua suite), the
--- hs.fs stub's directory-existence probe used os.rename(path, path). That is a
--- no-op SUCCESS for an existing entry on POSIX, but on Windows it FAILS because
--- the target already exists — so the probe returned nil for every real
--- directory, lib.paths.find_upward never located _shared/, and every test that
--- required a lib.timings-dependent module (modules.llm.api_mlx, the MLX menu)
--- died at load with "the _shared/ tree is unreachable". CI (macOS/Linux, lfs
--- present) never saw it.
---
--- ROOT CAUSE ENCODED:
--- The lfs-free probe must classify an existing directory as such on every OS.
--- It now accepts an os.rename failure whose errno is not ENOENT (2) — errno is
--- not localized, unlike the message string (which mattered on French Windows).
--- This test pins the probe directly, so a regression to the POSIX-only variant
--- fails here on any platform, not only on an lfs-less machine.
--- ==============================================================================

local helpers = require("tests.helpers")

-- This test file itself is a path that exists (a file), and its parent is a
-- directory that exists — both resolved without touching lfs or the shared tree.
local this_file = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
local this_dir = this_file:match("^(.*)[/\\][^/\\]+$") or "."

helpers.describe("hs.fs lfs-free probe classifies directory / file / missing", function()
	helpers.it("reports an existing directory as a directory", function()
		local attr = hs.fs.__probe_no_lfs(this_dir)
		helpers.assert_type(attr, "table", "an existing directory must probe to a table")
		helpers.assert_eq(attr.mode, "directory")
	end)

	helpers.it("reports an existing file as a file", function()
		local attr = hs.fs.__probe_no_lfs(this_file)
		helpers.assert_type(attr, "table", "an existing file must probe to a table")
		helpers.assert_eq(attr.mode, "file")
	end)

	helpers.it("reports a missing path as nil", function()
		helpers.assert_nil(hs.fs.__probe_no_lfs(this_dir .. "/__ergopti_no_such_entry__.xyz"))
	end)

	helpers.it("hs.fs.attributes still detects an existing directory (the _shared walk depends on it)", function()
		local attr = hs.fs.attributes(this_dir)
		helpers.assert_type(attr, "table", "attributes must detect an existing directory")
	end)
end)
