--- tests/unit/modules/llm/test_display_settings.lua

--- ==============================================================================
--- MODULE: Linux LLM Suggestion Presentation
--- DESCRIPTION:
--- Proves that display controls persist and that the headless suggestion model
--- turns parsed predictions into selectable, labelled renderer rows.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")

local held = {}

local function replace(name, value)
	if held[name] == nil then held[name] = package.loaded[name] or false end
	package.loaded[name] = value
end

local function restore()
	for name, value in pairs(held) do package.loaded[name] = value ~= false and value or nil end
	held = {}
end

local function load_settings(initial, writes_fail)
	local storage = Fakes.storage({ initial = initial, writes_fail = writes_fail })
	replace("adapters.storage", storage)
	package.loaded["modules.llm.display_settings"] = nil
	local settings = require("modules.llm.display_settings")
	settings._reset()
	return settings, storage
end

helpers.describe("LLM display settings: durable manifest-backed values", function()
	helpers.it("reads all four defaults without persisting them", function()
		local settings, storage = load_settings()
		local manifest = require("infra.manifest_reader")
		for _, name in ipairs({ "pred_indent", "show_info_bar", "streaming", "streaming_multi" }) do
			helpers.assert_eq(settings.get(name), manifest.default_for("llm.display." .. name))
			helpers.assert_true(not storage.has("llm.display." .. name))
		end
		restore()
	end)

	helpers.it("persists accepted changes and refuses invalid indentation", function()
		local settings, storage = load_settings()
		helpers.assert_true(settings.set("streaming", false))
		helpers.assert_eq(storage.get("llm.display.streaming"), false)
		helpers.assert_true(settings.set("pred_indent", -7))
		for _, invalid in ipairs({ -8, 8, 1.5, "2" }) do
			helpers.assert_eq(settings.set("pred_indent", invalid), false)
		end
		helpers.assert_eq(settings.get("pred_indent"), -7)
		restore()
	end)

	helpers.it("does not publish a write that failed", function()
		local settings = load_settings({ ["llm.display.show_info_bar"] = false }, true)
		helpers.assert_eq(settings.get("show_info_bar"), false)
		helpers.assert_eq(settings.set("show_info_bar", true), false)
		helpers.assert_eq(settings.get("show_info_bar"), false)
		restore()
	end)
end)

helpers.describe("LLM suggestion overlay: headless row decisions", function()
	helpers.it("labels alternatives, marks the selection, and appends optional info", function()
		replace("modules.llm.display_settings", {
			get = function(name)
				if name == "pred_indent" then return 2 end
				if name == "show_info_bar" then return true end
			end,
		})
		package.loaded["ui.llm.suggestion_overlay"] = nil
		local overlay = require("ui.llm.suggestion_overlay")
		local rows = overlay.build_rows({
			{ to_type = "first" },
			{ to_type = "second" },
		}, 2, {
			model = "qwen:4b",
			profile = "batch_advanced",
			validation_modifiers = { "alt" },
		})
		helpers.assert_eq(rows[1].text, "  first")
		helpers.assert_eq(rows[1].label, "Alt+1")
		helpers.assert_eq(rows[1].dimmed, true)
		helpers.assert_eq(rows[2].text, "second")
		helpers.assert_eq(rows[2].label, "Alt+2")
		helpers.assert_eq(rows[2].dimmed, false)
		helpers.assert_contains(rows[3].text, "qwen:4b")
		helpers.assert_contains(rows[3].text, "2/2")
		restore()
	end)

	helpers.it("redraws selection through an injected renderer", function()
		replace("modules.llm.display_settings", {
			get = function(name) return name == "pred_indent" and 0 or false end,
		})
		package.loaded["ui.llm.suggestion_overlay"] = nil
		local overlay = require("ui.llm.suggestion_overlay")
		local frames = {}
		local renderer = {
			show = function(rows) frames[#frames + 1] = rows; return true end,
			hide = function() end,
			is_visible = function() return true end,
		}
		helpers.assert_true(overlay.init({ style = {}, renderer = renderer }))
		helpers.assert_true(overlay.show({ { to_type = "one" }, { to_type = "two" } }, {}))
		helpers.assert_true(overlay.select(2))
		helpers.assert_eq(#frames, 2)
		helpers.assert_eq(frames[2][1].dimmed, true)
		helpers.assert_eq(frames[2][2].dimmed, false)
		overlay.hide()
		helpers.assert_eq(overlay.is_visible(), false)
		restore()
	end)
end)
