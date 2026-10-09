--- tests/unit/ui/menu/test_key_combination_labels.lua

--- ==============================================================================
--- MODULE: Physical Combination Labels Follow The Active Locale
--- DESCRIPTION:
--- Exercises the real combination provider and renderer against the complete
--- native matrix. Handwritten French names must never replace canonical key
--- translations, and a cached picker must follow a live language switch.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Reads source bytes without involving the menu's label resolver.
--- @param path string Absolute source path.
--- @return string
local function read(path)
	local file = assert(io.open(path, "rb"))
	local text = file:read("*a")
	file:close()
	return text
end

--- Uses genuine locale JSON and the genuine locale wrapper without reloading.
--- @param callback function Receives the actual menu, locale wrapper and codec.
local function with_menu(callback)
	helpers.with_stub_scope({ "ui.menu.menu_tap_holds", "infra.manifest_menu",
		"infra.i18n", "infra.locale", "locale.core", "infra.storage",
		"infra.timer_scheduler", "tap_hold.combination_labels" }, function()
		local menu = helpers.load_with_stubs("ui.menu.menu_tap_holds", {})
		local captured = package.loaded["infra.i18n"]
		package.loaded["infra.i18n"] = nil
		local real = require("infra.i18n")
		real.set_locale_injector(require("infra.locale").set_locale)
		for key, value in pairs(real) do captured[key] = value end
		package.loaded["infra.i18n"] = captured
		callback(menu, real, require("adapters.json_codec"))
	end)
end

--- Makes only the acknowledged facade boundary observable; IDs stay native.
--- @param definitions table Actual native ordered matrix.
--- @param observed table Callback observations.
--- @return table
local function remap(definitions, observed)
	local out = {
		MOD_COMBOS = definitions, TAP_HOLD_KEYS = {}, NON_CANONICAL_COMBOS = {},
		DEFAULT_TAP_HOLD_TIMEOUT_MS = 200, DEFAULT_STICKY_TIMEOUT_MS = 1000,
		DEFAULT_SIMULTANEOUS_THRESHOLD_MS = 50,
		AVAILABLE_ACTIONS = {
			{ id = "none", label = "None fixture", category = "Spécial", holdable = true, tappable = true },
			{ id = "copy", label = "Copy fixture", category = "Spécial", holdable = true, tappable = true },
		},
		get_enabled = function() return true end,
		get_mod_combos_enabled = function() return true end,
		get_combo_symmetric = function() return false end,
		get_tap_hold_timeout = function() return 200 end,
		get_simultaneous_threshold = function() return 50 end,
		get_combo_combo_action = function() return "none" end,
		get_combo_tap_action = function() return "none" end,
		get_combo_hold_action = function() return "none" end,
		regenerate = function() observed.regenerations = observed.regenerations + 1; return true end,
	}
	for _, slot in ipairs({ "combo", "tap", "hold" }) do
		out["set_combo_" .. slot .. "_action"] = function(id, action)
			observed.calls[#observed.calls + 1] = { id = id, action = action, slot = slot }
			return observed.accepted
		end
	end
	return out
end

--- The independent expectation is the actual key catalogue plus locale source.
--- @param definitions table Native matrix, not a regenerated expectation.
--- @param catalogue table Canonical physical keys.
--- @param strings table Raw strings from one locale JSON.
--- @return table Expected ordered group headers and pairs.
local function expected_rows(definitions, catalogue, strings)
	local by_id, rows = {}, {}
	for _, key in ipairs(catalogue) do by_id[key.id] = key end
	for _, hand in ipairs({ "left", "right" }) do
		local group = nil
		for _, definition in ipairs(definitions) do
			local first = by_id[definition.from.simultaneous[1].key_code]
			local second = by_id[definition.from.simultaneous[2].key_code]
			if first.hand == hand and not definition.menu_hidden then
				if first.id ~= group then
					rows[#rows + 1] = { title = "— " .. strings[first.label_key] .. " —" }
					group = first.id
				end
				rows[#rows + 1] = {
					title = strings[first.label_key] .. " + " .. strings[second.label_key] .. "  :  —",
					id = definition.id,
				}
			end
		end
	end
	return rows
end

--- Retains top-level physical rows, excluding the manifest's fixed commands.
--- @param rows table Actual rendered group.
--- @return table
local function physical_rows(rows)
	local out = {}
	for _, row in ipairs(rows) do
		if row.title:sub(1, #"— ") == "— " or row.title:find("  :  ", 1, true) then
			out[#out + 1] = row
		end
	end
	return out
end

helpers.describe("canonical physical combination labels", function()
	helpers.it("translates every native pair and family in all 21 locales without changing the matrix", function()
		with_menu(function(menu, locale, codec)
			local matrix_path = helpers.driver_root() .. "/platform/remap/data/mod_combos.json"
			local original = read(matrix_path)
			local definitions = codec.decode(original)
			helpers.assert_eq(#definitions, 182, "the complete native matrix is covered")
			local catalogue = require("tap_hold.key_catalog").load(helpers.shared("tap_hold/defaults.toml"), "hs")
			local observed = { calls = {}, regenerations = 0, accepted = true }
			local facade = remap(definitions, observed)
			local count = 0
			for _, language in ipairs(locale.locales()) do
				locale.set_locale_no_reload(language.code)
				local strings = codec.decode(read(helpers.shared("data/locales/" .. language.code .. ".json")))
				local expected = expected_rows(definitions, catalogue, strings)
				local actual = physical_rows(menu.build_key_combinations({ karabiner = facade }))
				helpers.assert_eq(#expected, 193, "179 visible pairs and 14 physical family headers; three script-control pairs stay hidden")
				helpers.assert_eq(#actual, #expected, language.code .. " retains cardinality")
				for index, row in ipairs(expected) do
					helpers.assert_eq(actual[index].title, row.title, language.code .. " physical row " .. index)
				end
				count = count + 1
			end
			helpers.assert_eq(count, 21, "all supported languages execute")
			helpers.assert_eq(#observed.calls, 0, "relabeling is not a settings mutation")
			helpers.assert_eq(observed.regenerations, 0, "relabeling does not acquire a remap lease")
			helpers.assert_eq(read(matrix_path), original, "IDs, native actions and order stay byte-identical")
		end)
	end)

	helpers.it("invalidates the picker cache on a genuine locale switch while preserving stable-language reuse", function()
		with_menu(function(menu, locale, codec)
			local definitions = codec.decode(read(helpers.driver_root() .. "/platform/remap/data/mod_combos.json"))
			local facade = remap(definitions, { calls = {}, regenerations = 0, accepted = true })
			locale.set_locale_no_reload("en")
			local _, first = menu._build_picker_trees(facade, nil, true)
			local _, stable = menu._build_picker_trees(facade, nil, true)
			helpers.assert_true(first == stable, "unchanged language keeps the cached tree")
			locale.set_locale_no_reload("fr")
			local _, second = menu._build_picker_trees(facade, nil, true)
			helpers.assert_true(first ~= second, "the same bindings cannot keep old language labels")
			helpers.assert_eq(first.left[1].label, "— Escape —", "independent English fixture")
			helpers.assert_eq(second.left[1].label, "— Échap —", "independent French fixture")
		end)
	end)

	helpers.it("keeps the original three pair IDs and setter refusal boundaries for every slot", function()
		with_menu(function(menu, locale, codec)
			locale.set_locale_no_reload("en")
			local all = codec.decode(read(helpers.driver_root() .. "/platform/remap/data/mod_combos.json"))
			local chosen = {}
			local wanted = { ["right_option:left_option"] = true, ["right_option:caps_lock"] = true,
				["left_option:caps_lock"] = true }
			for _, definition in ipairs(all) do
				local keys = definition.from.simultaneous
				if wanted[keys[1].key_code .. ":" .. keys[2].key_code] then chosen[#chosen + 1] = definition end
			end
			helpers.assert_eq(#chosen, 3, "the actual equivalent physical pairs exist")
			local observed = { calls = {}, regenerations = 0, refreshes = 0, accepted = false }
			local catalogue = require("tap_hold.key_catalog").load(helpers.shared("tap_hold/defaults.toml"), "hs")
			local strings = codec.decode(read(helpers.shared("data/locales/en.json")))
			local expected = expected_rows(chosen, catalogue, strings)
			local rows = physical_rows(menu.build_key_combinations({ karabiner = remap(chosen, observed),
				updateMenu = function() observed.refreshes = observed.refreshes + 1 end }))
			for index, expectation in ipairs(expected) do
				if expectation.id then
					local pair = rows[index]
					helpers.assert_eq(pair.title, expectation.title)
					for slot_index, slot in ipairs({ "combo", "tap", "hold" }) do
						local picker = pair.menu[slot_index + 2].menu
						helpers.assert_eq(picker[2].title, "Copy fixture")
						observed.accepted = false
						local before = observed.regenerations
						picker[2].fn()
						helpers.assert_eq(observed.regenerations, before, "refusal cannot redeploy")
						local call = observed.calls[#observed.calls]
						helpers.assert_eq(call.id, expectation.id, "physical identity survives relabeling")
						helpers.assert_eq(call.slot, slot)
						helpers.assert_eq(call.action, "copy")
						observed.accepted = true
						picker[2].fn()
						helpers.assert_eq(observed.regenerations, before + 1, "one acknowledged regeneration")
					end
				end
			end
			helpers.assert_eq(#observed.calls, 18, "each of three slots on three pairs refuses then recovers")
			helpers.assert_eq(observed.refreshes, 9, "only acknowledged writes refresh")
		end)
	end)
end)
