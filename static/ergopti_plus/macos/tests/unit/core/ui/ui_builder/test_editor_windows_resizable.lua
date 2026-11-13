--- tests/unit/core/ui/ui_builder/test_editor_windows_resizable.lua

--- ==============================================================================
--- MODULE: Editor Windows Are Resizable
--- DESCRIPTION:
--- Windows creates every page window resizable (webview_utils.ahk _NewWindow
--- and each editor's own Gui, « +Resize »), and Linux every GTK window. On
--- macOS the action picker, prompt editor, personal information editor, paths
--- editor and onboarding windows were created without the resizable mask, so
--- they could not be enlarged (WVH-002). This file fails when one of them loses
--- it again. hs.webview offers no minimum-size constraint, so the manifest
--- minimum is not applied on macOS.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Each window owner and the mask expression it builds its window with.
local OWNERS = {
	["ui.action_picker"]        = '{ "titled", "closable", "resizable", "utility" }',
	["ai.ui.prompt_editor"]        = '{"titled", "closable", "resizable", "utility"}',
	["hotstrings.ui.personal_info_editor"] = '(masks["titled"] or 1) + (masks["closable"] or 2) + (masks["resizable"] or 8)',
	["settings.ui.menu.paths"]      = '(masks["titled"] or 1) + (masks["closable"] or 2) + (masks["resizable"] or 8)',
	["onboarding.ui"]           = '(masks["titled"] or 1) + (masks["closable"] or 2) + (masks["resizable"] or 8)',
}

helpers.describe("macOS editor windows are resizable", function()
	helpers.it("(wvh-002-resizable-windows) every editor window carries the resizable mask", function()
		for module, mask in pairs(OWNERS) do
			local source = assert(helpers.read_module_source(module), module .. " source")
			helpers.assert_contains(source, mask, module .. " builds a resizable window")
		end
	end)
end)
