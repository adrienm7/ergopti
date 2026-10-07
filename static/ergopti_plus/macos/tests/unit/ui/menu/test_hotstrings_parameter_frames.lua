--- tests/unit/ui/menu/test_hotstrings_parameter_frames.lua

--- ==============================================================================
--- MODULE: Hotstrings Parameter Frames
--- DESCRIPTION:
--- Exercises complete native parameter providers with canonical frame data and
--- private category sources. Caption, order and refusal expectations are authored
--- independently of the declarations and preserve the original callback owners.
--- ==============================================================================

local helpers = require("tests.helpers")
local OutputFixture = require("tests.support.toml_output_fixture")

local function with_frame(body, paused)
	local translator = require("infra.i18n")
	return helpers.with_stub_scope({ "infra.logger", "infra.manifest_menu",
		"modules.hotstrings.hotstrings_config", "ui.menu.menu_hotstrings_management" }, function()
		helpers.load_with_stubs("infra.logger")
		package.loaded["infra.i18n"] = translator
		local renderer = assert(require("menu.renderer").new({ platform = "hs",
			manifest_path = function() return require("infra.paths").shared("modules/menu/menu_manifest.json") end,
			json_decode = require("adapters.json_codec").decode, i18n = translator,
			logger = require("infra.logger"),
		}))
		package.loaded["infra.manifest_menu"] = renderer
		return OutputFixture.with_output(function(path)
			local source = '[_meta]\ndelay = 0.25\n'
			local file = assert(io.open(path, "wb")); assert(file:write(source)); assert(file:close())
			return OutputFixture.with_output(function(override)
				local empty = assert(io.open(override, "wb")); assert(empty:write("")); assert(empty:close())
				local config = require("modules.hotstrings.hotstrings_config")
				assert(config.init({ override_path = override, toml_resolver = function() return path end }) == true)
				helpers.assert_eq(config.resolve("magickey", nil).delay, 0.25)
				local calls = { writes = 0, redraws = 0, notices = 0 }
				local context = {
					state = { expansion_delay = 0.1, delays = { llm_prediction = 0.3, dynamichotstrings = 0.4 },
						trigger_char = "★", terminator_states = {},
						preview_star_enabled = true, preview_autocorrect_enabled = false,
						preview_ai_enabled = true, preview_colored_tooltips = false,
						custom_terminators = { { key = "custom_test", char = "¤", consume = false } } },
					paused = paused == true,
					keymap = {
						DEFAULT_STATE = { expansion_delay = 0.1 },
						DELAYS_DEFAULT = { STAR_TRIGGER = 0.1, autocorrection = 0.1,
							llm_prediction = 0.3, dynamichotstrings = 0.4 },
						get_terminator_defs = function() return { { key = "first", label = "First" },
							{ type = "separator" }, { key = "second", label = "Second" } } end,
						is_terminator_enabled = function(key) return key == "first" or key == "custom_test" end,
					},
					applyTriggerChar = function(value) return value end,
					save_prefs = function() calls.writes = calls.writes + 1; return true end,
					updateMenu = function() calls.redraws = calls.redraws + 1 end,
					notify_feature = function() calls.notices = calls.notices + 1 end,
				}
				local owner = require("ui.menu.menu_hotstrings_management")
				local ok, err = pcall(body, { build = function() return owner.build_management(context) end,
					root = renderer.get_root(), context = context, captions = translator.get, calls = calls })
				local read = assert(io.open(path, "rb")); local actual = read:read("*a"); assert(read:close())
				helpers.assert_eq(actual, source, "presentation does not change the genuine category source")
				if not ok then error(err, 0) end
			end)
		end)
	end)
end

local function children(frame, key)
	for _, row in ipairs(frame.menu) do
		if row.title == key then return assert(row.menu) end
	end
	error("missing complete parameter parent: " .. key, 0)
end

helpers.describe("hotstrings parameter complete shared frames", function()
	helpers.it("retains Mac delay, preview and catalogue order with real category values", function()
		with_frame(function(f)
			local menu = assert(f.build())
			local delays = children(menu, f.captions("menu.hotstrings.delays_colors"))
			helpers.assert_eq(#delays, 8)
			local keys = { [1] = "menu.hotstrings.config_item", [3] = "menu.hotstrings.tooltip_ai_acceptance",
				[4] = "menu.hotstrings.tooltip_autocompletion", [5] = "menu.hotstrings.tooltip_default",
				[7] = "menu.hotstrings.delay_magic_key", [8] = "menu.hotstrings.delay_autocorrection" }
			for index, key in pairs(keys) do
				helpers.assert_eq(delays[index].title:sub(1, #f.captions(key)), f.captions(key))
			end
			helpers.assert_eq(delays[2].title, "-"); helpers.assert_eq(delays[6].title, "-")
			helpers.assert_true(delays[7].title:find("250 ms", 1, true) ~= nil)
			local preview = children(menu, f.captions("menu.hotstrings.preview_bubbles"))
			helpers.assert_eq(#preview, 5)
			for index, key in ipairs({ "tooltip_magic", "tooltip_autocorrect", "tooltip_ai" }) do
				helpers.assert_eq(preview[index].title, f.captions("menu.hotstrings." .. key))
			end
			helpers.assert_eq(preview[4].title, "-")
			helpers.assert_eq(preview[5].title, f.captions("menu.hotstrings.tooltip_colored"))
			helpers.assert_eq(preview[1].checked, true); helpers.assert_eq(preview[2].checked == true, false)
			local word = children(menu, f.captions("menu.hotstrings.word_expanders"))
			helpers.assert_eq(#word, 10)
			helpers.assert_eq(word[5].title, "First"); helpers.assert_eq(word[6].title, "-")
			helpers.assert_eq(word[7].title, "Second"); helpers.assert_eq(word[8].title, "-")
			helpers.assert_eq(word[9].menu[1].title, f.captions("menu.hotstrings.delete_delimiter"))
			helpers.assert_eq(word[10].title, f.captions("menu.hotstrings.add_delimiter"))
			helpers.assert_eq(f.calls.writes, 0); helpers.assert_eq(f.calls.redraws, 0)
		end)
	end)
	helpers.it("preserves disabled parents and inert paused preview deliveries", function()
		with_frame(function(f)
			local menu = assert(f.build())
			for _, row in ipairs(menu.menu) do
				if row.title == f.captions("menu.hotstrings.preview_bubbles")
					or row.title == f.captions("menu.hotstrings.word_expanders")
					or row.title == f.captions("menu.hotstrings.delays_colors") then helpers.assert_eq(row.disabled, true) end
			end
			local preview = children(menu, f.captions("menu.hotstrings.preview_bubbles"))
			helpers.assert_eq(preview[1].disabled, true)
			helpers.assert_eq(preview[1].fn(), false)
			helpers.assert_eq(f.calls.writes, 0); helpers.assert_eq(f.calls.redraws, 0)
		end, true)
	end)
	helpers.it("reads all five canonical caption fields instead of retained native labels", function()
		with_frame(function(f)
			for key in pairs(f.root.hotstrings_delay_captions) do f.root.hotstrings_delay_captions[key] = "button.ok" end
			local delays = children(assert(f.build()), f.captions("menu.hotstrings.delays_colors"))
			for _, index in ipairs({ 3, 4, 5, 7, 8 }) do
				helpers.assert_eq(delays[index].title:sub(1, #f.captions("button.ok")), f.captions("button.ok"))
			end
		end)
	end)
	for _, mode in ipairs({ "missing", "foreign", "wrong_type", "wrong_case" }) do
		helpers.it("refuses " .. mode .. " caption policies before returning parent rows", function()
			with_frame(function(f)
				if mode == "missing" then f.root.hotstrings_delay_captions.default = nil
				elseif mode == "foreign" then f.root.hotstrings_delay_captions.unrelated = "button.ok"
				elseif mode == "wrong_case" then
					f.root.hotstrings_delay_captions.Default = f.root.hotstrings_delay_captions.default
					f.root.hotstrings_delay_captions.default = nil
				else f.root.hotstrings_delay_captions.default = false end
				helpers.assert_eq(f.build(), nil)
				helpers.assert_eq(f.calls.writes, 0); helpers.assert_eq(f.calls.redraws, 0)
			end)
		end)
	end
	helpers.it("refuses an unbound native child identity and repairs the declaration", function()
		with_frame(function(f)
			local actual = f.root.hotstrings_delays_frame[1].id
			f.root.hotstrings_delays_frame[1].id = "unrelated_provider"
			helpers.assert_eq(f.build(), nil)
			f.root.hotstrings_delays_frame[1].id = actual
			helpers.assert_type(f.build(), "table")
		end)
	end)
	helpers.it("restores exact genuine owners after a raised scenario", function()
		local names = { "infra.i18n", "infra.manifest_menu", "modules.hotstrings.hotstrings_config",
			"ui.menu.menu_hotstrings_management", "infra.paths" }
		local before = {}; for _, name in ipairs(names) do before[name] = package.loaded[name] end
		local ok, err = pcall(function()
			with_frame(function(f) assert(f.build()); error("parameter frame scenario sentinel", 0) end)
		end)
		helpers.assert_eq(ok, false)
		helpers.assert_true(tostring(err):find("parameter frame scenario sentinel", 1, true) ~= nil)
		for _, name in ipairs(names) do helpers.assert_true(rawequal(package.loaded[name], before[name])) end
	end)
	for _, section in ipairs({ "hotstrings_word_expander_frame", "hotstrings_preview_frame", "hotstrings_delays_frame" }) do
		helpers.it("withdraws and repairs the actual " .. section .. " declaration", function()
			with_frame(function(f)
				local actual = f.root[section]; f.root[section] = nil
				helpers.assert_eq(f.build(), nil)
				f.root[section] = actual
				helpers.assert_type(f.build(), "table")
			end)
		end)
	end
end)

return true
