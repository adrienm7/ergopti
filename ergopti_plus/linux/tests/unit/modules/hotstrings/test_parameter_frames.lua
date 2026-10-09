--- tests/unit/modules/hotstrings/test_parameter_frames.lua

--- Exercises the actual complete parameter providers, canonical declaration
--- refusal and live translations without delivering native mutation callbacks.
local helpers = require("tests.helpers")

local function with_frames(body, paused, mutate)
	local saved = {}; for name, value in pairs(package.loaded) do saved[name] = value end
	local ok, err = pcall(function()
		local i18n = require("infra.i18n")
		local renderer = assert(require("menu.renderer").new({ platform = "linux",
			manifest_path = function() return require("infra.paths").shared("modules/menu/menu_manifest.json") end,
			json_decode = require("json").decode, i18n = i18n, logger = require("logger.shim"),
		}))
		local root = renderer.get_root()
		if mutate then mutate(root) end
		package.loaded["infra.manifest_menu"] = renderer
		local context = { paused = paused == true, config = {
			get_groups = function() return {} end, get_categories = function() return {} end,
			language_packs = function() return {} end,
			resolve = function() return { delay = 0.75, color = "#1e88e5", has_override = false } end,
			get_global_delay = function() return 0.75 end,
			has_global_delay_override = function() return false end,
		}, on_toggle_pause = function() end, on_quit = function() end }
		context.is_paused = function() return context.paused end
		local rows = helpers.load_module("ui.menu.menu_builder").build(context)
		body(rows, i18n, context)
	end)
	for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved) do package.loaded[name] = value end
	if not ok then error(err, 0) end
end

local function find(rows, title)
	for _, row in ipairs(rows or {}) do
		if row.title == title then return row end
		local nested = find(row.menu, title); if nested then return nested end
	end
end

helpers.describe("complete shared Hotstrings parameter frames", function()
	helpers.it("preserves Linux delay and preview orders without Mac-only quick actions", function()
		with_frames(function(rows, i18n)
			local delays = assert(find(rows, i18n.get("menu.hotstrings.delays_colors"))).menu
			helpers.assert_eq(#delays, 5)
			helpers.assert_eq(delays[1].title, i18n.get("menu.hotstrings.config_item"))
			helpers.assert_eq(delays[2].title, "-")
			for index, key in ipairs({ "tooltip_default", "delay_magic_key", "delay_autocorrection" }) do
				local caption = i18n.get("menu.hotstrings." .. key)
				helpers.assert_eq(delays[index + 2].title:sub(1, #caption), caption)
				helpers.assert_true(delays[index + 2].title:find("750 ms", 1, true) ~= nil)
			end
			local preview = assert(find(rows, i18n.get("menu.hotstrings.preview_bubbles"))).menu
			helpers.assert_eq(#preview, 5); helpers.assert_eq(preview[4].title, "-")
			for index, key in ipairs({ "tooltip_magic", "tooltip_autocorrect", "tooltip_ai" }) do
				helpers.assert_eq(preview[index].title, i18n.get("menu.hotstrings." .. key))
			end
			helpers.assert_eq(preview[5].title, i18n.get("menu.hotstrings.tooltip_colored"))
			local word = assert(find(rows, i18n.get("menu.hotstrings.word_expanders"))).menu
			helpers.assert_eq(word[4].title, "-")
			helpers.assert_eq(word[#word - 1].title, "-")
			helpers.assert_eq(word[#word].title, i18n.get("menu.hotstrings.add_delimiter"))
		end)
	end)
	helpers.it("keeps retained Linux parameter parents while bulk commands refuse a held pause", function()
		with_frames(function(rows, i18n, context)
			context.paused = true
			for _, key in ipairs({ "delays_colors", "preview_bubbles", "word_expanders" }) do
				local parent = assert(find(rows, i18n.get("menu.hotstrings." .. key)))
				helpers.assert_eq(parent.disabled == true, false)
			end
			local word = assert(find(rows, i18n.get("menu.hotstrings.word_expanders"))).menu
			helpers.assert_eq(word[1].disabled == true, false)
			helpers.assert_eq(word[1].fn(), false)
		end)
	end)
	helpers.it("reads the declared quick caption map in the actual native provider", function()
		with_frames(function(rows, i18n)
			local delays = assert(find(rows, i18n.get("menu.hotstrings.delays_colors"))).menu
			for _, index in ipairs({ 3, 4, 5 }) do
				local caption = i18n.get("button.ok")
				helpers.assert_eq(delays[index].title:sub(1, #caption), caption)
			end
		end, false, function(root)
			for key in pairs(root.hotstrings_delay_captions) do root.hotstrings_delay_captions[key] = "button.ok" end
		end)
	end)
	for _, mode in ipairs({ "missing", "unknown", "wrong_type", "wrong_case" }) do
		helpers.it("withdraws the quick-delay parent for " .. mode .. " caption data", function()
			with_frames(function(rows, i18n)
				helpers.assert_eq(find(rows, i18n.get("menu.hotstrings.delays_colors")), nil)
			end, false, function(root)
				if mode == "missing" then root.hotstrings_delay_captions.default = nil
				elseif mode == "unknown" then root.hotstrings_delay_captions.foreign = "button.ok"
				elseif mode == "wrong_case" then
					root.hotstrings_delay_captions.Default = root.hotstrings_delay_captions.default
					root.hotstrings_delay_captions.default = nil
				else root.hotstrings_delay_captions.default = false end
			end)
		end)
	end
	helpers.it("refuses an unbound delay child instead of accepting foreign provider data", function()
		with_frames(function(rows, i18n)
			helpers.assert_eq(find(rows, i18n.get("menu.hotstrings.delays_colors")), nil)
		end, false, function(root) root.hotstrings_delays_frame[1].id = "unrelated_provider" end)
	end)
	for _, key in ipairs({ "word_expander", "preview", "delays" }) do
		helpers.it("withdraws only the absent " .. key .. " frame parent", function()
			with_frames(function(rows, i18n)
				local label = key == "word_expander" and "word_expanders"
					or (key == "preview" and "preview_bubbles" or "delays_colors")
				helpers.assert_eq(find(rows, i18n.get("menu.hotstrings." .. label)), nil)
			end, false, function(root) root["hotstrings_" .. key .. "_frame"] = nil end)
		end)
	end
end)

return true
