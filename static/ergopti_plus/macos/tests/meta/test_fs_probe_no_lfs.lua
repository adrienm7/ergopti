--- tests/meta/test_fs_probe_no_lfs.lua

--- ==============================================================================
--- MODULE: Regression — hs.fs stub filesystem fidelity
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
---
--- The optional primitives used by atomic publication must also delegate to
--- LuaFileSystem with their production argument order and unmodified results.
--- Constant success/nil stubs would make ownership and symlink tests certify
--- behavior that the headless host never exercised.
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

	helpers.it("hs.fs.rmdir removes an empty temp directory without interpolating its pathname", function()
		local directory = os.tmpname():gsub("\\", "/")
		os.remove(directory)
		local created, create_err = hs.fs.mkdir(directory)
		helpers.assert_true(created == true, "fixture directory must be created: " .. tostring(create_err))
		local removed, remove_err = hs.fs.rmdir(directory)
		helpers.assert_true(removed == true, "empty-directory removal must succeed: " .. tostring(remove_err))
		helpers.assert_nil(hs.fs.__probe_no_lfs(directory), "rmdir success must mean the directory is absent")
	end)
end)





-- ==============================================
-- ==============================================
-- ======= 2/ Optional primitive fidelity =======
-- ==============================================
-- ==============================================

helpers.describe("hs.fs optional LuaFileSystem primitives are faithful", function()
	helpers.it("mirrors Hammerspoon's symlinkAttributes target wrapper and raw return arity", function()
		local calls = { symlinkattributes = {}, path_to_absolute = {} }
		local full_attributes = { mode = "link", size = 17 }
		local ambiguous_attributes = { mode = "link", size = 23 }
		local fake_lfs = {
			symlinkattributes = function(path, attribute)
				calls.symlinkattributes[#calls.symlinkattributes + 1] = { path, attribute }
				if path == "/missing" then return nil, "missing-marker" end
				if path == "/ambiguous" then return ambiguous_attributes, "second-marker" end
				if attribute ~= nil then return "raw-" .. attribute end
				return full_attributes
			end,
		}

		local previous_lfs = package.loaded["lfs"]
		local previous_stub = package.loaded["tests.stubs.hs"]
		package.loaded["lfs"] = fake_lfs
		package.loaded["tests.stubs.hs"] = nil
		local call_ok, result = xpcall(function()
			local isolated_hs = require("tests.stubs.hs")
			isolated_hs.fs.pathToAbsolute = function(path)
				calls.path_to_absolute[#calls.path_to_absolute + 1] = path
				return "/resolved" .. path
			end
			local attributes, attributes_err = isolated_hs.fs.symlinkAttributes("/link")
			local mode, mode_err = isolated_hs.fs.symlinkAttributes("/link", "mode")
			local target, target_err = isolated_hs.fs.symlinkAttributes("/link", "target")
			local missing, missing_err = isolated_hs.fs.symlinkAttributes("/missing")
			local ambiguous, ambiguous_err = isolated_hs.fs.symlinkAttributes("/ambiguous")
			return {
				attributes = attributes,
				attributes_err = attributes_err,
				mode = mode,
				mode_err = mode_err,
				target = target,
				target_err = target_err,
				missing = missing,
				missing_err = missing_err,
				ambiguous = ambiguous,
				ambiguous_err = ambiguous_err,
			}
		end, debug.traceback)
		package.loaded["tests.stubs.hs"] = previous_stub
		package.loaded["lfs"] = previous_lfs
		if not call_ok then error(result) end

		helpers.assert_eq(result.attributes, full_attributes)
		helpers.assert_eq(result.attributes.target, "/resolved/link",
			"the one-table result must carry Hammerspoon's resolved target")
		helpers.assert_nil(result.attributes_err, "a one-result lstat must stay one-result")
		helpers.assert_eq(result.mode, "raw-mode", "non-target scalar attributes must delegate to lfs")
		helpers.assert_nil(result.mode_err, "single-attribute return arity must stay intact")
		helpers.assert_eq(result.target, "/resolved/link", "the target scalar must bypass raw lstat")
		helpers.assert_nil(result.target_err)
		helpers.assert_nil(result.missing, "nil,error from raw lstat must remain nil,error")
		helpers.assert_eq(result.missing_err, "missing-marker")
		helpers.assert_eq(result.ambiguous, ambiguous_attributes)
		helpers.assert_eq(result.ambiguous_err, "second-marker")
		helpers.assert_nil(result.ambiguous.target,
			"a table accompanied by a second return value must not be rewritten")
		helpers.assert_eq(#calls.symlinkattributes, 4,
			"the target scalar is resolved without consulting raw lstat")
		helpers.assert_eq(#calls.path_to_absolute, 2,
			"only the one-table result and target scalar resolve the path")
	end)

	helpers.it("forwards symlinkAttributes, link, and rmdir arguments and results", function()
		local calls = {}
		local symlink_result = { mode = "link", target = "/resolved/target" }
		local fake_lfs = {
			symlinkattributes = function(path, attribute)
				calls.symlinkattributes = { path, attribute }
				return symlink_result, "symlink-marker"
			end,
			link = function(source_path, destination_path, is_symlink)
				calls.link = { source_path, destination_path, is_symlink }
				return true, "link-marker"
			end,
			rmdir = function(path)
				calls.rmdir = { path }
				return true, "rmdir-marker"
			end,
		}

		local previous_lfs = package.loaded["lfs"]
		local previous_stub = package.loaded["tests.stubs.hs"]
		package.loaded["lfs"] = fake_lfs
		package.loaded["tests.stubs.hs"] = nil
		local call_ok, result = xpcall(function()
			local isolated_hs = require("tests.stubs.hs")
			local attributes, attributes_err = isolated_hs.fs.symlinkAttributes("/link", "mode")
			local linked, link_err = isolated_hs.fs.link("/source", "/destination", true)
			local removed, rmdir_err = isolated_hs.fs.rmdir("/empty-directory")
			return {
				attributes = attributes,
				attributes_err = attributes_err,
				linked = linked,
				link_err = link_err,
				removed = removed,
				rmdir_err = rmdir_err,
			}
		end, debug.traceback)
		package.loaded["tests.stubs.hs"] = previous_stub
		package.loaded["lfs"] = previous_lfs
		if not call_ok then error(result) end

		helpers.assert_type(calls.symlinkattributes, "table", "symlinkAttributes must reach fake lfs")
		helpers.assert_eq(calls.symlinkattributes[1], "/link")
		helpers.assert_eq(calls.symlinkattributes[2], "mode")
		helpers.assert_eq(result.attributes, symlink_result)
		helpers.assert_eq(result.attributes_err, "symlink-marker")
		helpers.assert_type(calls.link, "table", "link must reach fake lfs")
		helpers.assert_eq(calls.link[1], "/source")
		helpers.assert_eq(calls.link[2], "/destination")
		helpers.assert_eq(calls.link[3], true)
		helpers.assert_eq(result.linked, true)
		helpers.assert_eq(result.link_err, "link-marker")
		helpers.assert_type(calls.rmdir, "table", "rmdir must reach fake lfs")
		helpers.assert_eq(calls.rmdir[1], "/empty-directory")
		helpers.assert_eq(result.removed, true)
		helpers.assert_eq(result.rmdir_err, "rmdir-marker")
	end)
end)
