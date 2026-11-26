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
local IsolationSyntax = require("tests.support.karabiner_isolation.syntax")

helpers.describe("owned runtime uninstall: scope", function()
	helpers.it("names the very files and jobs the Lua owner and the installer declare", function()
		package.loaded["platform.remap.ke_paths"] = nil
		local owned = require("platform.remap.ke_paths").OWNED
		local launcher = helpers.driver_root() .. "/launcher/Sources/ErgoptiPlus/"
		-- The worker names its job labels through the generated identifier enum;
		-- compare the values that enum holds with the Lua owner's declaration.
		local identifiers = IsolationSyntax.generated_swift_identifiers(
			assert(SourceFile.read(launcher .. "Identifiers.generated.swift")))
		local source = IsolationSyntax.fold_generated_identifiers(
			assert(SourceFile.read(launcher .. "UninstallWorker.swift")), identifiers)
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
		helpers.assert_eq(recursive, 2, "exactly two recursive removals: the runtime directory and the install stages")
		helpers.assert_true(block:find("/bin/rm -rf '\\(runtimeDirectory)'", 1, true) ~= nil,
			"the recursive removal names the constant, never a computed path")
		-- The install's stale step (field report 2026-11-24) removes only the helper's copy stages: a loop
		-- over the constant UUID pattern in the owned folder, each entry a plain folder, never a computed path.
		helpers.assert_true(block:find("for task_stage in '\\(ownedFolder)'/\\(installStagePattern); do ", 1, true) ~= nil,
			"the stage loop names the owned folder and the stage pattern constants")
		helpers.assert_true(block:find('[ -d \\"$task_stage\\" ] && [ ! -L \\"$task_stage\\" ] || exit 77; '
			.. '/bin/rm -rf \\"$task_stage\\"', 1, true) ~= nil, "a stage is removed only when it is a plain folder")
		helpers.assert_true(block:find('installStagePattern = ".runtime-install-????????-????-????-????-????????????"', 1, true)
			~= nil, "the stage pattern is the helper's UUID stage, never the shell's own .runtime-installer- stage")
	end)

	helpers.it("names the owned folder that holds the runtime directory", function()
		package.loaded["platform.remap.ke_paths"] = nil
		local owned = require("platform.remap.ke_paths").OWNED
		local source = assert(SourceFile.read(helpers.driver_root() .. "/launcher/Sources/ErgoptiPlus/UninstallWorker.swift"))
		local folder = assert(owned.RUNTIME_DIR:match("^(.+)/Runtime$"), "the runtime directory sits in the owned folder")
		helpers.assert_true(source:find('ownedFolder = "' .. folder .. '"', 1, true) ~= nil)
	end)
end)
