--- tests/meta/regressions/test_hammerspoon_icon_hidden.lua

--- ==============================================================================
--- MODULE: Regression — the Hammerspoon hammer stays out of the menu bar
---         (hammerspoon-icon-hidden)
--- DESCRIPTION:
--- The launcher hides the embedded runtime's own menu bar and Dock icons by
--- setting Hammerspoon's preferences before it starts. It wrote
--- MJShowMenuIconOnLaunch and MJShowDockIconOnLaunch, which Hammerspoon never
--- reads, so the hammer showed beside ErgoptiPlus' icon (field report
--- 2026-11-23). Hammerspoon 1.1.1 reads MJShowMenuIconKey and MJShowDockIconKey
--- (variables.h); the build pins that version, so a version change must check
--- these names again. The engine also showed the hammer as its own icon in its
--- dialogs; the build now gives it ErgoptiPlus' icon.
--- ==============================================================================

local helpers = require("tests.helpers")
local SourceFile = require("tests.support.source_file")

helpers.describe("the Hammerspoon hammer stays out of the menu bar (hammerspoon-icon-hidden)", function()
	local root = helpers.driver_root()
	local launcher = root .. "/launcher/Sources/ErgoptiPlus/"

	helpers.it("sets the preference keys Hammerspoon reads, before the runtime starts", function()
		local constants = assert(SourceFile.read(launcher .. "LauncherConstants.swift"))
		helpers.assert_true(constants:find('let kHammerspoonHiddenIconKeys = ["MJShowMenuIconKey", "MJShowDockIconKey"]', 1, true) ~= nil,
			"the hidden icon keys must be Hammerspoon's own")
		local main = assert(SourceFile.read(launcher .. "main.swift"))
		helpers.assert_true(main:find("for key in kHammerspoonHiddenIconKeys {", 1, true) ~= nil,
			"the runtime's preferences must set every hidden icon key")
		helpers.assert_true(main:find("OnLaunch\"", 1, true) == nil, "no key Hammerspoon never reads")
	end)

	helpers.it("gives the embedded engine ErgoptiPlus' icon instead of the hammer", function()
		local build = assert(SourceFile.read(root .. "/../../../tools/build/build_macos_app.sh"))
		local icon = assert(build:match("\nbuild_icon%(%) {(.-)\n}"), "the build's icon step")
		helpers.assert_true(icon:find('cp "$APP_PATH/Contents/Resources/ErgoptiPlus.icns" "$hs_app/Contents/Resources/ErgoptiPlus.icns"', 1, true) ~= nil,
			"the engine's bundle must hold ErgoptiPlus' icon")
		helpers.assert_true(icon:find('plutil -replace CFBundleIconFile -string "ErgoptiPlus" "$hs_plist"', 1, true) ~= nil,
			"the engine's Info.plist must name ErgoptiPlus' icon")
		helpers.assert_true(icon:find('plutil -remove CFBundleIconName "$hs_plist"', 1, true) ~= nil,
			"Hammerspoon's asset catalogue icon must not win over it")
		local main = assert(build:match("\nmain%(%) {(.-)\n}"), "the build's main")
		local assembled, iconed, signed = main:find("assemble_app", 1, true), main:find("build_icon", 1, true),
			main:find("codesign_app", 1, true)
		helpers.assert_true(assembled and iconed and signed and assembled < iconed and iconed < signed,
			"the icon goes into the embedded engine after it is assembled and before it is signed")
	end)

	helpers.it("names keys checked against the Hammerspoon version the build pins", function()
		local build = assert(SourceFile.read(root .. "/../../../tools/build/build_macos_app.sh"))
		helpers.assert_true(build:find('HAMMERSPOON_VERSION="${HAMMERSPOON_VERSION:-1.1.1}"', 1, true) ~= nil,
			"a new Hammerspoon version must have its menu and Dock icon keys checked again")
	end)
end)
