--- tests/unit/platform/remap/generator/test_generator_virtual_keyboard_choice.lua

--- ==============================================================================
--- MODULE: Virtual Keyboard Choice (Automatic, ISO, ANSI)
--- DESCRIPTION:
--- The Karabiner virtual keyboard type is a configuration choice declared once
--- in the shared manifest (layout.virtual_keyboard). Automatic resolves to the
--- ANSI product (issue #99: it passes an Apple ISO keyboard's key pair through
--- unswapped); an explicit ISO or ANSI choice is deployed as written and is never
--- replaced by what the active layout's keycode convention would suggest.
---
--- COVERAGE:
--- 1. The manifest declares the three values and Automatic as the default.
--- 2. The choice resolves to a product, and an unknown choice is refused.
--- 3. The four combinations (ISO or ANSI keyboard behind the ISO or ANSI
---    product), table-driven from an independently declared product table.
--- 4. Every choice is deployed unchanged under both layout conventions.
--- 5. Navigation-layer outputs and the arrival convention follow the product, so
---    every key still reaches the keycode it reached under the ANSI product.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.platform.remap.generator.generator_fixture"] = nil
local Fixture = require("tests.support.platform.remap.generator.generator_fixture")
local Generator = Fixture.Generator
local NONE_ACTION = Fixture.NONE_ACTION
local make_state = Fixture.make_state
local Layout = require("modules.keymap.layout")
local Manifest = require("infra.manifest_reader")

-- What each virtual product makes of a HID usage (IOHIDFamily; Karabiner's
-- event_tap_utility: the ISO product sends 0x35 as 10 and 0x64 as 50).
-- Declared here, independently of the production tables.
local PRODUCT_KEYCODE = {
	ansi = { grave_accent_and_tilde = 50, non_us_backslash = 10 },
	iso = { grave_accent_and_tilde = 10, non_us_backslash = 50 },
}
-- The product each choice must deploy, declared by the maintainer's decision.
local CHOICE_PRODUCT = { auto = "ansi", iso = "iso", ansi = "ansi" }
local CHOICES = { "auto", "iso", "ansi" }

--- The registry record of a physical key as an Apple keyboard of one form reports it.
--- @param code string Registry key code.
--- @param form string "iso" or "ansi".
--- @return string usage The HID usage name the keyboard reports.
--- @return integer native The keycode macOS natively gives that keyboard for it.
local function physical(code, form)
	local source = assert(io.open(helpers.shared("data/keycodes/physical_keys.json"), "rb"))
	local registry = require("json").decode(source:read("*a")); source:close()
	local entry = assert(registry.keys[code], code)
	local record = form == "iso" and entry.macos_iso or entry
	return record.karabiner.key_code, record.hs
end

--- Whether a keyboard's ISO-pair keys keep their native keycode behind a product.
--- @param product string "iso" or "ansi".
--- @param form string The keyboard's form.
--- @return boolean
local function delivered_natively(product, form)
	for _, code in ipairs(form == "iso" and { "Backquote", "IntlBackslash" } or { "Backquote" }) do
		local usage, native = physical(code, form)
		if PRODUCT_KEYCODE[product][usage] ~= native then return false end
	end
	return true
end

helpers.describe("the virtual keyboard choice is declared once in the manifest", function()
	helpers.it("offers Automatic, ISO and ANSI with Automatic as the shipped default", function()
		local entry = Manifest.find_entry_by_path("layout.virtual_keyboard")
		helpers.assert_not_nil(entry, "layout.virtual_keyboard must be declared")
		helpers.assert_eq(entry.type, "enum")
		helpers.assert_true(helpers.deep_equal(entry.enum_values, { "auto", "iso", "ansi" }), "the three values")
		helpers.assert_eq(Manifest.default_for("layout.virtual_keyboard"), "auto")
	end)

	helpers.it("resolves each choice to its product and refuses anything else", function()
		for choice, product in pairs(CHOICE_PRODUCT) do
			helpers.assert_eq(Layout.virtual_keyboard_product(choice), product, choice)
		end
		helpers.assert_eq(Layout.default_virtual_keyboard_product(), "ansi", "the default is Automatic")
		for _, bad in ipairs({ "", "AUTO", "jis", "iso ", 3 }) do
			local ok = pcall(Layout.virtual_keyboard_product, bad)
			helpers.assert_true(not ok, "the choice " .. tostring(bad) .. " must be refused")
		end
		helpers.assert_true(not pcall(Layout.virtual_keyboard_product, nil), "an absent choice must be refused")
	end)
end)

helpers.describe("the four combinations of keyboard and virtual keyboard choice", function()
	helpers.it("keeps a keyboard's native keycodes only behind the ANSI product", function()
		-- Automatic resolves to ANSI, so it keeps them on both keyboards; an explicit
		-- ISO choice is honoured even though it swaps the pair.
		for _, case in ipairs({
			{ keyboard = "iso", choice = "auto", native = true },
			{ keyboard = "ansi", choice = "auto", native = true },
			{ keyboard = "iso", choice = "ansi", native = true },
			{ keyboard = "ansi", choice = "ansi", native = true },
			{ keyboard = "iso", choice = "iso", native = false },
			{ keyboard = "ansi", choice = "iso", native = false },
		}) do
			helpers.assert_eq(delivered_natively(Layout.virtual_keyboard_product(case.choice), case.keyboard), case.native,
				case.keyboard .. " keyboard with the " .. case.choice .. " choice")
		end
	end)

	helpers.it("deploys the chosen product whatever convention the active layout has", function()
		-- Layout detection only tells which keycodes keys arrive as; it must never
		-- replace the product the user picked (an ISO layout once forced ISO).
		for _, convention in ipairs({ "iso", "ansi" }) do
			for _, choice in ipairs(CHOICES) do
				local state = make_state()
				state.virtual_keyboard_type = convention
				state.virtual_keyboard_product = Layout.virtual_keyboard_product(choice)
				local result = Generator.build_karabiner_json(state, { NONE_ACTION }, {}, {}, nil, "/fake/data_dir/")
				helpers.assert_not_nil(result)
				helpers.assert_eq(result.profiles[1].virtual_hid_keyboard.keyboard_type_v2, CHOICE_PRODUCT[choice],
					"a " .. convention .. " layout with the " .. choice .. " choice")
			end
		end
	end)

	helpers.it("deploys Automatic's product when no choice reached the state", function()
		local state = make_state()
		state.virtual_keyboard_type = "iso"
		local result = Generator.build_karabiner_json(state, { NONE_ACTION }, {}, {}, nil, "/fake/data_dir/")
		helpers.assert_eq(result.profiles[1].virtual_hid_keyboard.keyboard_type_v2, "ansi")
	end)

	helpers.it("refuses a product that is neither ISO nor ANSI", function()
		local state = make_state()
		state.virtual_keyboard_type = "iso"
		state.virtual_keyboard_product = "jis"
		local result, err = Generator.build_karabiner_json(state, { NONE_ACTION }, {}, {}, nil, "/fake/data_dir/")
		helpers.assert_nil(result)
		helpers.assert_true(tostring(err):find("jis", 1, true) ~= nil, "the refusal names the value")
	end)

	helpers.it("names an action's key for the chosen product", function()
		-- Both products send the character the layout types at the key left of 1.
		local layout_text = { [10] = "$", [50] = "ê" }
		for _, product in ipairs({ "ansi", "iso" }) do
			local name = Layout.product_key_name("non_us_backslash", product)
			helpers.assert_eq(layout_text[PRODUCT_KEYCODE[product][name]], "$", product .. " product")
		end
	end)
end)

helpers.describe("the choice reaches the outputs and the arrival convention", function()
	local REGISTRY = { keys = {
		KeyH = { kind = "key", group = "alphanumeric", karabiner = { key_code = "h" } },
		Backquote = { kind = "key", group = "alphanumeric", karabiner = { key_code = "grave_accent_and_tilde" },
			macos_iso = { hs = 10, karabiner = { key_code = "non_us_backslash" } } },
	} }
	local BINDINGS = {
		KeyH = { kind = "keystroke", chords = { { mods = {}, key = "Backquote" } }, repeatable = true, action = "x" },
	}

	--- The key_code a bound navigation key sends once deployed behind a product.
	local function deployed_output(product)
		local state = make_state()
		state.virtual_keyboard_type = "iso"
		state.virtual_keyboard_product = product
		state.nav_layer = { bindings = BINDINGS, registry = REGISTRY }
		local config, err = Generator.build_karabiner_json(state, { NONE_ACTION }, {}, {}, nil, "/fake/data_dir/")
		helpers.assert_nil(err)
		for _, rule in ipairs(config.profiles[1].complex_modifications.rules) do
			for _, manipulator in ipairs(rule.manipulators or {}) do
				if manipulator.from and manipulator.from.key_code == "h" and manipulator.to then
					return manipulator.to[1].key_code
				end
			end
		end
		error("the navigation key was not deployed")
	end

	helpers.it("sends the navigation layer's ISO key to the same keycode behind either product", function()
		local _, native = physical("Backquote", "iso")
		for _, choice in ipairs(CHOICES) do
			local product = Layout.virtual_keyboard_product(choice)
			local sent = deployed_output(product)
			helpers.assert_eq(PRODUCT_KEYCODE[product][sent], native,
				"the " .. choice .. " choice must still reach the ISO key left of 1")
		end
	end)

	helpers.it("derives the arrival convention from the layout convention and the product", function()
		-- An ISO keyboard's key left of 1 reports non_us_backslash; the keycode it
		-- arrives with behind a product is the ANSI or ISO registry code that matches.
		for _, case in ipairs({
			{ convention = "iso", product = "ansi" },
			{ convention = "ansi", product = "ansi" },
			{ convention = "iso", product = "iso" },
			{ convention = "ansi", product = "iso" },
		}) do
			local usage, _ = physical("Backquote", case.convention)
			local arrives = PRODUCT_KEYCODE[case.product][usage]
			local _, ansi_code = physical("Backquote", "ansi")
			local _, iso_code = physical("Backquote", "iso")
			local form = Layout.arrival_form(case.convention, case.product)
			helpers.assert_eq(form == "ansi" and ansi_code or iso_code, arrives,
				case.convention .. " layout behind the " .. case.product .. " product")
		end
	end)
end)
