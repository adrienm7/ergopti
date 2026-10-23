--- tests/unit/ui/menu/menu_llm/settings/test_settings_transaction_fixed_controls.lua

--- ==============================================================================
--- MODULE: Transactional LLM Settings Regression
--- DESCRIPTION:
--- Proves that every LLM setting action restores state, native settings, runtime,
--- durable preferences, and rendered menu state when any boundary refuses.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.ui.menu.menu_llm.settings.settings_transaction_fixture"] = nil
local Fixture = require("tests.support.ui.menu.menu_llm.settings.settings_transaction_fixture")
local assert_row_graph_unchanged = Fixture.assert_row_graph_unchanged
local capture_row_graph = Fixture.capture_row_graph
local find_item = Fixture.find_item
local with_fixture = Fixture.with_fixture





helpers.describe("Complete LLM fixed controls: real transaction owners", function()
	helpers.it("the modifier frame owns translated choices and retains every physical-key callback", function()
		with_fixture({}, function(f)
			local menu = package.loaded["infra.manifest_menu"]
			local root, frame = menu.get_root(), menu.get_array("llm_modifier_picker_frame")
			local original = frame[1].i18n
			local ok, detail = xpcall(function()
				local before = f.manager.build_nav_modifier_menu()
				helpers.assert_eq(#before, 8)
				helpers.assert_eq(before[1].title, "menu.settings.disabled")
				helpers.assert_eq(before[2].title, "menu.settings.no_modifier")
				helpers.assert_eq(before[3].title, "⇧ Shift")
				helpers.assert_eq(before[4].title, "⌘ Cmd")
				helpers.assert_eq(before[5].title, "⌥ Option")
				helpers.assert_eq(before[6].title, "⌃ Ctrl")
				helpers.assert_eq(before[7].title, "⇧⌘ Shift + Cmd")
				helpers.assert_eq(before[8].title, "⇧⌥ Shift + Option")
				helpers.assert_eq(before[6].checked, true)
				for _, row in ipairs(before) do helpers.assert_type(row.fn, "function") end
				frame[1].i18n = "button.cancel"
				helpers.assert_eq(f.manager.build_nav_modifier_menu()[1].title, "button.cancel")
				root.llm_modifier_picker_frame = nil
				helpers.assert_eq(f.manager.build_nav_modifier_menu(), {})
				helpers.assert_eq(f.calls.settings, 0)
				helpers.assert_eq(f.calls.runtime, 0)
				helpers.assert_eq(f.calls.save, 0)
			end, debug.traceback)
			root.llm_modifier_picker_frame = frame; frame[1].i18n = original
			if not ok then error(detail, 0) end
			local restored = f.manager.build_nav_modifier_menu()
			helpers.assert_eq(restored[1].title, "menu.settings.disabled")
			helpers.assert_eq(restored[3].fn(), true)
			helpers.assert_eq(f.state.llm_nav_modifiers, { "shift" })
		end)
	end)

	for _, section in ipairs({ "llm_generation_native_controls", "llm_after_model_boundary", "llm_after_profile_boundary" }) do
		helpers.it("refuses the actual missing " .. section .. " before native action delivery and repairs it", function()
			with_fixture({ parent_only = true }, function(f)
				local rebuild = f.top_level_callbacks().rebuild
				local menu = package.loaded["infra.manifest_menu"]
				local root, declaration = menu.get_root(), menu.get_array(section)
				helpers.assert_true(#declaration > 0)
				local before = rebuild()
				helpers.assert_true(#before > 0)
				local ok, detail = xpcall(function()
					root[section] = nil
					helpers.assert_nil(rebuild(), "the refused real LLM item exposes no submenu or native fallback")
					helpers.assert_eq(f.calls.runtime, 0)
					helpers.assert_eq(f.calls.save, 0)
					helpers.assert_eq(f.calls.settings, 0)
				end, debug.traceback)
				root[section] = declaration
				if not ok then error(detail, 0) end
				helpers.assert_eq(require("test.menu_native_child_rows").hierarchy(rebuild()),
					require("test.menu_native_child_rows").hierarchy(before))
			end)
		end)
	end
end)


local function with_fixed_controls_locale(locale, scenario)
	local previous, previous_hs, previous_getenv = {}, rawget(_G, "hs"), os.getenv
	for name, value in pairs(package.loaded) do previous[name] = value end
	local native, owner, receipt, acquired, scratch, fresh_bridge
	local ok, err = pcall(function()
		local driver = helpers.driver_root():gsub("/+$", "")
		local shared = assert(driver:match("^(.*)/[^/]+$")) .. "/_shared/lua"
		require("tests.support.module_isolation").purge(driver, shared)
		helpers.load_with_stubs("infra.logger")
		scratch = assert(os.tmpname())
		assert(os.remove(scratch))
		assert(hs.fs.mkdir(scratch))
		assert(hs.fs.mkdir(scratch .. "/metrics"))
		local ledger = assert(io.open(scratch .. "/metrics/karabiner_kc.log", "wb")); assert(ledger:close())
		local bootstrap = assert(io.open(scratch .. "/paths.toml", "wb"))
		assert(bootstrap:write('ConfigDirPath = "' .. scratch .. '/"\n'))
		assert(bootstrap:close())
		os.getenv = function(name)
			if name == "ERGOPTI_PATHS_FILE" then return scratch .. "/paths.toml" end
			return previous_getenv(name)
		end
		local paths = require("infra.config_paths")
		helpers.assert_eq(paths.init(scratch .. "/"), true)
		helpers.assert_eq(paths.get_config_dir(), scratch .. "/")
		package.loaded["infra.i18n"] = nil
		native = require("infra.i18n")
		local backend = require("infra.locale")
		native.set_locale_injector(function(code) backend.set_locale(code) end)
		native.init()
		owner = { pending = function() return false end }
		acquired = native.scope_acquire(owner)
		helpers.assert_eq(acquired, true)
		receipt = native.scope_capture(owner)
		helpers.assert_not_nil(receipt)
		helpers.assert_eq(native.scope_apply(owner, receipt, locale), true)
		scenario(native)
	end)
	local restored, released, forgotten = true, true, true
	if receipt then restored = native.scope_restore(owner, receipt) == true end
	if acquired then released = native.scope_release(owner) == true end
	if receipt then forgotten = native.scope_forget(owner, receipt) == true end
	local cleanup_ok, cleanup_error = pcall(function()
		fresh_bridge = fresh_bridge or package.loaded["modules.keystats.kc_bridge"]
		if fresh_bridge and not rawequal(fresh_bridge, previous["modules.keystats.kc_bridge"]) then fresh_bridge.stop() end
		local scheduler = package.loaded["adapters.timer_scheduler"]
		if scheduler and not rawequal(scheduler, previous["adapters.timer_scheduler"]) then
			helpers.assert_eq(scheduler.cancelAll(), true)
			helpers.assert_eq(scheduler.activeCount(), 0)
		end
		if scratch then
			os.remove(scratch .. "/metrics/karabiner_kc.log")
			os.remove(scratch .. "/paths.toml")
			if hs.fs.attributes(scratch .. "/hammerspoon") then assert(hs.fs.rmdir(scratch .. "/hammerspoon")) end
			if hs.fs.attributes(scratch .. "/metrics") then assert(hs.fs.rmdir(scratch .. "/metrics")) end
			assert(hs.fs.rmdir(scratch))
		end
	end)
	for name in pairs(package.loaded) do if previous[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(previous) do package.loaded[name] = value end
	_G.hs = previous_hs
	os.getenv = previous_getenv
	helpers.assert_eq(rawequal(os.getenv, previous_getenv), true)
	for name, value in pairs(previous) do helpers.assert_eq(rawequal(package.loaded[name], value), true, name) end
	helpers.assert_eq(cleanup_ok, true, tostring(cleanup_error))
	helpers.assert_eq(restored, true, "actual translator inverse restores before releasing ownership")
	helpers.assert_eq(released, true)
	helpers.assert_eq(forgotten, true)
	if not ok then error(err, 0) end
end


local function complete_control_corpus()
	local file = assert(io.open(helpers.shared("tests/corpus/menus/llm_complete_control_frames.json"), "rb"))
	local bytes = assert(file:read("*a")); assert(file:close())
	return assert(require("adapters.json_codec").decode(bytes))
end

helpers.describe("Complete LLM generation: independent native images", function()
	for _, locale in ipairs({ "en", "fr" }) do
		helpers.it("preserves the complete generation image and real callbacks in " .. locale, function()
			with_fixed_controls_locale(locale, function(native)
				with_fixture({ parent_only = true, translate = native.get }, function(f)
					local expected = complete_control_corpus().generation
					local parent = assert(find_item(f.top_level_callbacks().rebuild(), expected[locale].parent))
					helpers.assert_eq(#parent.menu, expected.count)
					for index, title in ipairs(expected[locale].prefix) do helpers.assert_eq(parent.menu[index].title, title) end
					helpers.assert_eq(#parent.menu[1].menu, 10)
					for index, title in ipairs(expected[locale].choices) do
						local choice = parent.menu[1].menu[index]
						helpers.assert_eq(choice.title, title)
						helpers.assert_type(choice.fn, "function")
						helpers.assert_eq(choice.checked, index == 3)
					end
					for _, index in ipairs(expected.callback_positions) do helpers.assert_type(parent.menu[index].fn, "function") end
					helpers.assert_nil(parent.menu[1].fn)
					helpers.assert_nil(parent.menu[3].fn)
					helpers.assert_eq(parent.menu[6].checked, true)
					helpers.assert_eq(parent.menu[13].checked, false)
					helpers.assert_eq(f.calls.save, 0); helpers.assert_eq(f.calls.runtime, 0)
					helpers.assert_eq(parent.menu[2].fn(), true)
					helpers.assert_eq(f.state.llm_num_predictions, 1)
					helpers.assert_eq(f.runtime.llm_num_predictions, 1)
					helpers.assert_eq(f.persisted().llm_num_predictions, 1)
				end)
			end)
		end)
	end
	for _, section in ipairs({ "llm_generation_count_control", "llm_generation_count_reset_control", "llm_generation_temperature_controls" }) do
		helpers.it("refuses withdrawn " .. section .. " without effects and repairs its actual owner", function()
			with_fixture({ parent_only = true }, function(f)
				local rebuild, menu = f.top_level_callbacks().rebuild, package.loaded["infra.manifest_menu"]
				local root, declaration = menu.get_root(), menu.get_array(section)
				local before = rebuild()
				helpers.assert_true(#declaration > 0 and #before > 0)
				local ok, detail = xpcall(function()
					root[section] = nil
					helpers.assert_nil(rebuild())
					helpers.assert_eq(f.calls.runtime, 0); helpers.assert_eq(f.calls.save, 0); helpers.assert_eq(f.calls.settings, 0)
				end, debug.traceback)
				root[section] = declaration
				if not ok then error(detail, 0) end
				helpers.assert_eq(require("test.menu_native_child_rows").hierarchy(rebuild()), require("test.menu_native_child_rows").hierarchy(before))
			end)
		end)
	end
end)


helpers.describe("Complete LLM outer boundary context", function()
	helpers.it("keeps the actual model and profile boundaries in the complete parent", function()
		with_fixture({parent_only = true}, function(fixture)
			local callbacks = fixture.top_level_callbacks()
			local rows = callbacks.rebuild()
			local model
			for index, row in ipairs(rows) do
				if type(row.title) == "string" and row.title:find("menu.llm.model_label", 1, true) then model = index end
			end
			helpers.assert_type(model, "number")
			helpers.assert_eq(rows[model + 1].title, "-", "the original after-model boundary remains")
			helpers.assert_eq(rows[model + 3].title, "-", "the original after-profile boundary remains")
			local renderer = package.loaded["infra.manifest_menu"]
			local fragment = renderer.get_array("llm_after_model_boundary")
			local original = fragment[1]
			local ok, err = xpcall(function()
				fragment[1] = {type = "command", id = "unbound_actual_model_boundary", i18n = "button.cancel"}
				helpers.assert_nil(callbacks.rebuild(), "unbound complete-parent boundary refuses construction")
			end, debug.traceback)
			fragment[1] = original
			if not ok then error(err, 0) end
			helpers.assert_eq(callbacks.rebuild()[model + 1].title, "-", "exact original repairs the same whole context")
		end)
	end)

	helpers.it("materializes genuine selector DATA and retains exact completed MLX child references", function()
		local original_children, original_tail, source_graph, native_children, native_rows, native_graph
		with_fixture({parent_only = true, native_mlx_port = true, observe_model_children = function(children)
			original_children, original_tail = children, children[#children]
			source_graph = capture_row_graph(children)
		end, observe_native_model_children = function(children, data)
			helpers.assert_true(rawequal(data, original_children), "the genuine materializer consumes the exact producer DATA")
			native_children = children
			native_rows = {}; for index, row in ipairs(children) do native_rows[index] = row end
			native_graph = capture_row_graph(native_rows)
		end}, function(fixture)
			local rows = fixture.top_level_callbacks().rebuild()
			helpers.assert_type(rows, "table", table.concat(fixture.errors, "\n"))
			local model
			for _, row in ipairs(rows) do
				if type(row.title) == "string" and row.title:find("menu.llm.model_label", 1, true) then model = row end
			end
			helpers.assert_type(model, "table")
			helpers.assert_true(rawequal(model.menu, native_children), "the genuine emitted native array reaches its native parent")
			helpers.assert_true(not rawequal(model.menu, original_children), "DATA is materialized before native publication")
			assert_row_graph_unchanged(source_graph)
			assert_row_graph_unchanged(native_graph)
			for index, original in ipairs(native_rows) do
				helpers.assert_true(rawequal(model.menu[index], original), "each genuine emitted native row remains exact")
				helpers.assert_nil(original.label); helpers.assert_nil(original.action); helpers.assert_nil(original.items)
			end
			helpers.assert_eq(model.menu[1].title, original_children[1].label, "the independently declared head caption remains")
			helpers.assert_true(rawequal(model.menu[1].fn, original_children[1].action), "the genuine source command closure remains exact")
			local retained_tail = model.menu[#native_rows]
			helpers.assert_true(rawequal(retained_tail, native_rows[#native_rows]))
			helpers.assert_eq(retained_tail.title, original_tail.label, "the actual source tail caption reaches native output")
			helpers.assert_true(rawequal(retained_tail.fn, original_tail.action)); helpers.assert_true(rawequal(retained_tail.image, original_tail.image))
			helpers.assert_eq(model.menu[#native_rows + 1].title, "-", "the real leading port boundary follows the genuine tail")
			helpers.assert_true(model.menu[#native_rows + 2].title:find("menu.llm.mlx_port", 1, true) ~= nil)
			helpers.assert_type(model.menu[#native_rows + 2].fn, "function")
			local compose = assert(package.loaded["infra.manifest_menu"].native_composition("macos_download_root"))
			helpers.assert_eq(compose({download = {}, body = rows}), true, "the actual completed subtree meets strict native publication")
			helpers.assert_eq(fixture.calls.save, 0); helpers.assert_eq(fixture.calls.runtime, 0)
		end)
	end)
end)


helpers.describe("Complete LLM MLX canonical context admission", function()
	local function model_row(rows)
		for _, row in ipairs(rows or {}) do
			if type(row.title) == "string" and row.title:find("menu.llm.model_label", 1, true) then return row end
		end
	end

	helpers.it("retains valid empty selector DATA and publishes only the genuine native port action", function()
		local original_children, native_children
		with_fixture({parent_only = true, native_mlx_port = true, observe_model_children = function(children)
			-- Exercise the established empty consumer image after the genuine selector ran.
			original_children = children
			for index = #children, 1, -1 do children[index] = nil end
		end, observe_native_model_children = function(children, data)
			helpers.assert_true(rawequal(data, original_children))
			helpers.assert_eq(#children, 0, "the genuine materializer emits the original empty context")
			native_children = children
		end}, function(fixture)
			local model = assert(model_row(fixture.top_level_callbacks().rebuild()))
			helpers.assert_true(rawequal(model.menu, native_children), "the actual emitted native array remains the parent's array")
			helpers.assert_true(not rawequal(model.menu, original_children)); helpers.assert_eq(#original_children, 0, "port append never writes into producer DATA")
			helpers.assert_eq(#model.menu, 1, "a genuinely empty consumer context has no leading separator")
			helpers.assert_true(model.menu[1].title:find("menu.llm.mlx_port", 1, true) ~= nil)
			helpers.assert_type(model.menu[1].fn, "function")
			helpers.assert_nil(model.menu[1].action); helpers.assert_nil(model.menu[1].label)
			helpers.assert_eq(fixture.calls.save, 0); helpers.assert_eq(fixture.calls.runtime, 0)
		end)
	end)

	helpers.it("retains deep emitted native tail identity while strict publication refuses excess depth", function()
		local tail, nested, source_graph, native_graph, native_children, original_count
		local image, delivered = {}, 0
		local action = function() delivered = delivered + 1 end
		with_fixture({parent_only = true, native_mlx_port = true, observe_model_children = function(children)
			source_graph = capture_row_graph(children)
		end, observe_native_model_children = function(children)
			native_children, original_count = children, #children
			tail = children[original_count]
			-- A bounded adversarial native image must retain identity but never pass the depth policy.
			nested = {title = "owned deep leaf", fn = action, image = image}
			for _ = 1, 12 do nested = {title = "owned deep parent", menu = {nested}} end
			tail.menu = {nested}; tail.fn = nil; tail.image = image
			native_graph = capture_row_graph({tail})
		end}, function(fixture)
			local rows = fixture.top_level_callbacks().rebuild()
			local model = assert(model_row(rows))
			local retained = model.menu[original_count]
			helpers.assert_true(rawequal(model.menu, native_children)); helpers.assert_true(rawequal(retained, tail))
			helpers.assert_true(rawequal(retained.menu[1], nested)); helpers.assert_true(rawequal(retained.image, image))
			helpers.assert_nil(retained.fn, "a submenu parent never carries the unreachable command")
			local leaf = nested; for _ = 1, 12 do leaf = leaf.menu[1] end
			helpers.assert_true(rawequal(leaf.fn, action)); helpers.assert_true(rawequal(leaf.image, image))
			assert_row_graph_unchanged(source_graph); assert_row_graph_unchanged(native_graph)
			helpers.assert_eq(model.menu[#model.menu - 1].title, "-")
			helpers.assert_type(model.menu[#model.menu].fn, "function")
			local publication_graph = capture_row_graph(rows)
			local compose = assert(package.loaded["infra.manifest_menu"].native_composition("macos_download_root"))
			helpers.assert_eq(compose({download = {}, body = rows}), false, "twelve native levels exceed the actual shared depth policy")
			assert_row_graph_unchanged(publication_graph); assert_row_graph_unchanged(source_graph)
			local original_menu = tail.menu
			local repaired, repair_error = xpcall(function()
				tail.menu = {leaf}
				local repaired_graph = capture_row_graph(rows)
				helpers.assert_eq(compose({download = {}, body = rows}), true, "the same complete native subtree admits after only excess depth is removed")
				assert_row_graph_unchanged(repaired_graph); assert_row_graph_unchanged(source_graph)
			end, debug.traceback)
			tail.menu = original_menu
			if not repaired then error(repair_error, 0) end
			assert_row_graph_unchanged(publication_graph); assert_row_graph_unchanged(native_graph)
			helpers.assert_eq(compose({download = {}, body = rows}), false, "restoring the exact excess-depth subtree restores the strict refusal")
			assert_row_graph_unchanged(publication_graph); assert_row_graph_unchanged(source_graph)
			helpers.assert_eq(delivered, 0, "neither handoff nor refused publication delivers the original leaf command")
			helpers.assert_eq(fixture.calls.save, 0); helpers.assert_eq(fixture.calls.runtime, 0)
		end)
	end)

	helpers.it("refuses a malformed actual tail without effects and repairs genuine construction", function()
		local malformed = true
		with_fixture({parent_only = true, native_mlx_port = true, observe_model_children = function(children)
			if malformed then children[#children].label = nil end
		end}, function(fixture)
			local rebuild = fixture.top_level_callbacks().rebuild
			helpers.assert_nil(rebuild())
			helpers.assert_eq(fixture.calls.save, 0); helpers.assert_eq(fixture.calls.runtime, 0); helpers.assert_eq(fixture.calls.settings, 0)
			malformed = false
			helpers.assert_type(model_row(rebuild()), "table")
		end)
	end)

	helpers.it("refuses a withdrawn or unbound port declaration and restores exact genuine ownership", function()
		with_fixture({parent_only = true, native_mlx_port = true}, function(fixture)
			local rebuild = fixture.top_level_callbacks().rebuild
			local renderer = package.loaded["infra.manifest_menu"]
			local root, fragment = renderer.get_root(), renderer.get_array("llm_mlx_port_frame")
			local first = fragment[2]
			local ok, err = xpcall(function()
				root.llm_mlx_port_frame = nil; helpers.assert_nil(rebuild())
				root.llm_mlx_port_frame = fragment
				fragment[2] = {type = "command", id = "withdrawn_actual_mlx_command", i18n = "button.cancel"}
				helpers.assert_nil(rebuild())
				helpers.assert_eq(fixture.calls.save, 0); helpers.assert_eq(fixture.calls.runtime, 0); helpers.assert_eq(fixture.calls.settings, 0)
			end, debug.traceback)
			root.llm_mlx_port_frame = fragment; fragment[2] = first
			if not ok then error(err, 0) end
			helpers.assert_type(model_row(rebuild()), "table")
		end)
	end)

	for _, raises in ipairs({false, true}) do
		helpers.it("restores actual selector/API dependency identities after " .. (raises and "raise" or "success"), function()
			local prior = {}; for name, value in pairs(package.loaded) do prior[name] = value end
			local previous_hs = _G.hs
			local ok, err = pcall(function()
				with_fixture({parent_only = true, native_mlx_port = true}, function(fixture)
					helpers.assert_type(model_row(fixture.top_level_callbacks().rebuild()), "table")
					if raises then error("intentional genuine context release") end
				end)
			end)
			helpers.assert_eq(ok, not raises)
			if raises then helpers.assert_true(tostring(err):find("intentional genuine context release", 1, true) ~= nil) end
			helpers.assert_true(rawequal(_G.hs, previous_hs))
			for name, value in pairs(prior) do helpers.assert_true(rawequal(package.loaded[name], value), name) end
			for name in pairs(package.loaded) do helpers.assert_not_nil(prior[name], "no actual fresh dependency survives: " .. name) end
		end)
	end
end)


helpers.describe("Complete LLM actual API raw dependency restoration", function()
	for _, raises in ipairs({false, true}) do
		helpers.it("restores raw absent, false and genuine dependency states after " .. (raises and "raise" or "success"), function()
			local name = "modules.llm.api_mlx_inference"
			local original = rawget(package.loaded, name)
			local genuine
			local ok, err = xpcall(function()
				with_fixture({parent_only = true, native_mlx_port = true}, function(fixture)
					helpers.assert_type(fixture.top_level_callbacks().rebuild(), "table")
					genuine = rawget(package.loaded, name)
					helpers.assert_type(genuine, "table")
				end)
				for _, cell in ipairs({{}, {value = false}, {value = genuine}}) do
					local prior = rawget(cell, "value")
					package.loaded[name] = prior
					local completed, detail = pcall(function()
						with_fixture({parent_only = true, native_mlx_port = true}, function(fixture)
							helpers.assert_type(fixture.top_level_callbacks().rebuild(), "table")
							helpers.assert_type(rawget(package.loaded, name), "table", "the genuine API actually requires its native dependency")
							if raises then error("intentional raw dependency release") end
						end)
					end)
					helpers.assert_eq(completed, not raises)
					if raises then helpers.assert_true(tostring(detail):find("intentional raw dependency release", 1, true) ~= nil) end
					helpers.assert_true(rawequal(rawget(package.loaded, name), prior), "exact original raw dependency state is restored")
				end
			end, debug.traceback)
			package.loaded[name] = original
			if not ok then error(err, 0) end
		end)
	end
end)
