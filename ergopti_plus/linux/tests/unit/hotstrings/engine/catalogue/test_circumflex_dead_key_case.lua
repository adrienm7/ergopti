--- tests/unit/hotstrings/engine/catalogue/test_circumflex_dead_key_case.lua

--- ==============================================================================
--- MODULE: Circumflex Dead Key Case (Linux)
--- DESCRIPTION:
--- Field report, Arch KDE Wayland: the roll ê then é typed "Œ" in a lowercase
--- word, so "coeur" came out "cŒur". The shipped dead_key_e_circumflex section
--- writes each key as a literal case pair ("êé" → "œ", "êÉ" → "Œ") that only
--- strict comparison can tell apart; registered as folding literals, the
--- first-written UPPER half of every pair won whatever casing was typed. This
--- drives the real catalogue through the real loader and the shared engine,
--- typing key by key as the daemon does.
--- ==============================================================================

package.loaded["tests.support.modules.hotstrings.catalogue.ergopti_extension_hotstrings_fixture"] = nil
local Fixture = require("tests.support.modules.hotstrings.catalogue.ergopti_extension_hotstrings_fixture")
local helpers, load = Fixture.helpers, Fixture.load
local SharedEngine = require("hotstrings.engine.matcher")
local text_utils = require("core.text.engine.utils_core")

-- The groups a French Ergopti typist has on for these words: the two
-- distance-reduction files that own the rolls and the French corrections.
local GROUPS = { distancesreduction = true, sfbsreduction = true, french_autocorrection = true }

--- An engine holding the shipped mappings of GROUPS, in catalogue order.
--- @return table engine
local function shipped_engine()
	local catalogue = load(true)
	local mappings = {}
	for _, m in ipairs(catalogue.mappings) do
		if GROUPS[m.group] then mappings[#mappings + 1] = m end
	end
	helpers.assert_true(#mappings > 0, "the shipped groups load")
	local engine = SharedEngine.new()
	helpers.assert_true(engine:load_mappings(mappings))
	return engine
end

--- Types a list of keys and returns what the screen shows afterwards.
--- @param engine table
--- @param keys table Array of UTF-8 characters, one per keystroke.
--- @return string
local function type_keys(engine, keys)
	engine:reset()
	local screen = {}
	for _, key in ipairs(keys) do
		screen[#screen + 1] = key
		local result = engine:on_char(key)
		if result then
			for _ = 1, result.backspace_count do table.remove(screen) end
			for _, cp in ipairs(text_utils.utf8_chars(result.replacement)) do screen[#screen + 1] = cp end
			if result.end_char and not result.consume_terminator then screen[#screen + 1] = result.terminator end
			engine:apply_expansion(result)
		end
	end
	return table.concat(screen)
end

helpers.describe("circumflex dead key keeps the typed case (linux-dead-key-case)", function()
	local cases = {
		-- The roll the field report names, inside a word and on its own.
		{ keys = { "c", "ê", "é", "u", "r" }, expected = "cœur" },
		{ keys = { "C", "ê", "é", "u", "r" }, expected = "Cœur" },
		{ keys = { "ê", "é", "u", "v", "r", "e" }, expected = "œuvre" },
		{ keys = { "ê", "é" }, expected = "œ" },
		-- Upper case has no dead-key pair ("ÊÉ" is not written), so the roll's
		-- own family answers, and the correction then ligatures the word.
		{ keys = { "Ê", "É" }, expected = "OE" },
		{ keys = { "C", "Ê", "É", "U", "R" }, expected = "CŒUR" },
		-- The reverse roll, which never touched the dead key.
		{ keys = { "é", "ê" }, expected = "eo" },
		{ keys = { "É", "Ê" }, expected = "EO" },
		-- Typed letter by letter, the French autocorrection conforms its ligature.
		{ keys = { "c", "o", "e", "u", "r" }, expected = "cœur" },
		{ keys = { "C", "o", "e", "u", "r" }, expected = "Cœur" },
		{ keys = { "C", "O", "E", "U", "R" }, expected = "CŒUR" },
		{ keys = { "o", "e", "u", "v", "r", "e" }, expected = "œuvre" },
		{ keys = { "O", "e", "u", "v", "r", "e" }, expected = "Œuvre" },
		-- Neither lower, Title nor UPPER: the shared case rule fires nothing
		-- rather than invent a casing (vector case_conform_rejects_mixed).
		{ keys = { "O", "E", "u", "v", "r", "e" }, expected = "OEuvre" },
		-- The upper half of the pair still answers its own casing.
		{ keys = { "ê", "É" }, expected = "Œ" },
		-- Every other pair had the same defect: "êo" typed "Ô".
		{ keys = { "ê", "o" }, expected = "ô" },
		{ keys = { "ê", "O" }, expected = "Ô" },
		{ keys = { "Ê", "o" }, expected = "Ô" },
		{ keys = { "ê", "u" }, expected = "û" },
		{ keys = { "ê", "c" }, expected = "ç" },
		{ keys = { "ê", "C" }, expected = "Ç" },
	}
	for _, case in ipairs(cases) do
		local typed = table.concat(case.keys)
		helpers.it("(linux-dead-key-case) types " .. typed .. " as " .. case.expected, function()
			helpers.assert_eq(type_keys(shipped_engine(), case.keys), case.expected)
		end)
	end
end)

helpers.describe("no shipped literal case pair is left to fold (linux-dead-key-case)", function()
	helpers.it("(linux-dead-key-case) gives two folding literals one folded trigger only when they agree", function()
		-- A folding literal fires on any casing, so two of them whose triggers
		-- differ only in case are one rule: whichever comes first answers both
		-- casings. A pair that means two outputs must be strict.
		local seen, folding, conflicts = {}, 0, {}
		for _, m in ipairs(load(true).mappings) do
			if m.is_case_sensitive == true and m.is_case_sensitive_strict ~= true then
				folding = folding + 1
				local key = text_utils.trig_fold(m.trigger)
				local first = seen[key]
				if not first then
					seen[key] = m
				elseif first.replacement ~= m.replacement then
					conflicts[#conflicts + 1] = string.format("%s/%s %q > %q against %s/%s %q > %q",
						first.group, first.section, first.trigger, first.replacement,
						m.group, m.section, m.trigger, m.replacement)
				end
			end
		end
		helpers.assert_true(folding > 100, "the shipped catalogue holds folding literals")
		helpers.assert_eq(conflicts, {})
	end)
end)
