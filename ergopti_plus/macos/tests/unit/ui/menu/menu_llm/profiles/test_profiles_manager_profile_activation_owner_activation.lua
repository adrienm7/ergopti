--- tests/unit/ui/menu/menu_llm/profiles/test_profiles_manager_profile_activation_owner_activation.lua

-- =============================================================================
-- MODULE: Profiles Manager Explicit-Intent Ownership
-- DESCRIPTION:
-- Proves that clone, create, and active-profile deletion route their resulting
-- profile selection through the transactional model-switcher owner, and that
-- Auto-detect propagates the same owner's exact terminal result.
-- =============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.ui.menu.menu_llm.profiles.profiles_manager_profile_activation_owner_fixture"] = nil
local Fixture = require("tests.support.ui.menu.menu_llm.profiles.profiles_manager_profile_activation_owner_fixture")
local find_row = Fixture.find_row
local with_profiles_fixture = Fixture.with_profiles_fixture





helpers.describe("HS-029 profiles manager activation ownership", function()
	for _, setter in ipairs({"registry", "active"}) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("HS-012 refuses a live manager after initial " .. setter
				.. " setter " .. mode, function()
				local options = {
					active_profile = "user_custom",
					user_profiles = {{id = "user_custom", label = "Custom"}},
				}
				options[setter .. "_setter_mode"] = mode
				with_profiles_fixture(options, function(fixture)
					helpers.assert_eq(fixture.manager, nil)
					if setter == "registry" then
						helpers.assert_eq(fixture.active_calls(), 0,
							"active identity cannot follow a refused registry")
					end
					helpers.assert_true(fixture.errors() >= 2)
				end)
			end)
		end
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("HS-012 stops edited-profile publication after active setter "
			.. mode, function()
			with_profiles_fixture({
				active_profile = "user_custom",
				active_setter_mode = mode,
				active_setter_occurrence = 2,
				user_profiles = {{id = "user_custom", label = "Custom"}},
				edit_update = {id = "user_custom", label = "Updated"},
			}, function(fixture)
				local rows = fixture.manager.get_menu_item().menu
				local custom = find_row(rows, "Custom")
				local edit = find_row(custom.items, "menu.profiles.edit_profile")
				helpers.assert_type(edit.action, "function")
				fixture.dispatch(edit)
				helpers.assert_eq(#fixture.runtime_profiles, 3,
					"the refused active identity must be reasserted exactly")
				helpers.assert_eq(fixture.state.llm_user_profiles[1].label, "Custom")
				helpers.assert_eq(fixture.runtime_registry()[1].label, "Custom")
				helpers.assert_eq(fixture.direct_saves(), 0,
					"a refused identity cannot publish edited preferences")
				helpers.assert_eq(fixture.direct_menus(), 0)
				helpers.assert_eq(fixture.notifications(), 0)
				helpers.assert_true(fixture.errors() >= 1)
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("HS-012 rolls back edited registry setter " .. mode, function()
			with_profiles_fixture({
				active_profile = "user_custom",
				registry_setter_mode = mode,
				registry_setter_occurrence = 2,
				user_profiles = {{id = "user_custom", label = "Custom"}},
				edit_update = {id = "user_custom", label = "Updated"},
			}, function(fixture)
				local rows = fixture.manager.get_menu_item().menu
				local custom = find_row(rows, "Custom")
				local edit = find_row(custom.items, "menu.profiles.edit_profile")
				helpers.assert_eq(fixture.dispatch(edit), true,
					"the editor timer owns dispatch even when its callback rejects")
				helpers.assert_eq(fixture.registry_calls(), 3)
				helpers.assert_eq(fixture.active_calls(), 1,
					"active publication cannot follow a refused candidate registry")
				helpers.assert_eq(fixture.state.llm_user_profiles[1].label, "Custom")
				helpers.assert_eq(fixture.runtime_registry()[1].label, "Custom")
				helpers.assert_eq(fixture.direct_saves(), 0)
				helpers.assert_eq(fixture.direct_menus(), 0)
			end)
		end)
	end

	for _, boundary in ipairs({"save", "menu"}) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("HS-012 rolls back edited profile after " .. boundary
				.. " boundary " .. mode, function()
			local options = {
				active_profile = "user_custom",
				user_profiles = {{id = "user_custom", label = "Custom"}},
				edit_update = {id = "user_custom", label = "Updated"},
			}
			options[boundary .. "_mode"] = mode
			with_profiles_fixture(options, function(fixture)
				local rows = fixture.manager.get_menu_item().menu
				local custom = find_row(rows, "Custom")
				local edit = find_row(custom.items, "menu.profiles.edit_profile")
				helpers.assert_eq(fixture.dispatch(edit), true)
				helpers.assert_eq(fixture.state.llm_user_profiles[1].label, "Custom")
				helpers.assert_eq(fixture.runtime_registry()[1].label, "Custom")
				helpers.assert_eq(fixture.active_calls(),
					boundary == "save" and 4 or 5,
					"rollback must reassert the prior active identity after opaque callbacks")
				helpers.assert_eq(fixture.notifications(), 0)
				if boundary == "save" then
					helpers.assert_eq(fixture.direct_saves(), 2)
					helpers.assert_eq(fixture.direct_menus(), 0)
				else
					helpers.assert_eq(fixture.direct_saves(), 2)
					helpers.assert_eq(fixture.direct_menus(), 2)
				end
			end)
		end)
		end
	end

	helpers.it("HS-012 fences a nested edit for the full opaque save boundary", function()
		local nested_dispatched = false
		with_profiles_fixture({
			active_profile = "user_custom",
			user_profiles = {{id = "user_custom", label = "Custom"}},
			edit_update = {id = "user_custom", label = "Updated"},
			save_hook = function(manager)
				local rows = manager.get_menu_item().menu
				local updated = find_row(rows, "Updated")
				local edit = find_row(updated.items, "menu.profiles.edit_profile")
				nested_dispatched = edit.action()
			end,
		}, function(fixture)
			local rows = fixture.manager.get_menu_item().menu
			local custom = find_row(rows, "Custom")
			local edit = find_row(custom.items, "menu.profiles.edit_profile")
			helpers.assert_eq(fixture.dispatch(edit), true)
			helpers.assert_eq(nested_dispatched, false,
				"the nested edit must be refused before it can acquire a timer")
			helpers.assert_eq(fixture.editor_calls(), 1,
				"the nested edit must stop before reopening its opaque editor callback")
			helpers.assert_eq(fixture.state.llm_user_profiles[1].label, "Updated")
			helpers.assert_eq(fixture.runtime_registry()[1].label, "Updated")
			helpers.assert_eq(fixture.notifications(), 1)
		end)
	end)

	for _, setter in ipairs({"registry", "active"}) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("HS-012 rolls back cloned-profile edit " .. setter
				.. " setter " .. mode, function()
				local options = {edit_update_label = "Updated clone"}
				options[setter .. "_setter_mode"] = mode
				options[setter .. "_setter_occurrence"] = setter == "registry" and 3 or 2
				with_profiles_fixture(options, function(fixture)
					local rows = fixture.manager.get_menu_item().menu
					local clone = find_row(rows, "menu.profiles.clone_builtin")
					helpers.assert_eq(fixture.dispatch(clone), true)
					helpers.assert_eq(#fixture.state.llm_user_profiles, 1)
					helpers.assert_true(
						fixture.state.llm_user_profiles[1].label ~= "Updated clone")
					helpers.assert_true(
						fixture.runtime_registry()[1].label ~= "Updated clone")
					helpers.assert_eq(fixture.direct_saves(), 0)
					helpers.assert_eq(fixture.direct_menus(), 0)
					if setter == "registry" then
						helpers.assert_eq(fixture.registry_calls(), 4)
					else
						helpers.assert_eq(fixture.active_calls(), 3)
					end
				end)
			end)
		end
	end

	helpers.it("HS-029 routes cloned-profile activation through the intent owner", function()
		with_profiles_fixture({}, function(fixture)
			local rows = fixture.manager.get_menu_item().menu
			local clone = find_row(rows, "menu.profiles.clone_builtin")
			helpers.assert_type(clone.action, "function")
			fixture.dispatch(clone)
			helpers.assert_eq(#fixture.selections, 1)
			helpers.assert_true(fixture.selections[1].id:match("^user_basic_") ~= nil)
			helpers.assert_eq(fixture.selections[1].registry_size, 1,
				"the new profile must be resolvable before activation")
			helpers.assert_eq(fixture.direct_saves(), 0)
			helpers.assert_eq(fixture.direct_menus(), 0)
		end)
	end)

	helpers.it("HS-029 routes created-profile activation through the intent owner", function()
		with_profiles_fixture({}, function(fixture)
			local rows = fixture.manager.get_menu_item().menu
			local create = find_row(rows, "menu.profiles.create_profile")
			helpers.assert_type(create.action, "function")
			fixture.dispatch(create)
			helpers.assert_eq(fixture.selections, {{id = "user_created", registry_size = 1}})
			helpers.assert_eq(fixture.state.llm_active_profile, "user_created")
			helpers.assert_eq(fixture.direct_saves(), 0)
			helpers.assert_eq(fixture.direct_menus(), 0)
		end)
	end)

	helpers.it("HS-029 commits basic before removing the active custom profile", function()
		with_profiles_fixture({
			active_profile = "user_custom",
			user_profiles = {{id = "user_custom", label = "Custom"}},
		}, function(fixture)
			local rows = fixture.manager.get_menu_item().menu
			local custom = find_row(rows, "Custom")
			local delete = find_row(custom.items, "menu.profiles.delete_profile")
			helpers.assert_type(delete.action, "function")
			fixture.dispatch(delete)
			helpers.assert_eq(fixture.selections, {{id = "basic", registry_size = 1}},
				"the fallback intent must commit while the old profile is still resolvable")
			helpers.assert_eq(fixture.state.llm_active_profile, "basic")
			helpers.assert_eq(#fixture.state.llm_user_profiles, 0)
			helpers.assert_eq(fixture.shortcut_clears(), 1)
			helpers.assert_eq(fixture.direct_saves(), 1,
				"registry deletion remains a separate persistence boundary")
			helpers.assert_eq(fixture.direct_menus(), 1)
		end)
	end)

	helpers.it("HS-029 preserves an active profile when fallback intent is refused", function()
		local profile = {id = "user_custom", label = "Custom"}
		with_profiles_fixture({
			active_profile = "user_custom",
			selection_result = false,
			user_profiles = {profile},
		}, function(fixture)
			local custom = find_row(fixture.manager.get_menu_item().menu, "Custom")
			local delete = find_row(custom.items, "menu.profiles.delete_profile")
			helpers.assert_type(delete.action, "function")
			helpers.assert_eq(fixture.dispatch(delete), false)
			helpers.assert_eq(fixture.selections, {{id = "basic", registry_size = 1}})
			helpers.assert_eq(fixture.state.llm_active_profile, "user_custom")
			helpers.assert_eq(fixture.state.llm_user_profiles, {profile})
			helpers.assert_eq(fixture.shortcut_clears(), 0)
			helpers.assert_eq(fixture.direct_saves(), 0)
			helpers.assert_eq(fixture.direct_menus(), 0)
		end)
	end)

	helpers.it("HS-031 propagates an Auto-detect refusal from the transaction owner", function()
		with_profiles_fixture({recommendation_result = false}, function(fixture)
			local rows = fixture.manager.get_menu_item().menu
			local auto_detect = find_row(rows, "menu.profiles.auto_detect")
			helpers.assert_type(auto_detect.action, "function")
			helpers.assert_eq(fixture.dispatch(auto_detect), false)
			helpers.assert_eq(#fixture.recommendations, 1)
			helpers.assert_eq(fixture.recommendations[1].force_dialog, true)
			helpers.assert_eq(fixture.recommendations[1].dialog_title,
				"menu.profiles.recommended_profile")
		end)
	end)

	helpers.it("HS-031 propagates a built-in profile refusal from the transaction owner", function()
		with_profiles_fixture({selection_result = false}, function(fixture)
			local rows = fixture.manager.get_menu_item().menu
			local basic = find_row(rows, "Basic")
			helpers.assert_type(basic.action, "function")
			helpers.assert_eq(fixture.dispatch(basic), false)
			helpers.assert_eq(fixture.selections, {{id = "basic", registry_size = 0}})
		end)
	end)

	helpers.it("HS-031 propagates a cloned-profile activation refusal", function()
		with_profiles_fixture({selection_result = false}, function(fixture)
			local rows = fixture.manager.get_menu_item().menu
			local clone = find_row(rows, "menu.profiles.clone_builtin")
			helpers.assert_type(clone.action, "function")
			helpers.assert_eq(fixture.dispatch(clone), false)
			helpers.assert_eq(#fixture.selections, 1)
			helpers.assert_eq(fixture.selections[1].registry_size, 1)
			helpers.assert_eq(fixture.state.llm_active_profile, "basic")
		end)
	end)

	helpers.it("HS-031 makes No Model Auto-detect visibly fail through the real owners", function()
		with_profiles_fixture({model = "", real_recommendation = true}, function(fixture)
			local rows = fixture.manager.get_menu_item().menu
			local auto_detect = find_row(rows, "menu.profiles.auto_detect")
			helpers.assert_type(auto_detect.action, "function")
			helpers.assert_eq(fixture.dispatch(auto_detect), false)
			helpers.assert_eq(fixture.state.llm_active_profile, "basic")
			helpers.assert_eq(fixture.notifications(), 1)
			helpers.assert_eq(fixture.direct_saves(), 0)
			helpers.assert_eq(fixture.direct_menus(), 0)
		end)
	end)
end)

-- Independent child presentation consumes the actual provider and native transactions.
helpers.describe("shared custom profile child: native macOS owner", function()
	local Renderer = require("menu.renderer")
	local Json = require("json")
	local function read_json(relative)
		local file = assert(io.open(helpers.shared(relative), "rb"))
		local value = Json.decode(file:read("*a")); file:close()
		return value
	end
	local expected = read_json("tests/corpus/menus/custom_profile_children.json")
	local function with_child(options, body)
		options = options or {}
		options.user_profiles = {{ id = "user_custom", label = "Custom" }}
		with_profiles_fixture(options, function(fixture)
			local document = read_json("modules/menu/menu_manifest.json")
			local i18n = package.loaded["infra.i18n"]
			local renderer = assert(Renderer.new({
				platform = "hs", manifest_path = function() return helpers.shared("modules/menu/menu_manifest.json") end,
				json_decode = function() return document end, i18n = i18n, logger = package.loaded["infra.logger"],
			}))
			local binding = package.loaded["infra.manifest_menu"]
			binding.template_rows, binding.render_rows = renderer.template_rows, renderer.render_rows
			local function child()
				local rows = fixture.manager.get_menu_item().menu
				for _, row in ipairs(rows) do if row.title == "Custom" then return row.menu or {} end end
				error("native custom profile parent disappeared")
			end
			body(fixture, child, document, i18n)
		end)
	end
	local function captions(rows)
		local result = {}
		for _, row in ipairs(rows) do result[#result + 1] = row.title end
		return result
	end
	helpers.it("custom-profile-child: exact independent declared child and actual native order", function()
		with_child({}, function(fixture, child, document)
			helpers.assert_eq(document[expected.section], expected.declaration)
			helpers.assert_eq(captions(child()), { "menu.profiles.use_profile", "menu.profiles.shortcut_prefix", "-", "menu.profiles.edit_profile", "menu.profiles.delete_profile" })
			helpers.assert_eq(child()[1].checked, false)
			helpers.assert_eq(child()[1].fn(), true)
			helpers.assert_eq(fixture.selections[1].id, "user_custom")
			helpers.assert_eq(child()[1].checked, true, "fresh native active owner supplies the shared checkbox")
		end)
	end)
	helpers.it("custom-profile-child: actual refused Use receipt remains false", function()
		with_child({selection_result = false}, function(fixture, child)
			helpers.assert_eq(child()[1].fn(), false)
			helpers.assert_eq(fixture.state.llm_active_profile, "basic")
			helpers.assert_eq(#fixture.selections, 1)
		end)
	end)
	helpers.it("custom-profile-child: source order and caption changes flow through actual menu", function()
		with_child({}, function(fixture, child, document)
			local rows = document[expected.section]
			rows[1].i18n = "button.cancel"
			rows[4], rows[5] = rows[5], rows[4]
			helpers.assert_eq(captions(child()), { "button.cancel", "menu.profiles.shortcut_prefix", "-", "menu.profiles.delete_profile", "menu.profiles.edit_profile" })
			helpers.assert_eq(child()[1].fn(), true)
			helpers.assert_eq(fixture.selections[1].id, "user_custom")
		end)
	end)
	for _, mutation in ipairs({"missing", "wrong command", "hidden platform"}) do
		helpers.it("custom-profile-child: actual native publication refuses " .. mutation, function()
			with_child({}, function(fixture, child, document)
				if mutation == "missing" then document[expected.section] = nil
				elseif mutation == "wrong command" then document[expected.section][1].id = "absent_profile_owner"
				else for _, row in ipairs(document[expected.section]) do row.platforms = {"linux"} end end
				helpers.assert_eq(child(), {})
				helpers.assert_eq(#fixture.selections, 0)
				helpers.assert_eq(fixture.editor_calls(), 0)
				helpers.assert_eq(fixture.direct_saves(), 0)
			end)
		end)
	end
	helpers.it("custom-profile-child: retained declared leaves refuse after declaration withdrawal", function()
		with_child({}, function(fixture, child, document)
			local held = child()
			document[expected.section] = nil
			for _, index in ipairs({1, 2, 4, 5}) do helpers.assert_eq(held[index].fn(), false) end
			helpers.assert_eq(#fixture.selections, 0)
			helpers.assert_eq(fixture.editor_calls(), 0)
			helpers.assert_eq(fixture.direct_saves(), 0)
		end)
	end)
	helpers.it("custom-profile-child: native pause and removed profile refuse held delivery", function()
		with_child({}, function(fixture, child)
			local held = child()
			fixture.native_dependencies.script_control.is_paused = function() return true end
			for _, index in ipairs({1, 2, 4, 5}) do helpers.assert_eq(held[index].fn(), false) end
			local paused = child()
			for _, index in ipairs({1, 2, 4, 5}) do
				helpers.assert_true(paused[index].disabled); helpers.assert_nil(paused[index].fn)
			end
			fixture.native_dependencies.script_control.is_paused = function() return false end
			fixture.state.llm_user_profiles = {}
			for _, index in ipairs({1, 2, 4, 5}) do helpers.assert_eq(held[index].fn(), false) end
			helpers.assert_eq(#fixture.selections, 0); helpers.assert_eq(fixture.editor_calls(), 0)
			helpers.assert_eq(fixture.direct_saves(), 0)
		end)
	end)
	for _, owner in ipairs({"missing", "throw", "wrong receipt"}) do
		helpers.it("custom-profile-child: missing/refused native pause owner " .. owner, function()
			with_child({}, function(fixture, child)
				local held = child()
				if owner == "missing" then fixture.native_dependencies.script_control = nil
				elseif owner == "throw" then fixture.native_dependencies.script_control.is_paused = function() error("native pause read refused") end
				else fixture.native_dependencies.script_control.is_paused = function() return "false" end end
				for _, index in ipairs({1, 2, 4, 5}) do helpers.assert_eq(held[index].fn(), false) end
				helpers.assert_eq(#fixture.selections, 0); helpers.assert_eq(fixture.editor_calls(), 0)
			end)
		end)
	end
	helpers.it("custom-profile-child: all 21 original native captions stay translated", function()
		with_child({}, function(_, child, _, i18n)
			local languages = read_json("data/locale_order.json").order
			assert(#languages == 21, "the independent caption control must exercise 21 locales")
			for _, language in ipairs(languages) do
				local values = read_json("data/locales/" .. language .. ".json")
				i18n.get = function(key) return values[key] or key end
				helpers.assert_eq(captions(child()), { values["menu.profiles.use_profile"], values["menu.profiles.shortcut_prefix"], "-", values["menu.profiles.edit_profile"], values["menu.profiles.delete_profile"] }, language)
			end
		end)
	end)
	helpers.it("custom-profile-child: held native leaves require raw owner identity without equality dispatch", function()
		with_child({}, function(fixture, child)
			local original = fixture.state.llm_user_profiles[1]
			local equality_calls = 0
			local equal = { __eq = function() equality_calls = equality_calls + 1; return true end }
			setmetatable(original, equal)
			local held = child()
			local successor = setmetatable({ id = original.id, label = original.label }, equal)
			helpers.assert_eq(rawequal(original, successor), false)
			fixture.state.llm_user_profiles = { successor }
			local results = {}
			for _, index in ipairs({1, 2, 4, 5}) do results[#results + 1] = held[index].fn() end
			helpers.assert_eq(results, { false, false, false, false })
			helpers.assert_eq(equality_calls, 0, "a replaced owner cannot run an equality metamethod")
			helpers.assert_eq(#fixture.selections, 0)
			helpers.assert_eq(fixture.editor_calls(), 0)
			helpers.assert_eq(fixture.direct_saves(), 0)
		end)
	end)

end)


-- The native list and callbacks keep ownership; only the inert profile headings are declared.
helpers.describe("shared profile section headings: actual macOS provider", function()
	local Json = require("json")
	local function read_json(relative)
		local file = assert(io.open(helpers.shared(relative), "rb"))
		local value = Json.decode(file:read("*a")); file:close(); return value
	end
	local expected = read_json("tests/corpus/menus/profile_section_headings.json")
	local function with_headings(custom, body)
		with_profiles_fixture({user_profiles = custom and {{id="user_canonical",label="Canonical"}} or {}}, function(fixture)
			local document = read_json("modules/menu/menu_manifest.json")
			local i18n = package.loaded["infra.i18n"]
			i18n.section = function(key) return "— " .. i18n.get(key) .. " —" end
			local renderer = assert(require("menu.renderer").new({platform="hs",
				manifest_path=function() return helpers.shared("modules/menu/menu_manifest.json") end,
				json_decode=function() return document end,i18n=i18n,logger=package.loaded["infra.logger"]}))
			local binding = package.loaded["infra.manifest_menu"]
			binding.template_rows, binding.render_rows = renderer.template_rows, renderer.render_rows
			body({document=document,i18n=i18n,heading_index=3,other_platform="linux",
				caption=function(key) return i18n.section(key) end,
				decorate=function(value) return "— " .. value .. " —" end,
				rows=function() return fixture.manager.get_menu_item().menu end,
				untouched=function()
					helpers.assert_eq(#fixture.selections,0); helpers.assert_eq(fixture.direct_saves(),0)
					helpers.assert_eq(fixture.editor_calls(),0); helpers.assert_eq(fixture.registry_calls(),1, "the initial native registry sync is the only publication")
				end,fixture=fixture})
		end)
	end

	local function titles(rows)
		local result = {}
		for _, row in ipairs(rows) do result[#result + 1] = row.title end
		return result
	end
	local function position(rows, title)
		for index, row in ipairs(rows) do if row.title == title then return index, row end end
	end
	local sections = { "llm_profile_builtin_heading", "llm_profile_custom_heading" }
	helpers.it("profile-headings: handwritten shared declaration exactly matches the independent oracle", function()
		with_headings(true, function(f)
			for _, section in ipairs(sections) do helpers.assert_eq(f.document[section], expected.sections[section]) end
			local rows = f.rows()
			local builtin, builtin_row = position(rows, f.caption(expected.keys[1]))
			local custom, custom_row = position(rows, f.caption(expected.keys[2]))
			helpers.assert_type(builtin, "number"); helpers.assert_type(custom, "number")
			helpers.assert_true(builtin < custom)
			helpers.assert_true(builtin_row.disabled); helpers.assert_nil(builtin_row.fn)
			helpers.assert_true(custom_row.disabled); helpers.assert_nil(custom_row.fn)
			helpers.assert_eq(rows[custom - 1].title, "-")
			helpers.assert_eq(rows[custom + 1].title, "Canonical")
			f.untouched()
		end)
	end)
	helpers.it("profile-headings: empty native registry has no custom heading or custom separator", function()
		with_headings(false, function(f)
			local rows = f.rows()
			helpers.assert_not_nil(position(rows, f.caption(expected.keys[1])))
			helpers.assert_nil(position(rows, f.caption(expected.keys[2])))
			local before = titles(rows)
			f.document[sections[2]] = { {type="label",id="empty_registry_probe",i18n="button.cancel"} }
			helpers.assert_eq(titles(f.rows()), before, "custom presentation is conditional on the actual native registry")
			f.untouched()
		end)
	end)
	helpers.it("profile-headings: actual native menu consumes changed caption and shared custom source order", function()
		with_headings(true, function(f)
			local custom = f.document[sections[2]]
			local heading = custom[f.heading_index]
			heading.i18n = "button.cancel"
			custom[1], custom[f.heading_index] = heading, custom[1]
			local rows = f.rows()
			local index = position(rows, f.caption("button.cancel"))
			helpers.assert_type(index, "number")
			helpers.assert_eq(rows[index + 1].title, "-")
			helpers.assert_eq(rows[index + 2].title, "Canonical")
			helpers.assert_nil(position(rows, f.caption(expected.keys[2])))
			f.untouched()
		end)
	end)
	for _, mutation in ipairs({"missing", "empty", "invalid caption", "hidden platform"}) do
		helpers.it("profile-headings: no native fallback repairs " .. mutation .. " declaration", function()
			with_headings(true, function(f)
				for _, section in ipairs(sections) do
					if mutation == "missing" then f.document[section] = nil
					elseif mutation == "empty" then f.document[section] = {}
					elseif mutation == "invalid caption" then
						for _, row in ipairs(f.document[section]) do if row.i18n then row.i18n = false end end
					else for _, row in ipairs(f.document[section]) do row.platforms = {f.other_platform} end end
				end
				local rows = f.rows()
				helpers.assert_nil(position(rows, f.caption(expected.keys[1])))
				helpers.assert_nil(position(rows, f.caption(expected.keys[2])))
				helpers.assert_not_nil(position(rows, "Canonical"), "native data rows must survive absent presentation")
				f.untouched()
			end)
		end)
	end
	helpers.it("profile-headings: all 21 original caption pairs keep the platform decoration", function()
		with_headings(true, function(f)
			local count = 0
			for language, pair in pairs(expected.captions) do
				count = count + 1
				local values = read_json("data/locales/" .. language .. ".json")
				helpers.assert_eq({values[expected.keys[1]], values[expected.keys[2]]}, pair, language)
				f.i18n.get = function(key) return values[key] or key end
				local rows = f.rows()
				helpers.assert_not_nil(position(rows, f.decorate(pair[1])), language)
				helpers.assert_not_nil(position(rows, f.decorate(pair[2])), language)
			end
			helpers.assert_eq(count, 21)
			f.untouched()
		end)
	end)

	helpers.it("profile-headings: withdrawing inert declarations keeps the existing native activation receipt", function()
		with_headings(true, function(f)
			local _, builtin = position(f.rows(), "Advanced")
			helpers.assert_type(builtin.fn,"function")
			for _, section in ipairs(sections) do f.document[section] = nil end
			helpers.assert_eq(builtin.fn(),true)
			helpers.assert_eq(#f.fixture.selections,1)
			helpers.assert_eq(f.fixture.selections[1].id,"advanced")
			helpers.assert_eq(f.fixture.state.llm_active_profile,"advanced")
		end)
	end)
	helpers.it("profile-headings: native pause still disables actual builtin choices", function()
		with_headings(true, function(f)
			f.fixture.native_dependencies.script_control.is_paused=function() return true end
			local _, builtin = position(f.rows(), "Advanced")
			helpers.assert_true(builtin.disabled); helpers.assert_nil(builtin.fn)
			f.untouched()
		end)
	end)
end)
