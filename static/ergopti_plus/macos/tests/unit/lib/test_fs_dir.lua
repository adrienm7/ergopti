--- tests/unit/lib/test_fs_dir.lua

--- ==============================================================================
--- MODULE: infra/fs_dir runtime contract
--- DESCRIPTION:
--- fs_dir.entries is the blessed hs.fs.dir wrapper extracted from init.lua and the
--- hotstrings config window (both alias it as safe_dir_entries). The meta test
--- test_fs_dir_iterator_contract pins the SOURCE shape; this test pins the RUNTIME
--- behaviour + public API (`entries`) so the require-alias in init.lua's boot path
--- can never silently break.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("infra/fs_dir.entries — directory listing", function()
	helpers.it("exposes entries() and lists registered names in order", function()
		package.loaded["infra.fs_dir"] = nil
		local fs_dir = require("infra.fs_dir")
		helpers.assert_true(type(fs_dir.entries) == "function", "must expose entries()")
		hs.fs.__set_entries("/fake/fsdir", { "a.toml", "b.toml" })
		local got = fs_dir.entries("/fake/fsdir")
		hs.fs.__reset_entries()
		helpers.assert_eq(got, { "a.toml", "b.toml" }, "must list the registered entries in order")
	end)

	helpers.it("returns an empty table for nil / non-string input", function()
		local fs_dir = require("infra.fs_dir")
		helpers.assert_eq(fs_dir.entries(nil), {}, "nil dir -> empty list")
		helpers.assert_eq(fs_dir.entries(""), {}, "empty-string dir -> empty list")
	end)

	helpers.it("survives a throwing hs.fs.dir (returns empty, never propagates)", function()
		local fs_dir = require("infra.fs_dir")
		local prev = hs.fs.dir
		hs.fs.dir = function(_) error("permission denied") end
		local ok, got = pcall(fs_dir.entries, "/inaccessible")
		hs.fs.dir = prev
		helpers.assert_true(ok, "entries must catch the throw, not propagate it")
		helpers.assert_eq(got, {}, "a throwing hs.fs.dir must yield an empty list")
	end)
end)
