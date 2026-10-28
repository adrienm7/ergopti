--- tests/unit/modules/hotstrings/preview/test_preview_autocorrect_toggle.lua

--- ==============================================================================
--- MODULE: Preview Autocorrect Toggle
--- DESCRIPTION:
--- Drives hotstrings.preview_autocorrect_enabled from the stored preference
--- through preview_settings.apply into the preview gate: off hides only the
--- autocorrection bubble, the ★ bubble keeps showing, and on restores it.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")

local saved = {}
for _, name in ipairs({ "adapters.graphics_renderer", "adapters.timer_scheduler", "infra.hotstring_preferences",
	"modules.hotstrings.preview_settings", "ui.tooltip.preview" }) do saved[name] = package.loaded[name] end

local shown = 0
package.loaded["adapters.graphics_renderer"] = {
	is_available = function() return true end,
	show = function() shown = shown + 1; return true end,
	hide = function() end,
	is_visible = function() return shown > 0 end,
	destroy = function() end,
}
package.loaded["adapters.timer_scheduler"] = Fakes.timer_scheduler()
local stored = {}
package.loaded["infra.hotstring_preferences"] = {
	get = function(path)
		if stored[path] ~= nil then return stored[path] end
		return require("infra.manifest_reader").default_for(path)
	end,
	set = function(path, value) stored[path] = value; return true end,
	is_explicit = function(path) return stored[path] ~= nil end,
}
package.loaded["modules.hotstrings.preview_settings"] = nil
package.loaded["ui.tooltip.preview"] = nil
local Settings = require("modules.hotstrings.preview_settings")
local Preview = require("ui.tooltip.preview")

local CANDIDATES = { { trigger = "btw", replacement = "by the way", group = "rolls", fires = true } }
Preview.init({
	style = { positioning = { window_bottom_inset = 0 } },
	config = { resolve = function() return { show_tooltip = true, delay = 0.5, color = "#1e88e5" } end },
})

helpers.describe("preview_autocorrect_enabled reaches the preview gate (linux-preview-autocorrect)", function()
	helpers.it("the shipped default shows the autocorrection bubble", function()
		helpers.assert_eq(Settings.default("autocorrect"), true)
		Settings.apply(Preview)
		helpers.assert_eq(Preview.show(CANDIDATES, "autocorrect"), true)
	end)

	helpers.it("off hides only the autocorrection bubble", function()
		helpers.assert_eq(Settings.set("autocorrect", false), true)
		helpers.assert_eq(stored["hotstrings.preview_autocorrect_enabled"], false)
		Settings.apply(Preview)
		shown = 0
		helpers.assert_eq(Preview.show(CANDIDATES, "autocorrect"), false)
		helpers.assert_eq(shown, 0)
		helpers.assert_eq(Preview.show(CANDIDATES, "star"), true, "the ★ toggle is independent")
	end)

	helpers.it("on restores the autocorrection bubble", function()
		helpers.assert_eq(Settings.toggle("autocorrect"), true)
		Settings.apply(Preview)
		helpers.assert_eq(Preview.show(CANDIDATES, "autocorrect"), true)
	end)
end)

for name, value in pairs(saved) do package.loaded[name] = value end
