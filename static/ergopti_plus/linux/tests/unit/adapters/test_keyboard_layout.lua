--- tests/unit/adapters/test_keyboard_layout.lua

--- ==============================================================================
--- MODULE: Keyboard Layout — character to keystroke
--- DESCRIPTION:
--- The whole output chain, from the text an XKB dump prints to the keycode and
--- modifiers that type a character, driven against a French AZERTY fixture.
---
--- WHY A FRENCH FIXTURE AND NOT A US ONE:
--- On US every interesting property is invisible. "a" is keycode 30 whether or
--- not the layout was ever read, so a US fixture passes against a hardcoded
--- table, against a broken parser that silently returns nothing plus a fallback,
--- and against the correct implementation alike. On AZERTY "a" is keycode 16 and
--- "é" is an unshifted key that does not exist on US at all — so every case
--- below fails if the layout is not genuinely being read.
---
--- That is not a hypothetical preference. This driver's replacements are
--- overwhelmingly accented French, ydotool assumes US, and "expansions come out
--- as gibberish" was the whole reason the injection path had to be rewritten.
---
--- WHAT THE THREE LAYERS ARE:
---   1. infra/xkb_keymap.lua   — text to (keysym, keycode, level). Pure.
---   2. infra/keysym.lua       — keysym name to character. Pure, plus an
---                               optional libxkbcommon path.
---   3. this adapter           — the join, the cache, and the refusal to guess.
--- Each is asserted here through the layer above it, because the seam between
--- them is where a plausible-looking half-answer would survive.
--- ==============================================================================

local helpers = require("tests.helpers")

-- A real `xkbcli dump-keymap-x11` shape for fr(azerty), cut to the keys the
-- cases below use. Both spellings of a key definition are present on purpose:
-- the short `{ [ … ] }` form and the long `{ type=…, symbols[Group1]= [ … ] }`
-- one, because a real dump contains both and a parser that knows only the short
-- form drops every key that carries an explicit type.
local AZERTY_DUMP = [[
xkb_keymap {
xkb_keycodes "(unnamed)" {
	minimum = 8;
	maximum = 708;
	 <TLDE>               = 49;
	 <AE01>               = 10;
	 <AE02>               = 11;
	 <AD01>               = 24;
	 <AD02>               = 25;
	 <AD03>               = 26;
	 <AC01>               = 38;
	 <AC02>               = 39;
	 <AB01>               = 52;
	 <SPCE>               = 65;
	 <LFSH>               = 50;
	 <RALT>               = 108;
};
xkb_types "(unnamed)" {
	virtual_modifiers LevelThree;
	type "FOUR_LEVEL" {
		modifiers= Shift+LevelThree;
		map[Shift]= Level2;
		level_name[Level1]= "Base";
	};
};
xkb_compatibility "(unnamed)" {
	interpret.useModMapMods= AnyLevel;
};
xkb_symbols "(unnamed)" {
	name[Group1]="French (AZERTY)";
	key <AD01>  {	[ a, A, ae, AE ] };
	key <AD02>  {	[ z, Z, acircumflex, Acircumflex ] };
	key <AD03>  {
		type= "FOUR_LEVEL",
		symbols[Group1]= [ e, E, EuroSign, cent ]
	};
	key <AC01>  {	[ q, Q, adiaeresis, Adiaeresis ] };
	key <AC02>  {	[ s, S, ssharp, U1E9E ] };
	key <AB01>  {	[ w, W, guillemotleft, less ] };
	key <AE02>  {	[ eacute, 2, asciitilde, Eacute ] };
	key <AE01>  {	[ ampersand, 1, dead_acute, exclamdown ] };
	key <TLDE>  {	[ twosuperior, asciitilde, notsign, NoSymbol ] };
	key <SPCE>  {	[ space, space, nobreakspace, U202F ] };
	key <LFSH>  {	[ Shift_L ] };
	key <RALT>  {	[ ISO_Level3_Shift ] };
};
};
]]

--- Loads the adapter with a table built from the fixture.
--- @return table adapter
local function loaded()
	local layout = helpers.load_module("adapters.keyboard_layout")
	local built = layout.build(AZERTY_DUMP)
	layout._set_table_for_test(built)
	return layout
end





-- =================================================================
-- =================================================================
-- ======= 1/ The parser reads the file, not a guess ===============
-- =================================================================
-- =================================================================

helpers.describe("xkb_keymap: parsing a real dump", function()

	helpers.it("converts XKB keycodes to evdev keycodes", function()
		local kb = helpers.load_module("infra.xkb_keymap")
		local codes = kb.parse_keycodes(AZERTY_DUMP)
		-- XKB numbers keys eight higher than the kernel does, because the X11
		-- protocol reserves 0-7. Getting this wrong types eight keys to the left,
		-- which on any layout is plausible text.
		helpers.assert_eq(codes.AD01, 16, "<AD01> = 24 in XKB is evdev 16")
		helpers.assert_eq(codes.AC01, 30, "<AC01> = 38 in XKB is evdev 30")
		helpers.assert_eq(codes.SPCE, 57, "space is evdev 57")
	end)

	helpers.it("reads the short form of a key definition", function()
		local kb = helpers.load_module("infra.xkb_keymap")
		local keys = kb.parse_symbols(AZERTY_DUMP)
		helpers.assert_eq(keys.AD01, { "a", "A", "ae", "AE" },
			"four levels, in order, from `key <AD01> { [ … ] }`")
	end)

	helpers.it("reads the long form too", function()
		local kb = helpers.load_module("infra.xkb_keymap")
		local keys = kb.parse_symbols(AZERTY_DUMP)
		-- A dump contains both spellings. A parser that knows only the short one
		-- silently drops every key with an explicit type — which on a French
		-- layout includes most of the ones with an accent on level 3.
		helpers.assert_eq(keys.AD03, { "e", "E", "EuroSign", "cent" },
			"`symbols[Group1]= [ … ]` must parse identically to the short form")
	end)

	helpers.it("marks NoSymbol as an absent level rather than a keysym", function()
		local kb = helpers.load_module("infra.xkb_keymap")
		local keys = kb.parse_symbols(AZERTY_DUMP)
		helpers.assert_eq(keys.TLDE[4], false,
			"NoSymbol produces nothing, and treating it as a name would put a "
				.. "keysym called NoSymbol in the table")
	end)

	helpers.it("survives the nested braces of the types block", function()
		local kb = helpers.load_module("infra.xkb_keymap")
		-- A non-greedy pattern for the symbols block stops at the first inner
		-- closing brace and returns the type definitions instead. The result is
		-- an empty symbol table and a driver that types nothing, silently.
		local keys = kb.parse_symbols(AZERTY_DUMP)
		local count = 0
		for _ in pairs(keys) do count = count + 1 end
		helpers.assert_true(count >= 10,
			"every key must be found past the brace-nested types block, got " .. count)
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 2/ Keysym names are protocol, not text ==================
-- =================================================================
-- =================================================================

helpers.describe("keysym: name to character", function()

	helpers.it("resolves the names that spell themselves", function()
		local ks = helpers.load_module("infra.keysym")
		ks._set_xkb_for_test(false)
		helpers.assert_eq(ks.to_char("a"), "a", "a letter names its own character")
		helpers.assert_eq(ks.to_char("A"), "A", "and so does the capital")
		helpers.assert_eq(ks.to_char("2"), "2", "and a digit")
	end)

	helpers.it("resolves the ones that do not", function()
		local ks = helpers.load_module("infra.keysym")
		ks._set_xkb_for_test(false)
		helpers.assert_eq(ks.to_char("eacute"), "é", "the whole point of the table")
		helpers.assert_eq(ks.to_char("ccedilla"), "ç", "French needs this one constantly")
		helpers.assert_eq(ks.to_char("adiaeresis"), "ä", "and German this one")
		helpers.assert_eq(ks.to_char("ssharp"), "ß", "the Latin-1 block, in order")
		helpers.assert_eq(ks.to_char("guillemotleft"), "«", "French quotation marks")
		helpers.assert_eq(ks.to_char("EuroSign"), "€", "on level 3 of most European layouts")
	end)

	helpers.it("resolves ASCII punctuation by its protocol name", function()
		local ks = helpers.load_module("infra.keysym")
		ks._set_xkb_for_test(false)
		helpers.assert_eq(ks.to_char("ampersand"), "&", "AZERTY puts this where US puts 1")
		helpers.assert_eq(ks.to_char("space"), " ", "space is a keysym like any other")
		helpers.assert_eq(ks.to_char("asciitilde"), "~", "not to be confused with dead_tilde")
	end)

	helpers.it("resolves the Unicode spellings a modern keymap uses", function()
		local ks = helpers.load_module("infra.keysym")
		ks._set_xkb_for_test(false)
		-- Everything without a legacy name is written this way, which is how a
		-- keymap expresses ★ or a narrow no-break space.
		helpers.assert_eq(ks.to_char("U20AC"), "€", "the U-prefixed form")
		helpers.assert_eq(ks.to_char("U2605"), "★", "including the magic key's own character")
		helpers.assert_eq(ks.to_char("0x1002605"), "★", "and the numeric keysym form")
	end)

	helpers.it("produces nothing for a dead key, even when the library answers", function()
		local ks = helpers.load_module("infra.keysym")
		-- Driven with a library that DOES return a character for dead_acute, which
		-- is the case that matters: on a machine with libxkbcommon the guard is
		-- the only thing standing between the injector and a wrong answer. With
		-- the library forced off, every name resolves to nil anyway and the test
		-- would pass with the guard deleted.
		ks._set_xkb_for_test({
			from_name = function(name) return name == "dead_acute" and 0xFE51 or nil end,
			to_utf8   = function() return "´" end,
		})
		helpers.assert_eq(ks.to_char("dead_acute"), nil,
			"pressing a dead key types NOTHING and arms the next keystroke; "
				.. "returning its accent makes the injector believe it typed a "
				.. "character it did not, and the next one comes out accented")
		ks._set_xkb_for_test(false)
		helpers.assert_eq(ks.to_char("dead_circumflex"), nil, "the whole dead_ family")
	end)

	helpers.it("produces nothing for a modifier", function()
		local ks = helpers.load_module("infra.keysym")
		ks._set_xkb_for_test(false)
		helpers.assert_eq(ks.to_char("Shift_L"), nil, "a modifier is not a character")
		helpers.assert_eq(ks.to_char("ISO_Level3_Shift"), nil, "nor is AltGr")
	end)

	helpers.it("encodes above the basic plane", function()
		local ks = helpers.load_module("infra.keysym")
		helpers.assert_eq(ks.utf8_encode(0x1F600), "\240\159\152\128",
			"four-byte UTF-8, because a keymap may legally carry an emoji")
		helpers.assert_eq(ks.utf8_encode(0x110000), nil, "and nothing above the range")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 3/ The join: character to keystroke =====================
-- =================================================================
-- =================================================================

helpers.describe("keyboard_layout: resolving against the session's own layout", function()

	helpers.it("gives AZERTY answers, not US ones", function()
		local layout = loaded()
		-- THE assertion. On US "a" is keycode 30; on AZERTY it is 16. A hardcoded
		-- table, a silently-empty parse plus a fallback, and a correct
		-- implementation are indistinguishable on a US fixture and differ here.
		local a = layout.resolve("a")
		helpers.assert_eq(a.keycode, 16, "AZERTY puts A where QWERTY puts Q")
		helpers.assert_eq(a.level, 1, "unshifted")
		helpers.assert_eq(#a.mods, 0, "so no modifier is needed")

		local q = layout.resolve("q")
		helpers.assert_eq(q.keycode, 30, "and Q where QWERTY puts A")
	end)

	helpers.it("types an accented character with no modifier at all", function()
		local layout = loaded()
		-- é is an unshifted key on AZERTY and does not exist on US. This is the
		-- character class the driver's replacements are full of.
		local e = layout.resolve("é")
		helpers.assert_true(e ~= nil, "é must be typable on a French layout")
		helpers.assert_eq(e.keycode, 3, "<AE02> = 11 in XKB is evdev 3")
		helpers.assert_eq(e.level, 1, "unshifted on AZERTY")
		helpers.assert_eq(#e.mods, 0, "no modifier")
	end)

	helpers.it("reports Shift for a level-2 character", function()
		local layout = loaded()
		local caps = layout.resolve("A")
		helpers.assert_eq(caps.keycode, 16, "same key as lowercase")
		helpers.assert_eq(caps.level, 2, "level 2")
		helpers.assert_eq(caps.mods, { "shift" }, "which Shift selects")
	end)

	helpers.it("reports AltGr for a level-3 character", function()
		local layout = loaded()
		local euro = layout.resolve("€")
		helpers.assert_eq(euro.keycode, 18, "<AD03> = 26 in XKB is evdev 18")
		helpers.assert_eq(euro.level, 3, "level 3")
		helpers.assert_eq(euro.mods, { "altgr" },
			"AltGr, not Ctrl+Alt: the injector presses what this names")
	end)

	helpers.it("prefers the lowest level for every character with two homes", function()
		local layout = loaded()
		local kb = helpers.load_module("infra.xkb_keymap")
		local ks = helpers.load_module("infra.keysym")

		-- Computed independently rather than spot-checked. "~" sits on two keys in
		-- this fixture, and asserting one expected level passes by accident when
		-- the rule is "last one parsed wins": pairs() order decides the answer, so
		-- a broken implementation is green about half the time. Comparing against
		-- the minimum derived from the same dump cannot be satisfied by luck.
		local lowest = {}
		local homes = {}
		for _, entry in ipairs(kb.parse(AZERTY_DUMP)) do
			local char = ks.to_char(entry.keysym)
			if char then
				homes[char] = (homes[char] or 0) + 1
				if not lowest[char] or entry.level < lowest[char] then
					lowest[char] = entry.level
				end
			end
		end

		local multi = 0
		for char, level in pairs(lowest) do
			if homes[char] > 1 then multi = multi + 1 end
			-- Every extra level is a synthetic modifier held across the keystroke,
			-- and a held modifier is what stays stuck when an injection is
			-- interrupted.
			helpers.assert_eq(layout.resolve(char).level, level,
				"'" .. char .. "' must be typed at its cheapest level")
		end
		helpers.assert_true(multi >= 1,
			"the fixture must contain at least one character reachable two ways, or "
				.. "this case asserts nothing; found " .. multi)
	end)

	helpers.it("knows what it cannot type", function()
		local layout = loaded()
		helpers.assert_eq(layout.resolve("漢"), nil,
			"a character absent from the layout has no keystroke, and inventing one "
				.. "types something else entirely")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 4/ Planning a whole replacement =========================
-- =================================================================
-- =================================================================

helpers.describe("keyboard_layout: planning a string", function()

	helpers.it("walks UTF-8 by character, not by byte", function()
		local layout = loaded()
		local plan = layout.plan("aé")
		helpers.assert_true(plan ~= nil, "both characters are typable")
		helpers.assert_eq(#plan, 2,
			"é is two bytes and one keystroke; iterating bytes would emit three")
		helpers.assert_eq(plan[1].keycode, 16, "a")
		helpers.assert_eq(plan[2].keycode, 3, "é")
	end)

	helpers.it("refuses the whole string when one character is untypable", function()
		local layout = loaded()
		local plan, blocker = layout.plan("aé漢z")
		-- All-or-nothing, because the trigger has ALREADY been erased by the time
		-- this runs. Typing the prefix and stopping loses the user text they had.
		helpers.assert_eq(plan, nil, "a partial plan must not be returned")
		helpers.assert_eq(blocker, "漢", "and the caller is told which character blocked it")
	end)

	helpers.it("refuses everything when no layout is loaded", function()
		local layout = helpers.load_module("adapters.keyboard_layout")
		layout._set_table_for_test(nil)
		helpers.assert_eq(layout.is_ready(), false, "no table means not ready")
		helpers.assert_eq((layout.plan("abc")), nil,
			"with no layout there is no correct keycode for anything, and guessing "
				.. "US is the defect this replaces — it does not fail, it types the "
				.. "wrong characters")
	end)

	helpers.it("(layout-plan-utf8) refuses malformed bytes instead of skipping them", function()
		local layout = loaded()
		for _, text in ipairs({
			string.char(0x80) .. "az",
			string.char(0xFF) .. "az",
			"a" .. string.char(0xC0, 0xAF) .. "z",
			"az" .. string.char(0xF5, 0x80, 0x80, 0x80),
		}) do
			local plan, blocker = layout.plan(text)
			helpers.assert_nil(plan, "every input byte must belong to a validated character")
			helpers.assert_nil(blocker, "malformed input has no valid blocking character to report")
		end
	end)

	helpers.it("(layout-plan-utf8) refuses incomplete and invalid scalar sequences", function()
		local layout = loaded()
		for _, text in ipairs({
			"a" .. string.char(0xC2),
			string.char(0xC2) .. "az",
			string.char(0xE0, 0x80, 0xAF) .. "az",
			string.char(0xED, 0xA0, 0x80) .. "az",
			string.char(0xF4, 0x90, 0x80, 0x80) .. "az",
		}) do
			helpers.assert_nil((layout.plan(text)), "malformed UTF-8 has no complete keystroke plan")
		end
	end)

	helpers.it("(layout-plan-utf8) keeps healthy and unavailable-input contracts", function()
		local layout = loaded()
		local empty, empty_blocker = layout.plan("")
		helpers.assert_eq(#empty, 0, "an available layout still permits an empty plan")
		helpers.assert_nil(empty_blocker)
		local supported, supported_blocker = layout.plan("aé")
		helpers.assert_eq(#supported, 2)
		helpers.assert_nil(supported_blocker)
		local unsupported, unsupported_blocker = layout.plan("a😀z")
		helpers.assert_nil(unsupported)
		helpers.assert_eq(unsupported_blocker, "😀", "a valid unsupported scalar retains the old blocker")
		local invalid_type, invalid_type_blocker = layout.plan(false)
		helpers.assert_nil(invalid_type)
		helpers.assert_nil(invalid_type_blocker)
		layout._set_table_for_test(nil)
		local absent, absent_blocker = layout.plan("é")
		helpers.assert_nil(absent)
		helpers.assert_eq(absent_blocker, ("é"):sub(1, 1))
		local absent_empty, absent_empty_blocker = layout.plan("")
		helpers.assert_nil(absent_empty)
		helpers.assert_eq(absent_empty_blocker, "")
	end)

	helpers.it("(layout-plan-utf8-missing) refuses malformed blockers before a map is available", function()
		local layout = helpers.load_module("adapters.keyboard_layout")
		layout._set_table_for_test(nil)
		for _, text in ipairs({ string.char(0x80) .. "az", string.char(0xFF) .. "az",
			"a" .. string.char(0xC0, 0xAF) .. "z", "az" .. string.char(0xF5, 0x80, 0x80, 0x80),
			"a" .. string.char(0xC2), string.char(0xC2) .. "az", string.char(0xE0, 0x80, 0xAF) .. "az",
			string.char(0xED, 0xA0, 0x80) .. "az", string.char(0xF4, 0x90, 0x80, 0x80) .. "az" }) do
			local plan, blocker = layout.plan(text)
			helpers.assert_nil(plan)
			helpers.assert_nil(blocker, "the malformed-input receipt cannot depend on layout availability")
		end
	end)

	helpers.it("(layout-plan-utf8-missing) preserves valid unavailable and nonstring receipts", function()
		local layout = helpers.load_module("adapters.keyboard_layout")
		layout._set_table_for_test(nil)
		for _, text in ipairs({ "", "a", "é", "\0", "😀" }) do
			local plan, blocker = layout.plan(text)
			helpers.assert_nil(plan)
			helpers.assert_eq(blocker, text:sub(1, 1), "valid input retains its existing unavailable-layout blocker")
		end
		for _, text in ipairs({ false, 17, {} }) do
			local plan, blocker = layout.plan(text)
			helpers.assert_nil(plan)
			helpers.assert_nil(blocker)
		end
		local nil_plan, nil_blocker = layout.plan(nil)
		helpers.assert_nil(nil_plan)
		helpers.assert_nil(nil_blocker)
	end)

	helpers.it("builds a plausible number of characters from a real dump", function()
		local layout = helpers.load_module("adapters.keyboard_layout")
		local _, count = layout.build(AZERTY_DUMP)
		-- A parse that collapses to almost nothing looks exactly like a layout
		-- with almost nothing on it, and the consequence is silent: every
		-- expansion quietly reroutes elsewhere.
		helpers.assert_true(count >= 20,
			"the fixture carries eleven keys across four levels; got " .. count)
	end)

end)





-- ===============================================================
-- ===============================================================
-- ======= 5/ Quoted block metadata ==============================
-- ===============================================================
-- ===============================================================

helpers.describe("xkb_keymap: quoted block metadata", function()
	local plain = "\n\tkey <AC01> { [ a, A ] };\n"
	local function dump(body, header, prefix)
		return (prefix or "") .. 'xkb_symbols "' .. (header or "healthy") .. '" {' .. body .. '};\nxkb_types "next" { type "T" { modifiers=Shift; }; };'
	end
	local escaped_quote = [[name="Readback \" } metadata"; key <AC01> { [ a, A ] };]]
	local even_backslashes = [[name="Readback \\"; key <AC01> { [ a, A ] };]]
	local odd_backslashes = [[name="Readback \\\" } metadata"; key <AC01> { [ a, A ] };]]
	local cases = {
		{ name = "preserves the exact nested body", text = dump(plain), body = plain },
		{ name = "ignores a closing brace in metadata", body = [[name="Readback } metadata";]] .. plain },
		{ name = "ignores an opening brace in metadata", body = [[name="Readback { metadata";]] .. plain },
		{ name = "ignores balanced braces in metadata", body = [[name="Readback {balanced} metadata";]] .. plain },
		{ name = "ignores inverted braces in metadata", body = [[name="Readback }{ metadata";]] .. plain },
		{ name = "ignores a quoted keyword before the actual block", text = dump(plain, nil, 'xkb_types "t" { type "xkb_symbols" { modifiers=Shift; }; };'), body = plain },
		{ name = "ignores repeated quoted keywords", text = dump(plain, nil, 'xkb_types "xkb_symbols" { name="xkb_symbols"; };'), body = plain },
		{ name = "ignores an escaped quote before the actual block", text = dump(plain, nil, [[name="before \" xkb_symbols } metadata";]]), body = plain },
		{ name = "finds the opener after a quoted opening brace", text = dump(plain, "Readback { header"), body = plain },
		{ name = "finds the opener after a quoted closing brace", text = dump(plain, "Readback } header"), body = plain },
		{ name = "ignores escaped quotes inside the body", body = escaped_quote },
		{ name = "closes a string after an even backslash run", body = even_backslashes },
		{ name = "retains a string after an odd backslash run", body = odd_backslashes },
		{ name = "preserves Unicode metadata bytes", body = [[name="é }{ 😀";]] .. plain },
		{ name = "preserves an empty body", text = dump(""), body = "" },
		{ name = "refuses a missing block", text = 'xkb_types "t" { type "T" { modifiers=Shift; }; };' },
		{ name = "refuses a keyword found only inside a string", text = 'name="xkb_symbols"; unrelated { raw };' },
		{ name = "refuses a missing structural opener", text = 'xkb_symbols "Readback { header";' },
		{ name = "refuses an unclosed header string", text = 'xkb_symbols "Readback { header;' },
		{ name = "refuses an unclosed body string", text = [[xkb_symbols "h" { name="unfinished } ; };]] },
		{ name = "refuses an escaped terminal quote", text = [[xkb_symbols "h" { name="unfinished \" } ; };]] },
		{ name = "refuses a terminal string backslash", text = [[xkb_symbols "h" { name="unfinished \]] },
		{ name = "refuses an unfinished structural block", text = 'xkb_symbols "h" { key <AC01> { [ a, A ] };' },
		{ name = "refuses empty input", text = "" },
		{ name = "refuses nonstring input", text = false },
	}
	for _, spec in ipairs(cases) do
		if spec.text == nil then spec.text = dump(spec.body) end
		helpers.it("(xkb-block-strings) " .. spec.name, function()
			local parser = helpers.load_module("infra.xkb_keymap")
			helpers.assert_eq(parser.block(spec.text, "xkb_symbols"), spec.body,
				"quoted bytes do not choose a structural block or change its exact body")
		end)
	end
end)





-- =================================================================
-- =================================================================
-- ======= 6/ Quoted key definition metadata =======================
-- =================================================================
-- =================================================================

helpers.describe("xkb_keymap: quoted key definition metadata", function()
	local alphabetic = { AC01 = { "a", "A" } }
	local cases = {
		{ name = "balances a closing brace in a quoted type", body = [[key <AC01> { type="Readback } type", symbols[Group1]=[ a, A ] };]], expected = alphabetic },
		{ name = "balances an opening brace in a quoted type", body = [[key <AC01> { type="Readback { type", symbols[Group1]=[ a, A ] };]], expected = alphabetic },
		{ name = "retains balanced quoted braces", body = [[key <AC01> { type="Readback {balanced} type", symbols[Group1]=[ a, A ] };]], expected = alphabetic },
		{ name = "retains inverted quoted braces", body = [[key <AC01> { type="Readback }{ type", symbols[Group1]=[ a, A ] };]], expected = alphabetic },
		{ name = "retains an escaped quote before a quoted brace", body = [[key <AC01> { type="Readback \" } type", symbols[Group1]=[ a, A ] };]], expected = alphabetic },
		{ name = "closes a quoted type after even backslashes", body = [[key <AC01> { type="Readback \\" , symbols[Group1]=[ a, A ] };]], expected = alphabetic },
		{ name = "retains a quoted type after odd backslashes", body = [[key <AC01> { type="Readback \\\" } type", symbols[Group1]=[ a, A ] };]], expected = alphabetic },
		{ name = "ignores a quoted declaration before a real key", body = [[name="key <AC01> { [ z, Z ] }"; key <AC01> { [ a, A ] };]], expected = alphabetic },
		{ name = "ignores a quoted declaration after a real key", body = [[key <AC01> { [ a, A ] }; name="key <AC01> { [ z, Z ] }";]], expected = alphabetic },
		{ name = "ignores a quoted phantom key declaration", body = [[name="key <DECOY> { [ z, Z ] }"; key <AC01> { [ a, A ] };]], expected = alphabetic },
		{ name = "refuses a declaration inside another identifier", body = [[monkey <AC01> { [ z, Z ] };]], expected = {} },
		{ name = "keeps adjacent real declarations distinct", body = [[key <AC01> {[ a, A ]};key <AC02> {[ s, S ]};]], expected = { AC01 = { "a", "A" }, AC02 = { "s", "S" } } },
		{ name = "preserves the existing key-name grammar", body = [[key <A_B+1-2> {[ a, A ]};]], expected = { ["A_B+1-2"] = { "a", "A" } } },
		{ name = "preserves long and short symbols forms", body = [[key <AC01> { type="Readback [ z, Z ] type", symbols[Group1]=[ a, A ] };key <AC02> {[ s, S ]};]], expected = { AC01 = { "a", "A" }, AC02 = { "s", "S" } } },
		{ name = "refuses a declaration without its structural opener", body = [[key <AC01> [ a, A ];]], expected = {} },
		{ name = "retains the empty symbols contract", body = "", expected = {} },
	}
	for _, spec in ipairs(cases) do
		helpers.it("(xkb-key-definition-strings) " .. spec.name, function()
			local parser = helpers.load_module("infra.xkb_keymap")
			local text = 'xkb_symbols "healthy" {' .. spec.body .. '};'
			helpers.assert_eq(parser.parse_symbols(text), spec.expected,
				"real key declarations own complete definitions outside quoted metadata")
		end)
	end
end)





-- ===============================================================
-- ===============================================================
-- ======= 7/ Quoted symbol-list metadata =========================
-- ===============================================================
-- ===============================================================

helpers.describe("xkb_keymap: quoted symbol-list metadata", function()
	local alphabetic = { AC01 = { "a", "A" } }
	local cases = {
		{ name = "ignores a quoted explicit fake list", body = [[key <AC01> { type="Readback symbols[Group1]= [ z, Z ] type", symbols[Group1]=[ a, A ] };]], expected = alphabetic },
		{ name = "ignores a spaced quoted explicit fake list", body = [[key <AC01> { type="Readback symbols [ Group1 ] = [ z, Z ] type", symbols[Group1]=[ a, A ] };]], expected = alphabetic },
		{ name = "ignores a nested quoted explicit fake list", body = [=[key <AC01> { type="Readback [[ symbols[Group1]= [ z, Z ] ]] type", symbols[Group1]=[ a, A ] };]=], expected = alphabetic },
		{ name = "ignores repeated quoted explicit fake lists", body = [[key <AC01> { type="symbols[Group1]=[z,Z] symbols[Group1]=[s,S]", symbols[Group1]=[ a, A ] };]], expected = alphabetic },
		{ name = "ignores a quoted fallback fake list", body = [[key <AC01> { type="Readback [ z, Z ] type", [ a, A ] };]], expected = alphabetic },
		{ name = "retains an earlier real fallback list", body = [[key <AC01> { [ a, A ], type="Readback [ z, Z ] type" };]], expected = alphabetic },
		{ name = "retains an earlier real explicit list", body = [[key <AC01> { symbols[Group1]=[ a, A ], type="symbols[Group1]=[z,Z]" };]], expected = alphabetic },
		{ name = "preserves explicit priority over an earlier fallback", body = [[key <AC01> { [ z, Z ], symbols[Group1]=[ a, A ] };]], expected = alphabetic },
		{ name = "preserves explicit Group1 priority over Group2", body = [[key <AC01> { symbols[Group2]=[ z, Z ], symbols[Group1]=[ a, A ] };]], expected = alphabetic },
		{ name = "preserves the existing fallback index behavior", body = [[key <AC01> { type[Group1]="Readback [ z, Z ] type", [ a, A ] };]], expected = { AC01 = { "Group1" } } },
		{ name = "preserves the existing Group2-only fallback behavior", body = [[key <AC01> { symbols[Group2]=[ z, Z ] };]], expected = { AC01 = { "Group2" } } },
		{ name = "preserves an empty explicit capture", body = [[key <AC01> { [ z, Z ], symbols[Group1]=[] };]], expected = { AC01 = { false } } },
		{ name = "preserves raw keysym spelling and NoSymbol", body = [[key <AC01> { symbols[Group1]=[ U00E9, NoSymbol, A ] };]], expected = { AC01 = { "U00E9", false, "A" } } },
		{ name = "ignores a fake list after an escaped quote", body = [[key <AC01> { type="Readback \" symbols[Group1]=[z,Z] type", symbols[Group1]=[ a, A ] };]], expected = alphabetic },
		{ name = "closes metadata after even backslashes", body = [[key <AC01> { type="Readback \\" , symbols[Group1]=[ a, A ] };]], expected = alphabetic },
		{ name = "retains metadata after odd backslashes", body = [[key <AC01> { type="Readback \\\" symbols[Group1]=[z,Z] type", symbols[Group1]=[ a, A ] };]], expected = alphabetic },
		{ name = "ignores braces and fake lists in the same type", body = [[key <AC01> { type="Readback } symbols[Group1]=[z,Z] { type", symbols[Group1]=[ a, A ] };]], expected = alphabetic },
		{ name = "ignores fake lists in multiple metadata strings", body = [[key <AC01> { type="symbols[Group1]=[z,Z]", name="symbols[Group1]=[s,S]", symbols[Group1]=[ a, A ] };]], expected = alphabetic },
		{ name = "preserves first outside-string match precedence", body = [[key <AC01> { mysymbols[Group1]=[ z, Z ], symbols[Group1]=[ a, A ] };]], expected = { AC01 = { "z", "Z" } } },
		{ name = "retains the no-list contract", body = [[key <AC01> { type="Readback [ z, Z ] type" };]], expected = {} },
	}
	for _, spec in ipairs(cases) do
		helpers.it("(xkb-symbol-list-strings) " .. spec.name, function()
			local parser = helpers.load_module("infra.xkb_keymap")
			helpers.assert_eq(parser.parse_symbols('xkb_symbols "healthy" {' .. spec.body .. '};'), spec.expected,
				"quoted metadata does not own a list; existing unquoted priority and raw captures remain")
		end)
	end
end)


--- Drives real capture, refresh and planning over a controlled native protocol.
--- @param body function
local function cohort_fixture(body)
	local capture = helpers.load_module("adapters.xkb_capture")
	local state = { rows = {} }
	local backend = {
		create = function() return { identity = "owned-cohort-map", group = 0, groups = 2 } end,
		destroy = function() end,
		key_sym = function() return nil end,
		key_utf8 = function() return nil end,
		compose_feed = function() end,
		compose_status = function() return "nothing" end,
		update_key = function(session, code, direction)
			if code == 107 and direction == 1 then session.group = 1 - session.group end
		end,
		capture_group = function(session)
			if state.on_group then state.on_group() end
			return session.group
		end,
		caps_locked = function()
			if state.on_caps then state.on_caps() end
			return state.caps == true
		end,
	}
	backend.inverse = function(session, group)
		local rows = {}
		for code = 32, 126 do rows[string.char(code)] = { keycode = code, level = 1, mods = {} } end
		rows.z = { keycode = group == 1 and 21 or 44, level = 1, mods = {} }
		rows.Z = { keycode = group == 1 and 21 or 44, level = 2, mods = { "shift" } }
		state.rows = rows
		if state.on_inverse then state.on_inverse() end
		return rows
	end
	capture._set_backend(backend)
	local path = os.tmpname()
	local file = assert(io.open(path, "w"))
	file:write("owned-cohort-map")
	file:close()
	local layout = helpers.load_module("adapters.keyboard_layout")
	local ok, err = pcall(function()
		helpers.assert_true(layout.refresh(path))
		body(capture, layout, state, backend, path)
	end)
	layout._set_table_for_test(nil)
	capture._reset_backend()
	os.remove(path)
	if not ok then error(err, 0) end
end


helpers.describe("keyboard_layout: retained inverse cohort", function()
	helpers.it("refuses readiness after an actual capture group action", function()
		cohort_fixture(function(capture, layout)
			capture.process(99, 1)
			helpers.assert_eq(layout.is_ready(), false)
		end)
	end)
	helpers.it("refuses stale character resolution", function()
		cohort_fixture(function(capture, layout)
			capture.process(99, 1)
			helpers.assert_nil(layout.resolve("z"))
		end)
	end)
	helpers.it("refuses a whole stale plan including empty text", function()
		cohort_fixture(function(capture, layout)
			capture.process(99, 1)
			helpers.assert_nil(layout.plan("z"))
			helpers.assert_nil(layout.plan(""))
		end)
	end)
	helpers.it("never revives a cohort after observed group ABA", function()
		cohort_fixture(function(capture, layout)
			capture.process(99, 1)
			capture.process(99, 1)
			helpers.assert_eq(layout.is_ready(), false)
		end)
	end)
	helpers.it("refuses after same-map capture replacement", function()
		cohort_fixture(function(capture, layout)
			helpers.assert_true(capture.load("owned-cohort-map", "C"))
			helpers.assert_nil(layout.resolve("z"))
		end)
	end)
	helpers.it("preserves readiness through ordinary original edges", function()
		cohort_fixture(function(capture, layout)
			capture.process(42, 1)
			capture.process(42, 0)
			helpers.assert_true(layout.is_ready())
			helpers.assert_eq(layout.resolve("z").keycode, 44)
		end)
	end)
	helpers.it("isolates native producer and returned character mutations", function()
		cohort_fixture(function(_, layout, state)
			state.rows.Z.keycode = 30
			state.rows.Z.mods[1] = "altgr"
			local hit = layout.resolve("Z")
			hit.keycode = 31
			hit.mods[1] = "altgr"
			helpers.assert_eq(layout.resolve("Z").keycode, 44)
			helpers.assert_eq(layout.resolve("Z").mods[1], "shift")
		end)
	end)
	helpers.it("isolates returned plans and retains exact admitted data", function()
		cohort_fixture(function(_, layout)
			local plan, _, receipt = layout.plan("ZZ")
			plan[1].keycode, plan[1].mods[1] = 30, "altgr"
			helpers.assert_eq(plan[2].keycode, 44)
			helpers.assert_eq(layout.plan_view(receipt)[1].keycode, 44)
			helpers.assert_eq(layout.plan_view(receipt)[1].mods[1], "shift")
			helpers.assert_nil(layout.plan_view({}), "caller tables cannot become plan owners")
		end)
	end)
	helpers.it("keeps successor refresh while refusing predecessor plans", function()
		cohort_fixture(function(capture, layout, _, _, path)
			local _, _, receipt = layout.plan("z")
			capture.process(99, 1)
			helpers.assert_true(layout.refresh(path))
			helpers.assert_true(layout.is_ready())
			helpers.assert_eq(layout.plan_current(receipt), false)
			helpers.assert_nil(layout.plan_view(receipt))
		end)
	end)
	helpers.it("rejects a source getter replacement without allowing a lookalike", function()
		cohort_fixture(function(_, layout, _, backend)
			backend.capture_group = function() return 0 end
			helpers.assert_eq(layout.is_ready(), false)
		end)
	end)
	helpers.it("rejects capture reentry during readiness observation", function()
		cohort_fixture(function(capture, layout, state)
			state.on_group = function()
				state.on_group = nil
				capture.load("owned-cohort-map", "C")
			end
			helpers.assert_eq(layout.is_ready(), false)
		end)
	end)
	helpers.it("retains a nested refresh and refuses its stale outer publisher", function()
		cohort_fixture(function(_, layout, state, _, path)
			state.on_inverse = function()
				state.on_inverse = nil
				helpers.assert_true(layout.refresh(path))
			end
			helpers.assert_eq(layout.refresh(path), false)
			helpers.assert_true(layout.is_ready())
			helpers.assert_eq(layout.resolve("z").keycode, 44)
		end)
	end)
end)


--- Runs automatic X11 refresh through its actual existing command adapter.
--- @param layout table
--- @param backend table
--- @param state table
--- @param body function
local function desktop_cohort(layout, backend, state, body)
	local display = require("infra.display_server")
	local shell = require("adapters.shell_runner")
	local old_exec = shell.exec
	display._set_for_test("x11")
	shell.exec = function() return "xkb_keymap { controlled desktop source }" end
	state.native_generation, state.acknowledged = 7, true
	backend.source_group = function(session)
		if state.on_source then state.on_source() end
		if not state.acknowledged then return nil, "native-keymap-unacknowledged" end
		local group, generation = session.group, state.native_generation
		return group, generation, function()
			return state.acknowledged == true and state.native_generation == generation and session.group == group
		end
	end
	local ok, err = pcall(function()
		helpers.assert_true(layout.refresh())
		body()
	end)
	shell.exec = old_exec
	display._set_for_test(nil)
	if not ok then error(err, 0) end
end

helpers.describe("keyboard_layout: automatic X11 acknowledgement cohort", function()
	helpers.it("refuses an equal-group native source epoch replacement", function()
		cohort_fixture(function(_, layout, state, backend)
			desktop_cohort(layout, backend, state, function()
				state.native_generation = 8
				helpers.assert_eq(layout.is_ready(), false)
				helpers.assert_nil(layout.resolve("z"))
				helpers.assert_nil(layout.plan("z"))
			end)
		end)
	end)
	helpers.it("never revives after native keymap acknowledgement is lost", function()
		cohort_fixture(function(_, layout, state, backend)
			desktop_cohort(layout, backend, state, function()
				state.acknowledged = false
				helpers.assert_eq(layout.is_ready(), false)
				state.acknowledged = true
				helpers.assert_eq(layout.is_ready(), false)
			end)
		end)
	end)
	helpers.it("refuses a lookalike native desktop getter", function()
		cohort_fixture(function(_, layout, state, backend)
			desktop_cohort(layout, backend, state, function()
				backend.source_group = function() return 0, 7 end
				helpers.assert_eq(layout.is_ready(), false)
			end)
		end)
	end)
	helpers.it("refuses capture replacement during native desktop observation", function()
		cohort_fixture(function(capture, layout, state, backend)
			desktop_cohort(layout, backend, state, function()
				state.on_source = function() state.on_source = nil; capture.reset_state() end
				helpers.assert_eq(layout.is_ready(), false)
			end)
		end)
	end)
	helpers.it("refuses changed native acknowledgement before publishing new rows", function()
		cohort_fixture(function(_, layout, state, backend)
			desktop_cohort(layout, backend, state, function()
				state.on_inverse = function() state.native_generation = state.native_generation + 1 end
				helpers.assert_eq(layout.refresh(), false)
				helpers.assert_eq(layout.is_ready(), false)
			end)
		end)
	end)
	helpers.it("preserves the explicit file override without desktop rights", function()
		cohort_fixture(function(_, layout, state, backend, path)
			desktop_cohort(layout, backend, state, function()
				state.acknowledged = false
				helpers.assert_true(layout.refresh(path))
				helpers.assert_true(layout.is_ready())
				helpers.assert_eq(layout.resolve("z").keycode, 44)
			end)
		end)
	end)
end)

helpers.describe("keyboard_layout: exact native authority and preserved logical contracts", function()
	helpers.it("requires an actual native source epoch for automatic X11 admission", function()
		cohort_fixture(function(_, layout, state, backend)
			desktop_cohort(layout, backend, state, function()
				state.native_generation = nil
				helpers.assert_eq(layout.refresh(), false)
				helpers.assert_eq(layout.is_ready(), false)
			end)
		end)
	end)
	helpers.it("keeps Wayland logical refresh without manufacturing a native seat receipt", function()
		cohort_fixture(function(_, layout, _, backend)
			local display = require("infra.display_server")
			local shell = require("adapters.shell_runner")
			local old_exec = shell.exec
			display._set_for_test("wayland")
			shell.exec = function() return "xkb_keymap { controlled logical source }" end
			backend.source_group = function() return nil, "native-wayland-seat-unqualified" end
			local ok, err = pcall(function()
				helpers.assert_true(layout.refresh())
				helpers.assert_true(layout.is_ready())
				helpers.assert_eq(layout.resolve("z").keycode, 44)
			end)
			shell.exec = old_exec
			display._set_for_test(nil)
			if not ok then error(err, 0) end
		end)
	end)
	helpers.it("never revives an observed replaced native receipt checker", function()
		cohort_fixture(function(capture, layout)
			local original = capture.inverse_current
			capture.inverse_current = function() return true end
			helpers.assert_eq(layout.is_ready(), false)
			capture.inverse_current = original
			helpers.assert_eq(layout.is_ready(), false)
		end)
	end)
end)

helpers.describe("keyboard_layout: terminal plan observation seal", function()
	helpers.it("seals only its exact observed owner without another native callback", function()
		cohort_fixture(function(_, layout, state)
			local _, _, receipt = layout.plan("z")
			state.on_group = function() error("native reads are forbidden in the terminal RAM seal") end
			helpers.assert_true(layout.plan_current(receipt, true))
			helpers.assert_eq(layout.plan_current({}, true), false)
			helpers.assert_eq(layout.plan_current(receipt), false)
			helpers.assert_eq(layout.plan_current(receipt, true), false)
		end)
	end)
end)
