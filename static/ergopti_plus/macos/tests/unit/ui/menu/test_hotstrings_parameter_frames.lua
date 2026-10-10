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



-- The sole actual registered consumer receives genuine parameter children and actual counter results.
helpers.describe("fixed feature parent: actual Mac Hotstrings (fixed-feature-parent-native)", function()
	for _, vector in ipairs({{total = 0, present = false, suffix = ""},
		{total = 0, present = true, suffix = " (0)"}, {total = 1234, present = true, suffix = " (1 234)"}}) do
		local contract = vector
		for _, enabled in ipairs({true, false}) do
			local state = enabled
			for _, paused in ipairs({true, false}) do
				local posture = paused
				helpers.it("keeps original count " .. contract.total .. "/" .. tostring(contract.present) .. " and master " .. tostring(state)
					.. " paused " .. tostring(posture) .. " in actual native Hotstrings consumer (fixed-feature-parent-native)", function()
					with_frame(function(f)
						return helpers.with_stub_scope({"ui.menu.builder", "ui.menu.hotstring_counter"}, function()
							local manifest = require("infra.manifest_menu")
							local management = require("ui.menu.menu_hotstrings_management")
							local counter = require("ui.menu.hotstring_counter")
							local actual_counter, actual_parent = counter.count_all, manifest.group_row
							local reads, completed = 0, nil
							counter.count_all = function(...) reads = reads + 1; return actual_counter(...) end
							manifest.group_row = function(section, id, child, getters)
								if section == "top_level" and id == "hotstrings" then completed = child end
								return actual_parent(section, id, child, getters)
							end
							local ok, detail = xpcall(function()
								local ctx = f.context
								ctx.state.keymap = state
								ctx.hotfiles = {"autocorrection"}; ctx.extension_packs = {}
								ctx.get_group_name = function(name) return name end
								-- Original source data receipts; the production counter itself remains the owner.
								ctx.keymap.get_sections = function(name)
									if name == "autocorrection" and contract.present then return {{name = "names", count = contract.total}} end
									return {}
								end
								ctx.keymap.is_group_enabled = function() return true end
								ctx.keymap.is_section_enabled = function() return true end
								local builder = require("ui.menu.builder")
								local owner, index, matches = nil, 1, 0
								while true do
									local name, candidate = debug.getupvalue(builder.generate, index)
									if name == nil then break end
									if name == "build_hotstrings_rows" then owner, matches = candidate, matches + 1 end
									index = index + 1
								end
								assert(matches == 1 and type(owner) == "function", "the sole actual registered native consumer is required")
								local rows = owner(ctx, {hotstrings = {build_management = management.build_management}})
								helpers.assert_eq(#rows, 1); helpers.assert_eq(reads, 1)
								helpers.assert_eq(rows[1].label, f.captions("menu.hotstrings.title") .. contract.suffix)
								helpers.assert_true(rawequal(rows[1].submenu, completed)); helpers.assert_nil(rows[1].action)
								helpers.assert_true(#completed > 0)
								if state then helpers.assert_eq(rows[1].checked, true) else helpers.assert_nil(rows[1].checked) end
								local parameters
								for _, row in ipairs(completed) do
									if row.title == f.captions("menu.hotstrings.params") then parameters = row end
								end
								helpers.assert_type(parameters, "table"); helpers.assert_type(parameters.menu, "table")
								local delays = children({menu = parameters.menu}, f.captions("menu.hotstrings.delays_colors"))
								helpers.assert_eq(#delays, 8)
								helpers.assert_eq(f.calls.writes, 0); helpers.assert_eq(f.calls.redraws, 0); helpers.assert_eq(f.calls.notices, 0)
							end, debug.traceback)
							counter.count_all, manifest.group_row = actual_counter, actual_parent
							if not ok then error(detail, 0) end
						end)
					end, posture)
				end)
			end
		end
	end
	for _, mode in ipairs({"wrong kind", "count declaration withdrawn", "bad count presence", "foreign platform"}) do
		local case = mode
		helpers.it("refuses " .. case .. " before the actual Mac counter and parameter producer (fixed-feature-parent-native)", function()
			with_frame(function(f)
				return helpers.with_stub_scope({"ui.menu.builder", "ui.menu.hotstring_counter"}, function()
					local counter, manifest = require("ui.menu.hotstring_counter"), require("infra.manifest_menu")
					local actual = counter.count_all; local reads, produces = 0, 0
					counter.count_all = function(...) reads = reads + 1; return actual(...) end
					local selected
					for _, row in ipairs(f.root.top_level) do if row.id == "hotstrings" then selected = row end end
					assert(selected)
					local kind, policy, platforms = selected.type, selected.caption_count_policy, selected.platforms
					local presence = policy.present_getter
					local ok, detail = xpcall(function()
						if case == "wrong kind" then selected.type = "command"
						elseif case == "count declaration withdrawn" then selected.caption_count_policy = {value_getter = "hotstrings_parent_total"}
						elseif case == "bad count presence" then policy.present_getter = ""
						else selected.platforms = {"linux", "ahk"} end
						local builder = require("ui.menu.builder")
						local owner, matches, index = nil, 0, 1
						while true do
							local name, candidate = debug.getupvalue(builder.generate, index)
							if name == nil then break end
							if name == "build_hotstrings_rows" then owner, matches = candidate, matches + 1 end
							index = index + 1
						end
						assert(matches == 1 and type(owner) == "function")
						local management = require("ui.menu.menu_hotstrings_management")
						local modules = {hotstrings = {build_management = function(...)
							produces = produces + 1; return management.build_management(...)
						end}}
						helpers.assert_eq(#owner(f.context, modules), 0)
						helpers.assert_eq(reads, 0); helpers.assert_eq(produces, 0)
						selected.type, selected.caption_count_policy, selected.platforms = kind, policy, platforms
						policy.present_getter = presence
						helpers.assert_eq(#owner(f.context, modules), 1)
						helpers.assert_eq(reads, 1); helpers.assert_eq(produces, 1)
					end, debug.traceback)
					selected.type, selected.caption_count_policy, selected.platforms = kind, policy, platforms
					policy.present_getter, counter.count_all = presence, actual
					if not ok then error(detail, 0) end
				end)
			end)
		end)
	end
end)

--- Runs the actual sole consumer, observing its real native producer delivery.
local function with_parameter_parent_consumer(f, body)
	return helpers.with_fresh_modules({ "ui.menu.builder" }, function()
		local builder = require("ui.menu.builder")
		local consumer
		local index = 1
		while true do
			local name, value = debug.getupvalue(builder.generate, index)
			if not name then break end
			if name == "build_hotstrings_rows" then
				assert(consumer == nil, "the actual parameter-parent consumer must have one registration")
				consumer = value
			end
			index = index + 1
		end
		assert(type(consumer) == "function", "the actual sole parameter-parent consumer must be registered")
		local owner = require("ui.menu.menu_hotstrings_management")
		local completed, calls = nil, 0
		local modules = { hotstrings = { build_management = function(context)
			calls = calls + 1
			completed = owner.build_management(context)
			return completed
		end } }
		local context = {}; for key, value in pairs(f.context) do context[key] = value end
		context.config, context.base_dir, context.hotfiles = { log_level = 2 }, helpers.driver_root(), {}
		local function build(expected_caption)
			completed, calls = nil, 0
			local roots = consumer(context, modules)
			assert(type(roots) == "table" and #roots == 1 and type(roots[1].submenu) == "table")
			local parent, matches = nil, 0
			for _, row in ipairs(roots[1].submenu) do
				if row.title == expected_caption then parent, matches = row, matches + 1 end
			end
			assert(matches == 1 and type(parent) == "table", "the actual consumer must publish one canonical parameter parent")
			return parent, completed, calls
		end
		return body(build)
	end)
end

helpers.describe("parameter parent is owned only by its existing shared consumer", function()
	for _, paused in ipairs({ false, true }) do
		helpers.it("publishes the completed native tree through the sole consumer, paused " .. tostring(paused), function()
			with_frame(function(f)
				with_parameter_parent_consumer(f, function(build)
					local parent, completed, calls = build(f.captions("menu.hotstrings.params"))
					helpers.assert_eq(calls, 1, "the native producer is invoked exactly once by its actual group callback")
					helpers.assert_nil(completed.title, "native children carry no second fixed parent caption")
					helpers.assert_true(rawequal(parent.menu, completed.menu), "the actual consumer retains completed child identity")
					helpers.assert_nil(parent.fn, "the rendered canonical group is not clickable")
					local preview = children(completed, f.captions("menu.hotstrings.preview_bubbles"))
					helpers.assert_eq(preview[1].disabled == true, paused, "the native paused child gate remains unchanged")
					helpers.assert_eq(f.calls.writes, 0); helpers.assert_eq(f.calls.redraws, 0)
				end)
			end, paused)
		end)
	end
	helpers.it("reads a changed canonical parent through the same sole consumer and restores it", function()
		with_frame(function(f)
			local declaration
			for _, row in ipairs(f.root.hotstrings_menu) do
				if row.id == "hotstrings_params" then assert(declaration == nil); declaration = row end
			end
			assert(type(declaration) == "table")
			local previous = declaration.i18n
			local called, detail = xpcall(function()
				declaration.i18n = "button.ok"
				with_parameter_parent_consumer(f, function(build)
					local parent, completed, calls = build(f.captions("button.ok"))
					helpers.assert_eq(calls, 1)
					helpers.assert_nil(completed.title, "the old native caption cannot shadow the changed shared owner")
					helpers.assert_true(rawequal(parent.menu, completed.menu))
				end)
			end, debug.traceback)
			declaration.i18n = previous
			if not called then error(detail, 0) end
			with_parameter_parent_consumer(f, function(build)
				local parent = build(f.captions("menu.hotstrings.params"))
				helpers.assert_eq(parent.title, f.captions("menu.hotstrings.params"))
			end)
		end)
	end)
end)

return true
