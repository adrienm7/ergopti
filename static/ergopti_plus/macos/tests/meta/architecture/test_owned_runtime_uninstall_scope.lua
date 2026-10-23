--- tests/meta/architecture/test_owned_runtime_uninstall_scope.lua

--- ==============================================================================
--- MODULE: Owned Runtime Uninstall Scope Guard
--- DESCRIPTION:
--- The application uninstall retires the owned Karabiner runtime (ADR 011) with
--- one administrator command. This guard keeps that command to exactly what the
--- Lua owner and installer declare, so uninstalling Ergopti can never touch the
--- official Karabiner-Elements it may sit next to.
---
--- ROOT CAUSE ENCODED: the uninstall runs as root, and its paths were a second
--- spelling of ke_paths.lua's. A drifted or widened path there would remove files
--- nobody owns.
--- ==============================================================================

local helpers = require("tests.helpers")
local SourceFile = require("tests.support.source_file")

helpers.describe("owned runtime uninstall: scope", function()
	helpers.it("names the very files and jobs the Lua owner and the installer declare", function()
		package.loaded["platform.remap.ke_paths"] = nil
		local owned = require("platform.remap.ke_paths").OWNED
		local source = assert(SourceFile.read(helpers.driver_root() .. "/launcher/Sources/ErgoptiPlus/UninstallWorker.swift"))
		helpers.assert_true(source:find('runtimeDirectory = "' .. owned.RUNTIME_DIR .. '"', 1, true) ~= nil)
		helpers.assert_true(source:find('("' .. owned.CORE_LABEL .. '", "' .. owned.CORE_JOB_FILE .. '")', 1, true) ~= nil)
		helpers.assert_true(source:find('("' .. owned.VIRTUAL_HID_LABEL .. '", "/Library/LaunchDaemons/' .. owned.VIRTUAL_HID_LABEL
			.. '.plist")', 1, true) ~= nil)
	end)

	helpers.it("never mentions the official Karabiner or a path outside the owned namespace", function()
		local source = assert(SourceFile.read(helpers.driver_root() .. "/launcher/Sources/ErgoptiPlus/UninstallWorker.swift"))
		local block = assert(source:match("enum OwnedRuntimeUninstall %b{}"), "the owned uninstall block")
		helpers.assert_true(block:find("org.pqrs", 1, true) == nil)
		helpers.assert_true(block:find("Karabiner", 1, true) == nil)
		local _, recursive = block:gsub("/bin/rm %-rf", "")
		helpers.assert_eq(recursive, 1, "exactly one recursive removal: the runtime directory")
		helpers.assert_true(block:find("/bin/rm -rf '\\(runtimeDirectory)'", 1, true) ~= nil,
			"the recursive removal names the constant, never a computed path")
	end)
end)
