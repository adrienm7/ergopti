--- tests/unit/updater/engine/install/test_compiles_bytecode.lua

--- ==============================================================================
--- MODULE: An Update Compiles The Activated Tree's Bytecode Package
--- DESCRIPTION:
--- The maintainer's bytecode contract (2026-11-11): the updater compiles the
--- installed tree with the target's luajit, after the new root is activated and
--- its ownership verified, so the chunks carry the final path and the receipt
--- verifier never meets a derived tree it may predate. A failed compile costs
--- boot time only: the update still succeeds and says what was skipped.
--- ==============================================================================

local helpers = require("tests.helpers")

local ROOT = "/fixture/lib/ergopti"

--- An installer over operations that all succeed, recording their order.
--- @param compiled boolean What the compile operation answers.
--- @return table installer, table calls
local function load(compiled)
	local installer = helpers.load_module("updater.engine.installer")
	local calls = {}
	local function note(name, value) calls[#calls + 1] = name; return value end
	local ops = {
		validate_archive = function() return note("validate", true) end,
		make_work_dir = function() return note("work", "/fixture/lib/.ergopti-update.abc123") end,
		extract = function() return note("extract", true) end,
		is_file = function() return true end,
		is_dir = function() return true end,
		read = function() return "commit=" .. string.rep("a", 40) .. "\nversion=4.0.0\n" end,
		mkdir = function() return true end,
		move = function(source, destination) return note("move " .. source .. " -> " .. destination, true) end,
		record_ownership = function() return note("receipt", true) end,
		backup_is_owned = function() return true, "1:2" end,
		exists = function() return false end,
		remove_tree = function() return true end,
		remove_file = function() return true end,
		smoke = function() return note("smoke", true) end,
		compile_bytecode = function(root) return note("compile " .. root, compiled) end,
	}
	return installer, calls, ops
end

local function install(installer, ops)
	return installer.install({
		archive_path = "/fixture/download.tar.gz",
		expected_version = "v4.0.0",
		context = { kind = "standalone", install_root = ROOT, parent = "/fixture/lib", wrapper = "/fixture/bin/ergopti" },
		ops = ops,
	})
end

local function index_of(calls, prefix)
	for index, name in ipairs(calls) do
		if name:sub(1, #prefix) == prefix then return index end
	end
	return nil
end

helpers.describe("updater: the activated tree's bytecode package", function()
	helpers.it("compiles the activated root once, after the smoke test of the new wrapper", function()
		local installer, calls, ops = load(true)
		local installed, detail = install(installer, ops)
		helpers.assert_true(installed, tostring(detail))
		helpers.assert_nil(detail)
		local compile, smoke = index_of(calls, "compile "), index_of(calls, "smoke")
		helpers.assert_eq(calls[compile], "compile " .. ROOT, "the final root, never the staging tree")
		helpers.assert_true(smoke ~= nil and compile > smoke, "the package follows the verified activation")
		local compiles = 0
		for _, name in ipairs(calls) do if name:sub(1, 8) == "compile " then compiles = compiles + 1 end end
		helpers.assert_eq(compiles, 1, "one compile per update")
	end)

	helpers.it("keeps the update and names what was skipped when the compile fails", function()
		local installer, _, ops = load(false)
		local installed, detail = install(installer, ops)
		helpers.assert_true(installed, "a missing package costs boot time, never the update")
		helpers.assert_eq(detail, "update installed but its bytecode package was not compiled")
	end)

	helpers.it("compiles nothing when the new wrapper fails its smoke test", function()
		local installer, calls, ops = load(true)
		ops.smoke = function() calls[#calls + 1] = "smoke"; return false end
		local installed = install(installer, ops)
		helpers.assert_eq(installed, false)
		helpers.assert_nil(index_of(calls, "compile "), "a rolled-back release is never compiled")
	end)
end)
