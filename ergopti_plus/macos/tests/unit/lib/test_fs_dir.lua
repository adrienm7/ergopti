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
		helpers.assert_true(type(fs_dir.try_entries) == "function", "must expose try_entries()")
		hs.fs.__set_entries("/fake/fsdir", { "a.toml", "b.toml" })
		local got = fs_dir.entries("/fake/fsdir")
		local proven, listed, list_err = fs_dir.try_entries("/fake/fsdir")
		hs.fs.__reset_entries()
		helpers.assert_eq(got, { "a.toml", "b.toml" }, "must list the registered entries in order")
		helpers.assert_eq(proven, got, "try_entries must return the same complete listing")
		helpers.assert_eq(listed, true, "try_entries must mark a complete listing authoritative")
		helpers.assert_nil(list_err, "a complete listing must not carry an error")
	end)

	helpers.it("returns an empty table for nil / non-string input", function()
		local fs_dir = require("infra.fs_dir")
		helpers.assert_eq(fs_dir.entries(nil), {}, "nil dir -> empty list")
		helpers.assert_eq(fs_dir.entries(""), {}, "empty-string dir -> empty list")
		local _, nil_listed = fs_dir.try_entries(nil)
		local _, empty_listed = fs_dir.try_entries("")
		helpers.assert_eq(nil_listed, false, "nil is not an authoritative empty directory")
		helpers.assert_eq(empty_listed, false, "an empty path is not an authoritative empty directory")
	end)

	helpers.it("survives a throwing hs.fs.dir (returns empty, never propagates)", function()
		local fs_dir = require("infra.fs_dir")
		local prev = hs.fs.dir
		hs.fs.dir = function(_) error("permission denied") end
		local ok, got = pcall(fs_dir.entries, "/inaccessible")
		local proven, listed, list_err = fs_dir.try_entries("/inaccessible")
		hs.fs.dir = prev
		helpers.assert_true(ok, "entries must catch the throw, not propagate it")
		helpers.assert_eq(got, {}, "a throwing hs.fs.dir must yield an empty list")
		helpers.assert_eq(proven, {}, "try_entries must keep the legacy empty-list fallback")
		helpers.assert_eq(listed, false, "an unreadable directory is not authoritative evidence of absence")
		helpers.assert_true(type(list_err) == "string" and list_err:find("permission denied", 1, true) ~= nil,
			"try_entries must preserve the enumeration failure for its caller")
	end)
end)
