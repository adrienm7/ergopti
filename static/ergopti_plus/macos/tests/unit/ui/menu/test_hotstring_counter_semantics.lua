--- tests/unit/ui/menu/test_hotstring_counter_semantics.lua

--- ==============================================================================
--- MODULE: Hotstring Counter Semantics Tests
--- DESCRIPTION:
--- Verifies canonical entry classification and rejection before count publication.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_counter = require("tests.support.hotstring_counter_fixture")

helpers.describe("hotstring counter semantics", function()
	helpers.it("(hs-269-adjacent) preserves one cached section record for adjacent declarations", function()
		with_counter(function(counter, state, context)
			state.content = '[[arrows]]\n"a" = { output = "A" }\n[[arrows]]\n"b" = { output = "B" }\n'
			local result = counter.count_all(context, {})
			local sections = result.ext_details[1].files[1].sections
			helpers.assert_eq(result.ext, 2)
			helpers.assert_eq(sections, { { name = "arrows", count = 2 } })
			helpers.assert_true(counter.count_all(context, {}).ext_details[1].files[1].sections == sections)
			helpers.assert_eq(state.opens, 1)
			helpers.assert_eq(state.closes, 1)
		end)
	end)

	for _, newline in ipairs({ "\n", "\r\n" }) do
		for _, prefix in ipairs({ "", string.char(239, 187, 191) }) do
			helpers.it("(hs-270-registry-parity) preserves embedded BOM with prefix/newline " .. #prefix .. "/" .. #newline, function()
				with_counter(function(counter, state, context)
					helpers.with_fresh_modules({ "modules.keymap.registry_groups", "modules.hotstrings.hotstrings_config",
						"toml_codec.reader", "infra.toml.reader" }, function()
						local bom = string.char(239, 187, 191)
						state.content = prefix .. '[[arrows]]' .. newline
							.. '"' .. bom .. 'a" = { output = "' .. bom .. 'A" }'
						package.loaded["modules.hotstrings.hotstrings_config"] = { get_user_override = function() return nil end }
						local groups = require("modules.keymap.registry_groups")
						local runtime = { groups = {}, mappings = {}, SECTION_DELAYS = {} }
						local function noop() end
						helpers.assert_true(groups.init(runtime, {
							add = function(trigger, output)
								runtime.mappings[#runtime.mappings + 1] = { trigger = trigger, output = output }
							end,
							sort_mappings = noop, is_section_enabled = function() return true end,
							resolve_priority = function() return 1 end, rebuild_lookup = noop,
							rebuild_tail_indexes = noop, drop_classify_cache = noop,
						}))
						helpers.assert_true(groups.load_toml("ext:demo:demo", "/virtual/extensions/demo/hotstrings/demo.toml"))
						helpers.assert_eq(runtime.mappings, { { trigger = bom .. "a", output = bom .. "A" } })
						local opens, closes = state.opens, state.closes
						local result = counter.count_all(context, {})
						helpers.assert_eq(result.ext, #runtime.mappings)
						helpers.assert_eq(result.has_ext, true)
						helpers.assert_eq(counter.count_all(context, {}).ext, 1)
						helpers.assert_eq(state.opens - opens, 1)
						helpers.assert_eq(state.closes - closes, 1)
					end)
				end)
			end)
		end
	end

	helpers.it("(hs-269-rendering) renders one merged detail across repeated declarations", function()
		local original_hs = _G.hs
		local ok, failure = xpcall(function()
			helpers.with_fresh_modules({ "ui.menu.builder", "ui.menu.hotstring_counter", "infra.logger" }, function()
				local builder = helpers.load_with_stubs("ui.menu.builder")
				local builder_counter = require("ui.menu.hotstring_counter")
				local counts
				with_counter(function(counter, state, context)
					state.content = '[[arrows]]\n"a" = { output = "A" }\n'
						.. '[[symbols]]\n"s" = { output = "S" }\n'
						.. '[_meta]\n"description" = "Metadata"\n'
						.. '[[arrows]]\n"b" = { output = "B" }\n'
					counts = counter.count_all(context, {})
					helpers.assert_eq(counts.ext, 3)
					helpers.assert_eq(counts.ext_details[1].files[1].sections, {
						{ name = "arrows", count = 2 }, { name = "symbols", count = 1 },
					})
					helpers.assert_eq(counter.count_all(context, {}).ext, 3)
					helpers.assert_eq(state.opens, 1)
					helpers.assert_eq(state.closes, 1)
				end)
				-- Feed real counter output after restoring I/O for the menu manifest
				builder_counter.count_all = function() return counts end
				local context = { config = { log_level = 2 }, paused = false, hotfiles = {},
					state = { hotstrings = {} }, save_prefs = function() end, updateMenu = function() end }
				local actions = setmetatable({}, { __index = function() return function() end end })
				local menu = builder.generate(context, { hotstrings = {} }, actions)
				local merged, duplicate = 0, 0
				local function visit(rows)
					for _, row in ipairs(rows) do
						if row.title == "arrows (2)" then
							merged = merged + 1
							helpers.assert_eq(row.disabled, true)
						elseif row.title == "arrows (1)" then
							duplicate = duplicate + 1
						end
						if type(row.menu) == "table" then visit(row.menu) end
					end
				end
				visit(menu)
				helpers.assert_eq(merged, 1)
				helpers.assert_eq(duplicate, 0)
			end)
		end, debug.traceback)
		_G.hs = original_hs
		if not ok then error(failure, 0) end
	end)

	helpers.it("(hs-271-projection) counts each canonical section once and omits placeholders", function()
		with_counter(function(counter, state, context)
			state.content = '[_meta]\nsections_order = ["arrows", "arrows", "-", "placeholder"]\n'
				.. '[_meta.sections]\nplaceholder = "Module"\n'
				.. '[[arrows]]\n"a" = { output = "A" }\n'
				.. '[[symbols]]\n"s" = { output = "S" }\n'
				.. '[[arrows]]\n"b" = { output = "B" }\n'
			local result = counter.count_all(context, {})
			local sections = result.ext_details[1].files[1].sections
			helpers.assert_eq(result.ext, 3)
			helpers.assert_eq(#sections, 2)
			helpers.assert_eq(sections[1], { name = "arrows", count = 2 })
			helpers.assert_eq(sections[2], { name = "symbols", count = 1 })
			helpers.assert_eq(counter.count_all(context, {}).ext_details[1].files[1].sections, sections)
			helpers.assert_eq(state.opens, 1)
		end)
	end)

	for _, newline in ipairs({ "\n", "\r\n" }) do
		helpers.it("(hs-271-snapshot) accepts initial BOM with newline width " .. #newline, function()
			with_counter(function(counter, state, context)
				local bom = string.char(239, 187, 191)
				state.content = bom .. '# comment' .. newline .. '[[arrows]]' .. newline
					.. '"' .. bom .. 'a" = { output = "A" }'
				helpers.assert_eq(counter.count_all(context, {}).ext, 1)
				helpers.assert_eq(counter.count_all(context, {}).ext, 1)
				helpers.assert_eq(state.opens, 1)
				helpers.assert_eq(state.closes, 1)
			end)
		end)
	end

	for _, key in ipairs({ "description", '"description"' }) do
		helpers.it("(hs-271-properties) excludes " .. key .. " before and after entries", function()
			with_counter(function(counter, state, context)
				state.content = '[[empty]]\n' .. key .. ' = "Only a property"\n'
					.. '[[arrows]]\n"a" = { output = "A" }\n' .. key .. ' = "Arrow shortcuts"\n'
				local result = counter.count_all(context, {})
				helpers.assert_eq(result.ext, 1)
				helpers.assert_eq(result.ext_details[1].files[1].sections[1].count, 0)
				helpers.assert_eq(result.ext_details[1].files[1].sections[2].count, 1)
			end)
		end)
	end

	helpers.it("(hs-271-triggers) counts description and escaped trigger entries", function()
		with_counter(function(counter, state, context)
			state.content = '[[arrows]]\n"description" = { output = "A" }\n'
				.. '"a\\\"b" = { output = "quoted" }\n'
			helpers.assert_eq(counter.count_all(context, {}).ext, 2)
		end)
	end)

	for _, invalid in ipairs({
		'"description" = "Private property"\n"description" = { output = "A" }',
		'"a" = { output = "A" }\n"a" = { output = "B" }',
		'description = "first"\n"description" = "second"',
	}) do
		helpers.it("(hs-271-rejection) rejects semantic failure and retries without cached counts " .. #invalid, function()
			with_counter(function(counter, state, context)
				state.content = '[[arrows]]\n' .. invalid
				local ok, failure = pcall(counter.count_all, context, {})
				helpers.assert_eq(ok, false)
				helpers.assert_eq(failure, "Extension TOML semantic parse failed; hotstring counts were not published")
				helpers.assert_eq(#state.errors, 1)
				helpers.assert_eq(state.errors[1]:find("Private", 1, true), nil)
				state.content = '[[arrows]]\n"fixed" = { output = "OK" }'
				helpers.assert_eq(counter.count_all(context, {}).ext, 1)
				helpers.assert_eq(state.opens, 2)
				helpers.assert_eq(state.closes, 2)
			end)
		end)
	end
end)
