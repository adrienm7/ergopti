--- tests/unit/ai/ui/menu/profiles/test_manager_profile_activation_owner_ordered_frame.lua

-- =============================================================================
-- MODULE: Profiles Manager Explicit-Intent Ownership
-- DESCRIPTION:
-- Proves that clone, create, and active-profile deletion route their resulting
-- profile selection through the transactional model-switcher owner, and that
-- Auto-detect propagates the same owner's exact terminal result.
-- =============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.ai.ui.profiles.manager_profile_activation_owner_fixture"] = nil
local Fixture = require("tests.support.ai.ui.profiles.manager_profile_activation_owner_fixture")
local with_profiles_fixture = Fixture.with_profiles_fixture





-- The two declared frame orders own every fixed control; native row providers
-- keep real profile data and transactions, including captured recommendation pause.
helpers.describe("complete ordered profile frame: actual macOS owner", function()
	local Json = require("core.text.engine.json")
	local function read(relative)
		local file = assert(io.open(helpers.shared(relative), "rb"))
		local value = Json.decode(file:read("*a")); file:close(); return value
	end
	local oracle = read("tests/corpus/menus/profile_ordered_frame.json")
	-- Explicit V3 presentation policy; preserve the original independent frame oracle bytes.
	-- Found by section, not position: retiring the recommendation rows (4c0197d2)
	-- moved the builtin heading from the fifth entry to the third.
	local function include_of(frame, section)
		for _, entry in ipairs(frame) do
			if entry.type == "include" and entry.section == section then return entry end
		end
		error("the frame oracle declares no include of " .. section)
	end
	include_of(oracle.sections.llm_profile_lua_frame, "llm_profile_builtin_heading").on_refusal = "omit_presentation"
	oracle.sections.llm_profile_windows_frame[1].on_refusal = "omit_presentation"
	oracle.sections.llm_profile_custom_section[1].on_refusal = "omit_presentation"
	local function with_frame(options, body)
		options = options or {}
		if options.custom then options.user_profiles = { { id = "user_canonical", label = "Canonical" } } end
		with_profiles_fixture(options, function(fixture)
			local document = read("menu/data/menu_manifest.json")
			local i18n = package.loaded["core.i18n.engine.i18n"]
			i18n.section = function(key) return "— " .. i18n.get(key) .. " —" end
			local Menu = assert(require("menu.engine.renderer").new({ platform = "hs",
				manifest_path = function() return helpers.shared("menu/data/menu_manifest.json") end,
				json_decode = function() return document end, i18n = i18n, logger = package.loaded["core.logger.engine.logger"] }))
			local binding = package.loaded["menu.engine.manifest_menu"]
			binding.template_rows, binding.render_rows = Menu.template_rows, Menu.render_rows
			if options.paused then fixture.native_dependencies.script_control.is_paused = function() return true end end
			local function rows() return fixture.manager.get_menu_item().menu end
			body({ fixture = fixture, document = document, rows = rows, i18n = i18n })
		end)
	end
	local function at(rows, title)
		for _, row in ipairs(rows) do if row.title == title then return row end end
	end
	local function roles(f, rows)
		local result = {}
		for _, row in ipairs(rows) do
			local role
			if row.title == "-" then role = "---"
			elseif row.title == "Basic" then role = "builtin:basic"
			elseif row.title == "Advanced" then role = "builtin:advanced"
			elseif row.title == "Canonical" then role = "custom:user_canonical"
			else
				for id, key in pairs(oracle.labels) do
					local decorated = id == "builtin_heading" or id == "custom_heading"
					local title = decorated and f.i18n.section(key) or f.i18n.get(key)
					if row.title == title then role = id end
				end
			end
			helpers.assert_not_nil(role, "every physical native row has an independent expected role: " .. tostring(row.title))
			result[#result + 1] = role
		end
		return result
	end
	local states = {
		{ "hs_custom_builtin", { custom = true } },
		{ "hs_empty_builtin", {} },
		{ "hs_custom_active_user", { custom = true, active_profile = "user_canonical" } },
		{ "hs_paused_custom_builtin", { custom = true, paused = true } },
	}
	for _, state in ipairs(states) do
		helpers.it("pins complete actual native row order for " .. state[1], function()
			with_frame(state[2], function(f)
				helpers.assert_eq(roles(f, f.rows()), oracle.expected[state[1]])
				helpers.assert_eq(#f.fixture.selections, 0)
				helpers.assert_eq(f.fixture.direct_saves(), 0)
				helpers.assert_eq(f.fixture.registry_calls(), 1)
			end)
		end)
	end
	helpers.it("consumes the exact independent complete shared declarations", function()
		with_frame({ custom = true }, function(f)
			for key, value in pairs(oracle.sections) do helpers.assert_eq(f.document[key], value, key) end
		end)
	end)
	helpers.it("greys the automatic-profile check and hides clone while paused", function()
		with_frame({ custom = true, paused = true }, function(f)
			local rows = f.rows()
			local auto = assert(at(rows, f.i18n.get(oracle.labels.auto_detect)))
			helpers.assert_eq(auto.fn ~= nil and auto.fn() or false, false, "a paused driver changes nothing")
			helpers.assert_eq(f.fixture.direct_saves(), 0)
			helpers.assert_nil(at(rows, f.i18n.get(oracle.labels.clone)))
			helpers.assert_eq(#f.fixture.recommendations, 0)
		end)
	end)
	-- llm.profiles.auto_profile_for_model, as on Windows and Linux: a check, not a
	-- one-shot recommendation; switched on, the profile follows the model at once.
	helpers.it("switches the automatic profile and applies the recommendation when it goes on", function()
		with_frame({ recommendation_result = true }, function(f)
			local row = assert(at(f.rows(), f.i18n.get(oracle.labels.auto_detect)))
			helpers.assert_eq(row.checked, true, "the automatic profile is on by default")
			helpers.assert_eq(row.fn(), true)
			helpers.assert_eq(f.fixture.state.llm_auto_profile_for_model, false)
			helpers.assert_eq(f.fixture.direct_saves(), 1)
			helpers.assert_eq(#f.fixture.recommendations, 0, "switching off applies nothing")
			row = assert(at(f.rows(), f.i18n.get(oracle.labels.auto_detect)))
			helpers.assert_eq(row.fn(), true)
			helpers.assert_eq(f.fixture.state.llm_auto_profile_for_model, true)
			helpers.assert_eq(f.fixture.direct_saves(), 2)
			helpers.assert_eq(f.fixture.recommendations, { {} }, "switching on follows the current model")
		end)
	end)
	helpers.it("keeps the automatic profile unchanged when its save is refused", function()
		with_frame({ save_mode = "false" }, function(f)
			local row = assert(at(f.rows(), f.i18n.get(oracle.labels.auto_detect)))
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(f.fixture.state.llm_auto_profile_for_model, true)
			helpers.assert_eq(#f.fixture.recommendations, 0)
		end)
	end)
	helpers.it("refuses a withdrawn automatic-profile declaration before native effects", function()
		with_frame({ recommendation_result = true }, function(f)
			local row = assert(at(f.rows(), f.i18n.get(oracle.labels.auto_detect)))
			f.document.llm_profile_auto_detect_control = nil
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(f.fixture.direct_saves(), 0)
			helpers.assert_eq(#f.fixture.recommendations, 0)
		end)
	end)
	helpers.it("actual frame consumption follows changed full source order", function()
		with_frame({ custom = true }, function(f)
			local frame = f.document.llm_profile_lua_frame
			frame[1], frame[8] = frame[8], frame[1]
			local rows = f.rows()
			helpers.assert_eq(rows[1].title, f.i18n.get(oracle.labels.create))
			-- The per-application overrides end the submenu after the frame, behind
			-- their separator, as on Windows: the frame's last row precedes them.
			helpers.assert_eq(rows[#rows].title, f.i18n.get("menu.profiles.per_app_overrides"))
			helpers.assert_eq(rows[#rows - 1].title, "-")
			helpers.assert_eq(rows[#rows - 2].title, f.i18n.get(oracle.labels.auto_detect))
			helpers.assert_eq(#f.fixture.recommendations, 0)
		end)
	end)
	for _, fault in ipairs({ "missing frame", "wrong native list binding", "missing presence getter", "wrong exact command selector" }) do
		helpers.it("refuses " .. fault .. " instead of inventing a native fixed frame", function()
			with_frame({ custom = true }, function(f)
				if fault == "missing frame" then f.document.llm_profile_lua_frame = nil
				elseif fault == "wrong native list binding" then f.document.llm_profile_lua_frame[4].id = "unregistered_data"
				elseif fault == "missing presence getter" then f.document.llm_profile_lua_frame[5].present_when = "unregistered_presence"
				else f.document.llm_profile_lua_frame[8].row_id = "unregistered_command" end
				helpers.assert_eq(#f.rows(), 0)
				helpers.assert_eq(#f.fixture.selections, 0)
				helpers.assert_eq(#f.fixture.recommendations, 0)
				helpers.assert_eq(f.fixture.direct_saves(), 0)
			end)
		end)
	end
	helpers.it("consumes all 21 existing fixed captions through the complete actual native frame", function()
		with_frame({ custom = true }, function(f)
			local languages = read("core/i18n/data/locale_order.json").order
			helpers.assert_eq(#languages, 21)
			for _, language in ipairs(languages) do
				local values = read("core/i18n/data/locales/" .. language .. ".json")
				f.i18n.get = function(key) return values[key] or key end
				local rows = f.rows()
				for _, id in ipairs({ "auto_detect", "builtin_heading", "custom_heading", "clone", "create" }) do
					local key = oracle.labels[id]
					helpers.assert_not_nil(values[key], language .. ": original translated caption")
					local title = id:find("heading", 1, true) and f.i18n.section(key) or values[key]
					helpers.assert_not_nil(at(rows, title), language .. ": actual physical shared fixed row")
				end
				helpers.assert_eq(roles(f, rows), oracle.expected.hs_custom_builtin)
				helpers.assert_eq(#f.fixture.selections, 0)
				helpers.assert_eq(f.fixture.direct_saves(), 0)
			end
		end)
	end)

end)
