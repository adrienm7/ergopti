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

local function count_rows(menu)
	local item = menu.build_item()
	for _, row in ipairs(item.submenu) do
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
