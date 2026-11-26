--- tests/unit/modules/updater/install/test_install_staged_layout.lua

--- ==============================================================================
--- MODULE: A Staged Release Is Admitted Whatever Its Folder Layout
--- DESCRIPTION:
--- The staged archive is another version than the running updater. Probing it
--- with this version's locale path refused every release built before the
--- structure move (« staged archive is missing the shared Lua tree », Linux E2E
--- updater, run 43457007087). The build stamp marks the shared root in every
--- layout, so the installer finds the tree by it.
--- ==============================================================================

local helpers = require("tests.helpers")

local WORK = "/fixture/lib/.ergopti-update.abc123"
local STAMP = "commit=" .. string.rep("a", 40) .. "\nversion=4.0.0\n"

--- Installer operations over an exact set of staged files; all writes succeed.
--- @param files table Set of staged file paths.
--- @return table ops
local function ops_over(files)
	return {
		validate_archive = function() return true end,
		make_work_dir = function() return WORK end,
		extract = function() return true end,
		is_file = function(path) return files[path] == true end,
		is_dir = function() return true end,
		read = function(path) return files[path] and STAMP or nil end,
		mkdir = function() return true end,
		move = function() return true end,
		record_ownership = function() return true end,
		backup_is_owned = function() return true, "1:2" end,
		exists = function() return false end,
		remove_tree = function() return true end,
		remove_file = function() return true end,
		smoke = function() return true end,
		compile_bytecode = function() return true end,
	}
end

--- The driver files every layout ships, plus the given shared files.
--- @param shared table List of staged shared-tree paths relative to WORK.
--- @return table files
local function staged(shared)
	local files = {
		[WORK .. "/linux/ergopti_hotstrings.lua"] = true,
		[WORK .. "/linux/infra/version.lua"] = true,
		[WORK .. "/bin/ergopti-hotstrings"] = true,
		[WORK .. "/install.sh"] = true,
	}
	for _, path in ipairs(shared) do files[WORK .. "/" .. path] = true end
	return files
end

local function install(files)
	local installer = helpers.load_module("modules.updater.installer")
	return installer.install({
		archive_path = "/fixture/download.tar.gz",
		expected_version = "v4.0.0",
		context = { kind = "standalone", install_root = "/fixture/lib/ergopti", parent = "/fixture/lib",
			wrapper = "/fixture/bin/ergopti" },
		ops = ops_over(files),
	})
end

helpers.describe("updater: a staged release's shared tree", function()
	helpers.it("admits a release built before the folder move (old locale path)", function()
		local installed, detail = install(staged({ "_shared/build_stamp.txt", "_shared/data/locales/en.json" }))
		helpers.assert_true(installed, tostring(detail))
	end)

	helpers.it("admits a package-style child shared tree", function()
		local installer = helpers.load_module("modules.updater.installer")
		local files = staged({ "linux/_shared/build_stamp.txt" })
		helpers.assert_eq(installer._staged_shared_root(WORK, ops_over(files)), WORK .. "/linux/_shared")
	end)

	helpers.it("still refuses a staged tree with no stamped shared root", function()
		local installed, detail = install(staged({ "_shared/core/i18n/data/locales/en.json" }))
		helpers.assert_true(installed == false, "a tree without a stamped shared root is refused")
		helpers.assert_eq(detail, "staged archive is missing the shared Lua tree")
	end)
end)
