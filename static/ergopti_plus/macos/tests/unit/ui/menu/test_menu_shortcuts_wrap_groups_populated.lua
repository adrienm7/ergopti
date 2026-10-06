--- tests/unit/ui/menu/test_menu_shortcuts_wrap_groups_populated.lua

--- ==============================================================================
--- MODULE: Regression — every wrap-symbol group opens a populated submenu
--- DESCRIPTION:
--- The wrap-symbols tree is provider DATA rendered by the shared renderer, which
--- reads a row's subtree from `items`. Each symbol group hung its rows on
--- `menu`, a field the renderer never reads on a provider row, so every group of
--- Shortcuts > wrap symbols opened empty. This renders the real Shortcuts row
--- through the tray's own call and opens every group.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("Shortcuts wrap-symbol groups are populated", function()
	helpers.it("every group under the wrap-symbols row has rows", function()
		local shortcuts = helpers.load_with_stubs("ui.menu.menu_shortcuts")
		local ManifestMenu = require("infra.manifest_menu")
		local item = shortcuts.build({
			state      = { shortcuts = true },
			save_prefs = function() return true end,
			updateMenu = function() end,
			shortcuts  = {
				list_shortcuts        = function() return {} end,
				is_enabled            = function() return true end,
				set_wrap_pairs_getter = function() end,
			},
		})
		helpers.assert_true(type(item) == "table", "menu_shortcuts.build must return a row")
		local row = ManifestMenu.render_rows({ item }, "top_level")[1]
		helpers.assert_true(type(row) == "table" and type(row.menu) == "table", "Shortcuts must render a submenu")

		local wrap
		for _, entry in ipairs(row.menu) do
			if entry.title == "menu.shortcuts.wrap_symbols" then wrap = entry end
		end
		helpers.assert_true(wrap ~= nil and type(wrap.menu) == "table", "the wrap-symbols row must render")

		local groups = 0
		for _, entry in ipairs(wrap.menu) do
			if entry.menu ~= nil then
				groups = groups + 1
				helpers.assert_true(type(entry.menu) == "table" and #entry.menu > 0,
					"wrap-symbol group '" .. tostring(entry.title) .. "' opened empty — its rows must be `items`")
			end
		end
		helpers.assert_true(groups > 0, "the manifest's wrap-symbol groups must render, or this test measures nothing")
	end)
end)


local WrapJson = require("json")
local wrap_file = assert(io.open(helpers.shared("tests/corpus/menus/wrap_symbol_controls.json"), "rb"))
local wrap_expectations = assert(WrapJson.decode(wrap_file:read("*a")))
wrap_file:close()

--- Executes the actual Shortcuts provider and renderer over bounded native ports.
local function with_wrap_controls(options, callback)
	options = options or {}
	return helpers.with_stub_scope({
		"ui.menu.menu_shortcuts", "menu.wrap_mutation", "infra.manifest_menu", "infra.i18n", "infra.paths",
		"infra.logger", "infra.dialog_util", "modules.shortcuts.actions.text",
		"ui.menu.menu_utils", "ui.menu.menu_keyboard_slots", "ui.menu.shortcut_utils",
		"ui.menu.menu_tap_keys", "infra.manifest_reader",
	}, function()
		local renderer = helpers.load_with_stubs("infra.manifest_menu")
		local translations = {}
		package.loaded["infra.i18n"].get = function(key) return translations[key] or key end
		local calls = { saves = 0, updates = 0, prompts = 0 }
		local responses = options.responses or {}
		package.loaded["infra.dialog_util"] = {
			text_prompt = function()
				calls.prompts = calls.prompts + 1
				local response = assert(responses[calls.prompts], "unexpected native prompt")
				return response[1], response[2]
			end,
			block_alert = function() return true end,
		}
		local text = require("modules.shortcuts.actions.text")
		if options.empty_catalogue then text.WRAP_GROUPS = {} end
		local menu = require("ui.menu.menu_shortcuts")
		local state = {
			shortcuts = true, chatgpt_url = "https://example.test", wrap_symbol_states = { ["("] = false },
			custom_wrap_symbols = options.custom or {},
		}
		local ctx = {
			state = state, paused = options.paused,
			shortcuts = { list_shortcuts = function() return {} end, is_enabled = function() return true end,
				set_wrap_pairs_getter = function() end },
			save_prefs = function()
				calls.saves = calls.saves + 1
				if options.receipt_kind == "nil" then return nil end
				if options.receipt_kind == "false" then return false end
				if options.receipt_kind == "truthy" then return "accepted" end
				return true
			end,
			updateMenu = function() calls.updates = calls.updates + 1 end,
		}
		local function build()
			local item = menu.build(ctx)
			for _, row in ipairs(item.submenu) do
				if row.title == "menu.shortcuts.wrap_symbols" then return row end
			end
			error("actual wrap-symbol provider did not render", 0)
		end
		callback({ build = build, renderer = renderer, state = state, calls = calls,
			ctx = ctx, text = text, translations = translations })
	end)
end

local function wrap_row(rows, title)
	for _, row in ipairs(rows) do if row.title == title then return row end end
	error("actual native row missing: " .. title, 0)
end

helpers.describe("declared fixed wrap-symbol controls", function()
	helpers.it("renders the handwritten complete control order and original catalogue groups (wrap-controls)", function()
		with_wrap_controls({ custom = { { left = "a", right = "b" }, { left = "c", right = "c" } } }, function(f)
			local wrap = f.build()
			helpers.assert_eq(#wrap.menu, wrap_expectations.counts.with_two_custom)
			helpers.assert_eq(wrap.menu[1].title, "menu.shortcuts.wrap_symbols_check_all")
			helpers.assert_eq(wrap.menu[2].title, "menu.shortcuts.wrap_symbols_uncheck_all")
			helpers.assert_eq(wrap.menu[3].title, "common.restore_recommended")
			helpers.assert_eq(wrap.menu[4].title, "-")
			for index, expected in ipairs(wrap_expectations.catalogue_groups) do
				local group = wrap.menu[index + 4]
				helpers.assert_eq(group.title, expected.i18n)
				helpers.assert_eq(group.menu[1].title, "menu.shortcuts.wrap_symbols_check_all")
				helpers.assert_eq(group.menu[2].title, "menu.shortcuts.wrap_symbols_uncheck_all")
				helpers.assert_eq(group.menu[3].title, "-")
				helpers.assert_eq(#group.menu, #expected.lefts + wrap_expectations.counts.group_controls)
				for pair_index, left in ipairs(expected.lefts) do
					helpers.assert_eq(f.text.WRAP_GROUPS[index].pairs[pair_index].left, left)
				end
			end
			helpers.assert_eq(wrap.menu[12].title, "-")
			for index, title in ipairs(wrap_expectations.custom_labels) do
				local custom = wrap.menu[index + 12]
				helpers.assert_eq(custom.title, title)
				helpers.assert_eq(custom.menu[1].title, wrap_expectations.custom_child_label)
				helpers.assert_type(custom.menu[1].fn, "function", "declared custom delete is actually reachable")
			end
			helpers.assert_eq(wrap.menu[15].title, "-")
			helpers.assert_eq(wrap.menu[16].title, "menu.shortcuts.wrap_symbols_add_custom")
		end)
	end)

	helpers.it("keeps separator normalization correct with no custom rows or catalogue (wrap-controls)", function()
		with_wrap_controls({}, function(f)
			helpers.assert_eq(#f.build().menu, wrap_expectations.counts.without_custom)
		end)
		with_wrap_controls({ empty_catalogue = true }, function(f)
			local rows = f.build().menu
			helpers.assert_eq(#rows, wrap_expectations.counts.rendered_without_catalogue_or_custom)
			helpers.assert_eq(rows[4].title, "-")
			helpers.assert_eq(rows[5].title, "menu.shortcuts.wrap_symbols_add_custom")
		end)
	end)

	for _, action in ipairs({ "menu.shortcuts.wrap_symbols_check_all", "menu.shortcuts.wrap_symbols_uncheck_all", "common.restore_recommended" }) do
		helpers.it("runs the real global mutation owner " .. action .. " (wrap-controls)", function()
			with_wrap_controls({ custom = { { left = "a", right = "b" } } }, function(f)
				wrap_row(f.build().menu, action).fn()
				helpers.assert_eq(f.calls.saves, 1)
				helpers.assert_eq(f.calls.updates, 1)
				if action == "common.restore_recommended" then
					helpers.assert_eq(f.state.wrap_symbol_states, {})
					helpers.assert_eq(f.state.custom_wrap_symbols, {})
				else
					for _, group in ipairs(wrap_expectations.catalogue_groups) do
						for _, left in ipairs(group.lefts) do
							helpers.assert_eq(f.state.wrap_symbol_states[left], action == "menu.shortcuts.wrap_symbols_check_all")
						end
					end
				end
			end)
		end)
	end

	for _, receipt in ipairs({ "false", "nil", "truthy" }) do
		helpers.it("requires the unchanged exact native save receipt " .. receipt .. " (wrap-controls)", function()
			with_wrap_controls({ receipt_kind = receipt }, function(f)
				helpers.assert_eq(wrap_row(f.build().menu, "menu.shortcuts.wrap_symbols_check_all").fn(), false)
				helpers.assert_eq(f.calls.saves, 1)
				helpers.assert_eq(f.calls.updates, 0)
			end)
		end)
	end

	helpers.it("captures each group payload while using current native state (wrap-controls)", function()
		with_wrap_controls({}, function(f)
			local rows = f.build().menu
			local first = wrap_row(rows, "menu.shortcuts.wrap_group_brackets")
			local second = wrap_row(rows, "menu.shortcuts.wrap_group_quotes")
			f.state.wrap_symbol_states = { ["sentinel"] = true }
			first.menu[2].fn()
			for _, left in ipairs(wrap_expectations.catalogue_groups[1].lefts) do helpers.assert_eq(f.state.wrap_symbol_states[left], false) end
			for _, left in ipairs(wrap_expectations.catalogue_groups[2].lefts) do helpers.assert_nil(f.state.wrap_symbol_states[left]) end
			second.menu[1].fn()
			for _, left in ipairs(wrap_expectations.catalogue_groups[2].lefts) do helpers.assert_eq(f.state.wrap_symbol_states[left], true) end
			helpers.assert_eq(f.state.wrap_symbol_states.sentinel, true)
			helpers.assert_eq(f.calls.saves, 2)
			helpers.assert_eq(f.calls.updates, 2)
		end)
	end)

	helpers.it("invokes the actual rendered custom delete on current native data (wrap-controls)", function()
		with_wrap_controls({ custom = { { left = "a", right = "b" }, { left = "c", right = "c" } } }, function(f)
			local row = wrap_row(f.build().menu, wrap_expectations.custom_labels[2])
			helpers.assert_eq(row.menu[1].title, "button.delete")
			f.state.custom_wrap_symbols = { { left = "x", right = "y" }, { left = "z", right = "z" } }
			row.menu[1].fn()
			helpers.assert_eq(f.state.custom_wrap_symbols, { { left = "x", right = "y" } })
			helpers.assert_eq(f.calls.saves, 1)
			helpers.assert_eq(f.calls.updates, 1)
		end)
	end)

	helpers.it("preserves the actual add-custom prompt and native save owner (wrap-controls)", function()
		with_wrap_controls({ responses = { { "button.ok", "a" }, { "button.ok", "" } } }, function(f)
			helpers.assert_eq(wrap_row(f.build().menu, "menu.shortcuts.wrap_symbols_add_custom").fn(), true)
			helpers.assert_eq(f.state.custom_wrap_symbols, { { left = "a", right = "a" } })
			helpers.assert_eq(f.calls.prompts, 2)
			helpers.assert_eq(f.calls.saves, 1)
			helpers.assert_eq(f.calls.updates, 1)
		end)
	end)

	helpers.it("keeps the native paused management rows inert (wrap-controls)", function()
		with_wrap_controls({ paused = true }, function(f)
			local wrap = f.build()
			helpers.assert_eq(wrap.disabled, true)
			for _, index in ipairs({ 1, 2, 3, #wrap.menu }) do
				local row = wrap.menu[index]
				helpers.assert_eq(row.disabled, true)
				if row.fn then helpers.assert_eq(row.fn(), false) end
			end
			helpers.assert_eq(f.calls.saves + f.calls.updates + f.calls.prompts, 0)
		end)
	end)

	helpers.it("consumes declaration order and caption mutations in the actual provider (wrap-controls)", function()
		with_wrap_controls({}, function(f)
			local def = f.renderer.get_array("wrap_symbols_global_controls")
			local old_first, old_second, old_key = def[1], def[2], def[1].i18n
			local ok, err = pcall(function()
				def[1].i18n = "independent.wrap.label"
				f.translations["independent.wrap.label"] = "literal 100% {1}"
				def[1], def[2] = def[2], def[1]
				local rows = f.build().menu
				helpers.assert_eq(rows[1].title, "menu.shortcuts.wrap_symbols_uncheck_all")
				helpers.assert_eq(rows[2].title, "literal 100% {1}")
				rows[2].fn()
				helpers.assert_eq(f.state.wrap_symbol_states["("], true)
			end)
			def[1], def[2] = old_first, old_second
			old_first.i18n = old_key
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("honors platform hiding and refuses missing native command ownership (wrap-controls)", function()
		with_wrap_controls({}, function(f)
			local def = f.renderer.get_array("wrap_symbols_global_controls")
			local old_platforms, old_id = def[1].platforms, def[2].id
			local ok, err = pcall(function()
				def[1].platforms = { "ahk" }
				local rows = f.build().menu
				helpers.assert_eq(rows[1].title, "menu.shortcuts.wrap_symbols_uncheck_all")
				def[2].id = "unowned.wrap.command"
				helpers.assert_eq(f.build().menu, {}, "missing native owner refuses the complete picker")
			end)
			def[1].platforms, def[2].id = old_platforms, old_id
			if not ok then error(err, 0) end
		end)
	end)
end)


local function wrap_find_nested(rows, title)
	for _, row in ipairs(rows or {}) do
		if row.title == title then return row end
		if row.menu then
			local found = wrap_find_nested(row.menu, title)
			if found then return found end
		end
	end
end

helpers.describe("independent complete fixed wrap declaration coverage", function()
	helpers.it("pins each published section field and hides every control on Linux (wrap-controls)", function()
		with_wrap_controls({}, function(f)
			local Renderer = require("menu.renderer")
			for _, platform in ipairs({ "ahk", "hs", "linux" }) do
				local renderer = assert(Renderer.new({ platform = platform,
					manifest_path = function() return helpers.shared("modules/menu/menu_manifest.json") end, json_decode = WrapJson.decode,
					i18n = package.loaded["infra.i18n"], logger = helpers.make_logger_stub() }))
				for _, section in ipairs(wrap_expectations.sections) do
					local definitions = renderer.get_array(section.section)
					helpers.assert_eq(#definitions, #section.rows)
					local commands = {}
					for index, expected in ipairs(section.rows) do
						local actual = definitions[index]
						helpers.assert_eq(actual.type, expected.separator and "---" or "command")
						helpers.assert_eq(actual.id, expected.id)
						helpers.assert_eq(actual.i18n, expected.i18n)
						helpers.assert_eq(actual.disabled_when, expected.disabled_when)
						helpers.assert_eq(actual.platforms, wrap_expectations.platforms)
						helpers.assert_eq(actual.unavailable, "hide")
						if expected.id then commands[expected.id] = function() error("projection must not deliver a native effect", 0) end end
					end
					local rows = assert(renderer.template_rows(section.section, commands, { wrap_symbols_ready = function() return true end }))
					if platform == "linux" then helpers.assert_eq(rows, {})
					else
						helpers.assert_eq(#rows, #section.rows)
						for index, expected in ipairs(section.rows) do
							if expected.separator then helpers.assert_eq(rows[index], { separator = true })
							else helpers.assert_eq(rows[index].label, expected.i18n) end
						end
					end
				end
			end
		end)
	end)

	helpers.it("materializes all existing translated captions in all 21 published locales (wrap-controls)", function()
		with_wrap_controls({ custom = { { left = "a", right = "b" } } }, function(f)
			local count = 0
			for _, code in ipairs(wrap_expectations.locales) do
				local file = assert(io.open(helpers.shared("data/locales/" .. code .. ".json"), "rb"))
				local translated = assert(WrapJson.decode(file:read("*a")))
				file:close()
				for _, section in ipairs(wrap_expectations.sections) do
					for _, expected in ipairs(section.rows) do
						if expected.i18n then f.translations[expected.i18n] = assert(translated[expected.i18n]) end
					end
				end
				local wrap = f.build()
				for _, section in ipairs(wrap_expectations.sections) do
					for _, expected in ipairs(section.rows) do
						if expected.i18n then
							helpers.assert_true(wrap_find_nested(wrap.menu, translated[expected.i18n]) ~= nil,
								"actual provider caption in " .. code .. ": " .. expected.i18n)
						end
					end
				end
				count = count + 1
			end
			helpers.assert_eq(count, 21, "every published locale was executed")
		end)
	end)

	for _, section in ipairs(wrap_expectations.sections) do
		local first_command
		for _, row in ipairs(section.rows) do if row.id then first_command = row; break end end
		if first_command then
			helpers.it("consumes actual native child caption metadata " .. section.section .. " (wrap-controls)", function()
				with_wrap_controls({ custom = { { left = "a", right = "b" } } }, function(f)
					local definition
					for _, row in ipairs(f.renderer.get_array(section.section)) do if row.id == first_command.id then definition = row end end
					local original = definition.i18n
					local ok, err = pcall(function()
						definition.i18n = "mutated.wrap.child"
						f.translations[definition.i18n] = "literal %s 100% {1}"
						helpers.assert_true(wrap_find_nested(f.build().menu, "literal %s 100% {1}") ~= nil)
					end)
					definition.i18n = original
					if not ok then error(err, 0) end
				end)
			end)
		end
	end
end)


helpers.describe("every fixed wrap mutation retains its exact native receipt", function()
	local commands = {
		{ name = "global disable", title = "menu.shortcuts.wrap_symbols_uncheck_all" },
		{ name = "global restore", title = "common.restore_recommended" },
		{ name = "group enable", group = "menu.shortcuts.wrap_group_brackets", index = 1 },
		{ name = "group disable", group = "menu.shortcuts.wrap_group_brackets", index = 2 },
		{ name = "custom delete", custom = true },
		{ name = "add custom", title = "menu.shortcuts.wrap_symbols_add_custom" },
	}
	for _, command in ipairs(commands) do
		for _, receipt in ipairs({ "false", "nil", "truthy" }) do
			helpers.it("refuses " .. command.name .. " save receipt " .. receipt .. " (wrap-controls)", function()
				with_wrap_controls({ receipt_kind = receipt, custom = { { left = "a", right = "b" } },
					responses = { { "button.ok", "x" }, { "button.ok", "y" } } }, function(f)
					local rows = f.build().menu
					local row
					if command.group then row = wrap_row(rows, command.group).menu[command.index]
					elseif command.custom then row = wrap_row(rows, wrap_expectations.custom_labels[1]).menu[1]
					else row = wrap_row(rows, command.title) end
					helpers.assert_eq(row.fn(), false)
					helpers.assert_eq(f.calls.saves, 1)
					helpers.assert_eq(f.calls.updates, 0, "existing native owner never advertises an unacknowledged save")
				end)
			end)
		end
	end
end)


helpers.describe("native wrap-control pause eligibility keeps its original truthiness", function()
	helpers.it("refuses a truthy native pause value before any control effect (wrap-controls)", function()
		with_wrap_controls({ paused = "native pause claim" }, function(f)
			local wrap = f.build()
			helpers.assert_eq(wrap.disabled, "native pause claim", "native outer row stays unchanged")
			for _, index in ipairs({ 1, 2, 3, #wrap.menu }) do
				local row = wrap.menu[index]
				helpers.assert_eq(row.disabled, true)
				if row.fn then helpers.assert_eq(row.fn(), false) end
			end
			helpers.assert_eq(f.calls.saves + f.calls.updates + f.calls.prompts, 0)
		end)
	end)
end)

helpers.describe("independent rendered custom-delete persistence refusal", function()
 for _, receipt in ipairs({"false", "nil", "truthy"}) do
  helpers.it("preserves custom model after " .. receipt .. " save refusal", function()
   with_wrap_controls({custom={{left="a",right="b"}},receipt_kind=receipt}, function(f)
    local row=wrap_row(f.build().menu,"a … b : menu.shortcuts.wrap_symbols_custom_label")
    helpers.assert_eq(row.menu[1].fn(),false)
    helpers.assert_eq(f.calls.saves,1)
    helpers.assert_eq(f.calls.updates,0)
    helpers.assert_eq(f.state.custom_wrap_symbols,{{left="a",right="b"}},"refusal must retain native model")
   end)
  end)
  helpers.it("preserves live wrap pair after " .. receipt .. " save refusal", function()
   with_wrap_controls({custom={{left="a",right="b"}},receipt_kind=receipt}, function(f)
    local live
    f.ctx.shortcuts.set_wrap_pairs_getter=function(getter)live=getter end
    local row=wrap_row(f.build().menu,"a … b : menu.shortcuts.wrap_symbols_custom_label")
    helpers.assert_eq(live().a,{left="a",right="b"})
    helpers.assert_eq(row.menu[1].fn(),false)
    helpers.assert_eq(live().a,{left="a",right="b"},"refusal must retain eventtap's active wrapping pair")
   end)
  end)
 end
end)


helpers.describe("acknowledged native Wrap mutations", function()
	local function callback(f, action)
		local rows = f.build().menu
		if action == "delete" then return wrap_row(rows, "a … b : menu.shortcuts.wrap_symbols_custom_label").menu[1].fn end
		if action == "group" then return wrap_row(rows, "menu.shortcuts.wrap_group_brackets").menu[2].fn end
		if action == "symbol" then return wrap_row(wrap_row(rows, "menu.shortcuts.wrap_group_brackets").menu, "( … )").fn end
		return wrap_row(rows, action).fn
	end
	local function custom()
		return { { left = "a", right = "b", future = { note = "retain" } }, { left = "c", right = "d" } }
	end
	local actions = { "delete", "group", "symbol", "menu.shortcuts.wrap_symbols_check_all",
		"menu.shortcuts.wrap_symbols_uncheck_all", "common.restore_recommended", "menu.shortcuts.wrap_symbols_add_custom" }
	for _, action in ipairs(actions) do
		for _, receipt in ipairs({ "false", "nil", "truthy", "throw" }) do
			helpers.it("retains model and real input for " .. action .. " after " .. receipt .. " refusal", function()
				with_wrap_controls({ custom = custom(), responses = { { "button.ok", "x" }, { "button.ok", "y" } } }, function(f)
					local live, observed
					f.ctx.shortcuts.set_wrap_pairs_getter = function(getter) live = getter end
					local run = callback(f, action)
					local prior_symbols, prior_custom = f.state.wrap_symbol_states, f.state.custom_wrap_symbols
					f.state.private = { note = "retain" }
					f.ctx.save_prefs = function()
						f.calls.saves = f.calls.saves + 1
						observed = live()
						f.state.private.note = "independent successor"
						if receipt == "throw" then error("controlled Wrap persistence failure", 0) end
						if receipt == "false" then return false end
						if receipt == "truthy" then return "accepted" end
					end
					helpers.assert_eq(run(), false)
					helpers.assert_eq(f.calls.saves, 1)
					helpers.assert_eq(f.calls.updates, 0)
					helpers.assert_eq(f.state.wrap_symbol_states, { ["("] = false })
					helpers.assert_eq(f.state.custom_wrap_symbols, custom())
					helpers.assert_true(rawequal(f.state.wrap_symbol_states, prior_symbols))
					helpers.assert_true(rawequal(f.state.custom_wrap_symbols, prior_custom))
					helpers.assert_eq(f.state.private.note, "independent successor")
					helpers.assert_eq(observed.a, { left = "a", right = "b" }, "pending writer cannot change active custom input")
					helpers.assert_nil(observed["("], "pending writer cannot enable a disabled built-in symbol")
					helpers.assert_eq(live().a, { left = "a", right = "b" })
					helpers.assert_nil(live()["("])
				end)
			end)
		end
	end
	for _, receipt in ipairs({ "false", "nil", "truthy", "throw" }) do
		helpers.it("retained Delete retries after " .. receipt .. " without a second mutation on refusal", function()
			with_wrap_controls({ custom = custom() }, function(f)
				local run = callback(f, "delete")
				f.ctx.save_prefs = function()
					f.calls.saves = f.calls.saves + 1
					if f.calls.saves > 1 then return true end
					if receipt == "throw" then error("controlled refusal", 0) end
					if receipt == "false" then return false end
					if receipt == "truthy" then return "accepted" end
				end
				helpers.assert_eq(run(), false)
				helpers.assert_eq(f.state.custom_wrap_symbols, custom())
				helpers.assert_eq(run(), true)
				helpers.assert_eq(f.state.custom_wrap_symbols, { { left = "c", right = "d" } })
				helpers.assert_eq(f.calls.saves, 2)
				helpers.assert_eq(f.calls.updates, 1)
			end)
		end)
	end
	for _, sibling in ipairs(actions) do
		helpers.it("refuses actual reentrant " .. sibling .. " during Delete publication", function()
			with_wrap_controls({ custom = custom(), responses = { { "button.ok", "x" }, { "button.ok", "y" } } }, function(f)
				local run, nested = callback(f, "delete"), callback(f, sibling)
				local observed, after_nested
				f.ctx.save_prefs = function()
					f.calls.saves = f.calls.saves + 1
					observed = nested()
					after_nested = { customs = f.state.custom_wrap_symbols, symbols = f.state.wrap_symbol_states }
					return false
				end
				helpers.assert_eq(run(), false)
				helpers.assert_eq(observed, false)
				helpers.assert_eq(f.calls.saves, 1, "no nested writer admitted")
				helpers.assert_eq(f.calls.updates + f.calls.prompts, 0, "reentrant Add cannot acquire a native dialog")
				helpers.assert_eq(after_nested.customs, { { left = "c", right = "d" } }, "nested callback cannot mutate the owned candidate")
				helpers.assert_eq(after_nested.symbols, { ["("] = false })
				helpers.assert_eq(f.state.custom_wrap_symbols, custom())
			end)
		end)
	end
	helpers.it("a rebuilt menu cannot escape the retained Delete field claim", function()
		with_wrap_controls({ custom = custom() }, function(f)
			local run = callback(f, "delete")
			local nested_result
			f.ctx.save_prefs = function()
				f.calls.saves = f.calls.saves + 1
				local rows = f.build().menu
				nested_result = wrap_row(rows, "c … d : menu.shortcuts.wrap_symbols_custom_label").menu[1].fn()
				return false
			end
			helpers.assert_eq(run(), false)
			helpers.assert_eq(nested_result, false)
			helpers.assert_eq(f.calls.saves, 1)
			helpers.assert_eq(f.state.custom_wrap_symbols, custom())
		end)
	end)
	helpers.it("refused Delete preserves a replacement successor and unrelated future fields", function()
		with_wrap_controls({ custom = custom() }, function(f)
			local run = callback(f, "delete")
			local successor = { { left = "x", right = "y", future = "successor" } }
			f.ctx.save_prefs = function()
				f.calls.saves = f.calls.saves + 1
				f.state.custom_wrap_symbols = successor
				f.state.private = { future = "successor" }
				return false
			end
			helpers.assert_eq(run(), false)
			helpers.assert_true(rawequal(f.state.custom_wrap_symbols, successor))
			helpers.assert_eq(f.state.private, { future = "successor" })
			helpers.assert_eq(f.state.wrap_symbol_states, { ["("] = false })
			helpers.assert_eq(f.calls.updates, 0)
		end)
	end)
	helpers.it("an out-of-range retained Delete cannot mutate a successor list", function()
		with_wrap_controls({ custom = custom() }, function(f)
			local rows = f.build().menu
			local run = wrap_row(rows, "c … d : menu.shortcuts.wrap_symbols_custom_label").menu[1].fn
			local successor = { { left = "x", right = "y" } }
			f.state.custom_wrap_symbols = successor
			helpers.assert_eq(run(), false)
			helpers.assert_true(rawequal(f.state.custom_wrap_symbols, successor))
			helpers.assert_eq(f.calls.saves + f.calls.updates, 0)
		end)
	end)
end)
