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
