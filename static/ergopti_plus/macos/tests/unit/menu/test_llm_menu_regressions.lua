--- tests/unit/menu/test_llm_menu_regressions.lua
---
--- Non-regression guards for fixed LLM tray/menu bugs (Hammerspoon). Mirrors
--- windows/tests/test_llm_menu_regressions.ahk where the platform shares the bug class.

local helpers = require("tests.helpers")
local prefs   = helpers.load_with_stubs("infra.preferences")
local codec   = helpers.load_with_stubs("infra.toml.codec")
local with_count_menu = require("tests.support.llm_count_menu_fixture")

local function contract_path()
	return helpers.shared("modules/llm/menu_persistence_contract.json")
end

local function load_contract_entry(id)
	local fh = io.open(contract_path(), "r")
	if not fh then error("menu_persistence_contract.json missing") end
	local raw = fh:read("*a")
	fh:close()
	local ok, data = pcall(hs.json.decode, raw)
	if not ok then error("contract JSON invalid") end
	for _, entry in ipairs(data.entries or {}) do
		if entry.id == id then return entry end
	end
	error("contract entry not found: " .. id)
end

local function preferences_source()
	return helpers.driver_root() .. "infra/preferences.lua"
end

local function driver_init_source()
	return helpers.driver_root() .. "init.lua"
end

local function normalize_toml_array(v)
	if type(v) == "table" then
		local out = {}
		for i = 1, #v do
			if v[i] ~= nil then out[#out + 1] = tostring(v[i]) end
		end
		if #out > 0 then return out end
		for _, val in pairs(v) do
			out[#out + 1] = tostring(val)
		end
		table.sort(out)
		return out
	end
	return v
end

local function array_signature(v)
	local arr = normalize_toml_array(v)
	if type(arr) ~= "table" then return tostring(arr) end
	return table.concat(arr, ",")
end

local function values_equal(expected, actual, entry)
	if entry.toml_array then
		return array_signature(expected) == array_signature(actual)
	end
	return expected == actual
end

--- The generation-parameters submenu of the real LLM menu.
--- @param menu table The LLM menu handler.
--- @return table rows
local function generation_rows(menu)
	local item = menu.build_item()
	for _, row in ipairs(item.submenu) do
		if row.title == "menu.llm.generation_menu_title" then return row.menu end
	end
	error("The real LLM menu did not expose its generation submenu")
end

local function count_rows(menu)
	for _, row in ipairs(generation_rows(menu)) do
		if row.title == "menu.llm.num_predictions_label" then return row.menu end
	end
	error("The real LLM menu did not expose its prediction count submenu")
end

helpers.describe("LLM menu regressions — Hammerspoon", function()

	helpers.it("num_predictions real callbacks submit each selected index (llm-count-menu)", function()
		with_count_menu(function(menu, _, calls)
			local rows = count_rows(menu)
			helpers.assert_eq(#rows, 10)
			for i = 1, 10 do
				helpers.assert_type(rows[i].fn, "function")
				helpers.assert_eq(rows[i].fn(), true)
				helpers.assert_eq(#calls, i)
				helpers.assert_eq(calls[i].key, "llm_num_predictions")
				helpers.assert_eq(calls[i].value, i)
				helpers.assert_eq(calls[i].runtime_fn, "set_llm_num_predictions")
				helpers.assert_eq(calls[i].publish_setting, false)
			end
		end)
	end)

	helpers.it("num_predictions real menu reflects state and propagates refusal (llm-count-menu)", function()
		with_count_menu(function(menu, state, calls, set_outcome)
			state.llm_num_predictions = 7
			local rows = count_rows(menu)
			helpers.assert_eq(#rows, 10)
			for i = 1, 10 do helpers.assert_eq(rows[i].checked == true, i == 7) end
			helpers.assert_eq(#calls, 0, "Rendering must not submit a settings transaction")
			set_outcome(false)
			helpers.assert_eq(rows[3].fn(), false)
			helpers.assert_eq(#calls, 1)
			helpers.assert_eq(calls[1].value, 3)
			helpers.assert_eq(state.llm_num_predictions, 7)
		end)
	end)

	-- The count is a generation parameter: it heads the generation submenu on
	-- every driver, and the top level no longer carries a row of its own.
	helpers.it("num_predictions heads the generation submenu, not the top level (llm-count-row)", function()
		with_count_menu(function(menu)
			for _, row in ipairs(menu.build_item().submenu) do
				helpers.assert_true(row.title ~= "menu.llm.num_predictions_label",
					"the top level must not carry the suggestion count row")
			end
			local rows = generation_rows(menu)
			helpers.assert_eq(rows[1].title, "menu.llm.num_predictions_label",
				"the count must be the first generation parameter")
			helpers.assert_eq(#rows[1].menu, 10, "the count row keeps its ten choices")
		end)
	end)

	-- The count used to be one key with an "s" injected after it, which no
	-- language but French and English pluralises that way. The rows now read the
	-- singular key for one and the plural key for every other count.
	helpers.it("num_predictions rows read the one/other plural keys (llm-count-plural)", function()
		with_count_menu(function(menu)
			local rows = count_rows(menu)
			helpers.assert_eq(#rows, 10)
			helpers.assert_eq(rows[1].title, "1 prediction", "one reads the singular key")
			for i = 2, 10 do
				helpers.assert_eq(rows[i].title, i .. " predictions", "every other count reads the plural key")
			end
		end)
	end)

	helpers.it("val_modifiers alt+ctrl round-trips (comma string vs TOML array)", function()
		local entry = load_contract_entry("val_modifiers")
		local hs = entry.hs
		local tmp = helpers.fixtures_dir() .. "llm_regress_val_modifiers.toml"
		os.remove(tmp)

		local state = { [hs.flat_key] = hs.sample }
		prefs.save(tmp, state, {}, {})
		local flat = prefs.load(tmp)
		helpers.assert_true(
			values_equal(hs.sample, flat[hs.flat_key], hs),
			"flat load must preserve alt+ctrl modifiers"
		)

		local fh = io.open(tmp, "r")
		helpers.assert_true(fh ~= nil, "config file missing")
		local content = fh:read("*a")
		fh:close()
		local ok, grouped = pcall(codec.decode, content)
		helpers.assert_true(ok, "TOML decode failed")
		helpers.assert_eq(type(grouped), "table",
			"a decode that answered nothing would make every key check below pass\n\t\t\tagainst an empty table")
		local nav = grouped.llm and grouped.llm.navigation
		helpers.assert_true(type(nav) == "table", "llm.navigation missing")
		helpers.assert_true(
			values_equal(hs.sample, nav.val_modifiers, hs),
			"grouped val_modifiers must round-trip alt,ctrl"
		)
		os.remove(tmp)
	end)

	helpers.it("preferences.lua maps llm_val_modifiers (persist path, not actions)", function()
		local fh = io.open(preferences_source(), "r")
		helpers.assert_true(fh ~= nil, "preferences.lua missing")
		local body = fh:read("*a")
		fh:close()
		helpers.assert_true(body:find("llm_val_modifiers", 1, true) ~= nil,
			"preferences.lua must wire llm_val_modifiers")
		-- macOS has no menu_llm/actions.ahk; guard against duplicating persist in wrong layer.
		helpers.assert_true(body:find("KEY_MAP", 1, true) ~= nil,
			"preferences.lua must use KEY_MAP for flat persistence")
	end)

	helpers.it("driver init gates LLM backend bootstrap on the boot enabled flag", function()
		local fh = io.open(driver_init_source(), "r")
		helpers.assert_true(fh ~= nil, "init.lua missing")
		local body = fh:read("*a")
		fh:close()
		helpers.assert_true(body:find("LLM boot disabled at startup", 1, true) ~= nil,
			"init.lua must keep an explicit disabled-boot LLM skip path")
		helpers.assert_true(body:find("start_background_network_bootstrap", 1, true) ~= nil,
			"init.lua must explicitly opt into the core LLM network bootstrap only when boot LLM is enabled")
	end)

end)


--- Reads the independent generation boundary expectations from the shared corpus.
--- @return table expected
local function generation_boundary_contract()
	local file = assert(io.open(helpers.shared("tests/corpus/menus/generation_boundaries.json"), "r"))
	local raw = file:read("*a"); file:close()
	return hs.json.decode(raw)
end

helpers.describe("Generation numeric boundaries", function()
	helpers.it("the genuine numeric owner consumes its shared count boundary (generation-boundaries)", function()
		with_count_menu(function(menu, state, calls, set_outcome)
			local expected = generation_boundary_contract()
			local ManifestMenu = require("infra.manifest_menu")
			local frame = ManifestMenu.get_array(expected.boundaries.count.section)
			local original = frame[1]
			local ok, detail = xpcall(function()
				local rows = generation_rows(menu)
				helpers.assert_eq(rows[1].title, "menu.llm.num_predictions_label")
				helpers.assert_eq(rows[2].title, "-", "the native count group retains its separator")
				helpers.assert_eq(rows[3].title, "menu.llm.context_length_label")
				helpers.assert_eq(rows[4].title, "menu.llm.reset_on_nav")
				helpers.assert_eq(rows[5].title, "menu.llm.min_words_label")
				helpers.assert_eq(rows[6].title, "menu.llm.max_words_label")
				helpers.assert_eq(#calls, 0, "presentation cannot submit a setting transaction")
				frame[1] = { type = expected.published_marker.type,
					id = expected.published_marker.id, i18n = expected.published_marker.i18n,
					platforms = { "ahk", "hs" }, unavailable = "hide" }
				state.llm_num_predictions = 7
				rows = generation_rows(menu)
				helpers.assert_eq(rows[2].title, "menu.llm.reset_label", "the native optional reset precedes the boundary")
				helpers.assert_eq(rows[3].title, expected.published_marker_key,
					"the real allocator consumes the current shared presentation")
				helpers.assert_eq(rows[3].disabled, true)
				helpers.assert_nil(rows[3].fn)
				helpers.assert_eq(rows[4].title, "menu.llm.context_length_label")
				helpers.assert_eq(rows[5].title, "menu.llm.reset_on_nav")
				helpers.assert_eq(#rows[1].menu, 10)
				set_outcome(false)
				helpers.assert_eq(rows[1].menu[4].fn(), false, "the unchanged count callback propagates refusal")
				helpers.assert_eq(#calls, 1)
				helpers.assert_eq(calls[1].key, "llm_num_predictions")
				helpers.assert_eq(calls[1].value, 4)
				helpers.assert_eq(calls[1].runtime_fn, "set_llm_num_predictions")
				helpers.assert_eq(state.llm_num_predictions, 7)
			end, debug.traceback)
			frame[1] = original
			if not ok then error(detail, 0) end
		end)
	end)

	helpers.it("a withdrawn boundary refuses without a native fallback or settings effects (generation-boundaries)", function()
		with_count_menu(function(menu, state, calls)
			local expected = generation_boundary_contract()
			local frame = require("infra.manifest_menu").get_array(expected.boundaries.count.section)
			local original = frame[1]
			local before = state.llm_num_predictions
			local ok, detail = xpcall(function()
				frame[1] = { type = "command", id = "unowned_generation_boundary",
					i18n = expected.published_marker_key, platforms = { "ahk", "hs" }, unavailable = "hide" }
				helpers.assert_eq(menu.build_item(), {}, "a refused presentation has no native fallback")
				helpers.assert_eq(#calls, 0)
				helpers.assert_eq(state.llm_num_predictions, before)
			end, debug.traceback)
			frame[1] = original
			if not ok then error(detail, 0) end
			helpers.assert_eq(generation_rows(menu)[2].title, "-", "repair restores the same real provider")
			helpers.assert_eq(#calls, 0)
		end)
	end)

	helpers.it("the actual shared renderer preserves both non-applicable projections (generation-boundaries)", function()
		with_count_menu(function()
			local expected = generation_boundary_contract()
			local Renderer = require("menu.renderer")
			local NativeJson = require("adapters.json_codec")
			for _, platform in ipairs({ "ahk", "hs", "linux" }) do
				local renderer = assert(Renderer.new({ platform = platform,
					manifest_path = function() return helpers.shared("modules/menu/menu_manifest.json") end,
					json_decode = NativeJson.decode, i18n = require("infra.i18n"),
					logger = require("infra.logger") }))
				for _, key in ipairs({ "count", "context", "words" }) do
					local boundary = expected.boundaries[key]
					helpers.assert_eq(renderer.template_rows(boundary.section, {}, {}, {}),
						boundary.projections[platform], platform .. ": independent boundary " .. key)
				end
			end
		end)
	end)
end)


helpers.describe("Count fixture authentic whole-frame admission", function()
	helpers.it("refuses missing non-count commands without delivering the observed transaction", function()
		with_count_menu(function(menu, _, calls)
			local native = package.loaded["infra.manifest_menu"]
			local declaration = native.get_array("llm_generation_context_control")
			local original = declaration[1]
			helpers.assert_true(#generation_rows(menu) >= 6)
			local ok, detail = xpcall(function()
				declaration[1] = { type = "command", id = "missing_real_context_command", i18n = original.i18n }
				helpers.assert_eq(menu.build_item(), {})
				helpers.assert_eq(#calls, 0)
			end, debug.traceback)
			declaration[1] = original
			if not ok then error(detail, 0) end
			helpers.assert_true(#generation_rows(menu) >= 6)
		end)
	end)
end)


helpers.describe("Actual model picker native handoff", function()
	for _, backend in ipairs({ "ollama", "mlx" }) do
		helpers.it("completes the genuine " .. backend .. " selector DATA before native publication", function()
			with_count_menu(function(menu, _, calls)
				local item = menu.build_item()
				local data = calls.real_model_selector_rows
				helpers.assert_type(data, "table", "the actual ModelsSelector constructor must have run")
				helpers.assert_type(data[1], "table", "the genuine declared No model row must exist")
				helpers.assert_type(data[1].action, "function", "the selector returns genuine command DATA")
				helpers.assert_type(data[1].label, "string", "the selector retains its canonical caption")
				local model
				for _, row in ipairs(item.submenu) do
					if type(row.menu) == "table" and row.menu[1]
						and rawequal(row.menu[1].fn, data[1].action) then model = row.menu; break end
				end
				helpers.assert_type(model, "table", "the same command closure reaches the completed model child")
				helpers.assert_eq(model[1].title, data[1].label, "materialization preserves the actual declared caption")
				helpers.assert_nil(model[1].action, "provider commands never leak into completed native rows")
				helpers.assert_nil(model[1].label, "provider captions never leak into completed native rows")
				helpers.assert_nil(data[1].fn, "materialization does not mutate the producer's original DATA")
				helpers.assert_nil(data[1].title, "the selector's DATA remains DATA")
				local renderer = require("infra.manifest_menu")
				local compose = renderer.native_composition("macos_download_root")
				helpers.assert_type(compose, "function", "the actual completed-native publication owner admits")
				helpers.assert_eq(compose({ download = {}, body = item.submenu }), true,
					"the genuine factory's complete subtree passes strict native ABI publication")
			end, { real_model_selector = true, backend = backend })
		end)
	end
end)
