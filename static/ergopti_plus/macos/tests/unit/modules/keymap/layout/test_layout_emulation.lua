--- tests/unit/modules/keymap/layout/test_layout_emulation.lua

--- ==============================================================================
--- MODULE: Layout Emulation (macOS)
--- DESCRIPTION:
--- Drives the keymap tap's rewrite of modules/keymap/layout_emulation.lua with
--- the shipped registry layouts and a recorded key-down: the event carries the
--- emulated text, a dead key is deleted, a shortcut chord takes the system
--- layout's key code, and the ISO key pair is named by the keyboard's geometry.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")

local function read_all(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

local KEYCODES = Json.decode(read_all(helpers.shared("layouts/data/mac_keycodes.json")))
local REGISTRY = Json.decode_lossless(read_all(helpers.shared("layouts/data/keycodes/physical_keys.json")))
local INDEX = Json.decode(read_all(helpers.shared("../../layouts/registry/index.json")))

-- macOS virtual key codes of the keys the cases press (ANSI numbering).
local KC_Q, KC_D, KC_C, KC_BACKSLASH, KC_DELETE, KC_ISO_PAIR = 12, 2, 8, 42, 51, 10

--- A recorded key-down.
local function event(flags, chars)
	local e = { flags = flags or {}, chars = chars or "", unicode = nil, keycode = nil }
	function e:getFlags() return self.flags end
	function e:getCharacters() return self.chars end
	function e:setUnicodeString(text) self.unicode = text end
	function e:setKeyCode(code) self.keycode = code end
	function e:setFlags(value) self.flags = value end
	function e:getProperty() return self.autorepeat and 1 or 0 end
	return e
end

--- A fresh module with recorded collaborators and the given [layout] table.
local function fixture(layout, form, source_override)
	package.loaded["modules.keymap.layout_emulation"] = nil
	local M = require("modules.keymap.layout_emulation")
	local record = { paused = false, magic = nil, now = 0, posted = {} }
	M.init({
		read_config = function() return { layout = layout } end,
		default_for = require("infra.manifest_reader").default_for,
		source = source_override or function(id)
			for _, entry in ipairs(INDEX.layouts) do
				if entry.id == id then
					return { id = id, text = read_all(helpers.shared("../../layouts/registry/" .. entry.file)),
						convention = entry.keycode_convention, composer = false }
				end
			end
			return nil, "not shipped"
		end,
		keycodes = function() return KEYCODES end,
		registry = function() return REGISTRY end,
		keyboard_type = function() return 1 end,
		physical_code = function(entry)
			local iso = type(entry.macos_iso) == "table" and entry.macos_iso.hs or entry.hs
			if form == "iso" then return iso end
			return entry.hs
		end,
		keycode_for_char = function(char) return ({ z = 6, c = 8 })[char] end,
		magic_code = function() return record.magic end,
		is_active = function() return not record.paused end,
		autorepeat = function(e) return e.autorepeat == true end,
		now_ms = function() return record.now end,
		post = function(outputs)
			for _, output in ipairs(outputs) do
				if output.type == "text" then record.posted[#record.posted + 1] = output.text
				else
					local names = {}
					for name, held in pairs(output.flags) do if held then names[#names + 1] = name end end
					table.sort(names)
					record.posted[#record.posted + 1] = output.key_code .. "+" .. table.concat(names, "+")
				end
			end
			return true
		end,
	})
	return M, record
end

helpers.describe("layout emulation (macOS keymap tap)", function()
	helpers.it("leaves every key-down untouched while no layout is emulated", function()
		local M = fixture({})
		helpers.assert_true(M.reload(), "an empty configuration reloads")
		local e = event()
		helpers.assert_true(not M.key_down(e, KC_Q), "not deleted")
		helpers.assert_nil(e.unicode, "not rewritten")
	end)

	helpers.it("rewrites a key-down to the emulated Ergopti text", function()
		local M = fixture({ ergopti_base = true, ergopti_variant = "ergopti" })
		helpers.assert_true(M.reload(), "the shipped Ergopti layout loads")
		local e = event({}, "q")
		helpers.assert_true(not M.key_down(e, KC_Q), "the event is kept")
		helpers.assert_eq(e.unicode, "è", "it carries Ergopti's è")
	end)

	helpers.it("deletes a dead key and composes the next key-down", function()
		local M = fixture({ ergopti_base = true, ergopti_variant = "ergopti" })
		M.reload()
		helpers.assert_true(M.key_down(event(), KC_BACKSLASH), "the dead key is deleted")
		local e = event({}, "d")
		helpers.assert_true(not M.key_down(e, KC_D), "the next key is kept")
		helpers.assert_eq(e.unicode, "ê", "circumflex + e")
		helpers.assert_true(M.key_down(event(), KC_BACKSLASH), "a new dead key")
		helpers.assert_true(not M.key_down(event(), KC_DELETE), "Delete passes")
		local after = event({}, "d")
		M.key_down(after, KC_D)
		helpers.assert_eq(after.unicode, "e", "Delete dropped the dead key")
	end)

	helpers.it("drops a pending dead key at a pause so it never composes after the resume (pause-drops-dead-key)", function()
		local M, record = fixture({ ergopti_base = true, ergopti_variant = "ergopti" })
		M.reload()
		helpers.assert_eq(M.drop_pending_dead_key(), false, "nothing pending, nothing dropped")
		helpers.assert_true(M.key_down(event(), KC_BACKSLASH), "the dead key is deleted")
		record.paused = true
		helpers.assert_eq(M.drop_pending_dead_key(), true, "the pause drops the pending dead key")
		record.paused = false
		local after = event({}, "d")
		M.key_down(after, KC_D)
		helpers.assert_eq(after.unicode, "e", "the resumed key types alone, no stale circumflex")
	end)

	helpers.it("moves a Cmd chord to the system layout's key of the Command-level character", function()
		local M = fixture({ emulated_layout = "ergopti", ergopti_base = true })
		M.reload()
		local e = event({ cmd = true }, "q")
		helpers.assert_true(not M.key_down(e, KC_Q), "the chord is kept")
		helpers.assert_eq(e.keycode, 6, "Cmd+Z where Ergopti has z")
		helpers.assert_nil(e.unicode, "a chord's text is the application's")
	end)

	-- A chord of two modifiers takes the key of the layout's character, as a
	-- single-modifier chord does, the held flags kept (ILD-1, decided by the
	-- maintainer on 2026-11-11: the logical key everywhere; two-modifier-chord).
	helpers.it("moves a chord of two modifiers to the layout character's key (two-modifier-chord)", function()
		local M = fixture({ emulated_layout = "ergopti", ergopti_base = true })
		M.reload()
		for _, flags in ipairs({ { cmd = true, shift = true }, { cmd = true, alt = true } }) do
			local e = event(flags, "q")
			helpers.assert_true(not M.key_down(e, KC_Q), "the chord is kept")
			helpers.assert_eq(e.keycode, 6, "Z where Ergopti has z")
			helpers.assert_eq(e.flags, flags, "with the modifiers the hand holds")
			helpers.assert_nil(e.unicode)
		end
	end)

	-- Ctrl+AltGr (Ctrl+Option) sends Ctrl and the logical key with Option
	-- suspended, as Linux does (ILD-2, decided by the maintainer on 2026-11-11;
	-- ctrl-altgr-logical).
	helpers.it("sends Ctrl and the logical key for Ctrl+AltGr, Option suspended (ctrl-altgr-logical)", function()
		local M = fixture({ emulated_layout = "ergopti", ergopti_base = true })
		M.reload()
		for _, held in ipairs({ { ctrl = true, alt = true }, { ctrl = true, alt = true, shift = true } }) do
			local e = event(held, "q")
			helpers.assert_true(not M.key_down(e, KC_Q), "the chord is kept")
			helpers.assert_eq(e.keycode, 6, "Ctrl+Z where Ergopti has z")
			helpers.assert_eq(e.flags, { ctrl = true, shift = held.shift }, "Ctrl kept, Option suspended")
			helpers.assert_nil(e.unicode, "a chord's text is the application's")
		end
	end)

	-- SendEvent "^{z}" sends a matched down and up; the release kept the
	-- physical key code, so applications saw z down never released and a Q up
	-- with no down (ILM-001, cmd-chord-release).
	helpers.it("releases a moved Cmd chord on the key code it was pressed on (cmd-chord-release)", function()
		local M = fixture({ emulated_layout = "ergopti", ergopti_base = true })
		M.reload()
		local down = event({ cmd = true }, "q")
		M.key_down(down, KC_Q)
		helpers.assert_eq(down.keycode, 6, "Cmd+Z where Ergopti has z")
		local up = event({ cmd = true }, "q")
		up.keycode = KC_Q
		helpers.assert_true(not M.key_up(up, KC_Q), "the release is kept")
		helpers.assert_eq(up.keycode, 6, "and released on the same key code")
		local next_up = event({}, "q")
		next_up.keycode = KC_Q
		M.key_up(next_up, KC_Q)
		helpers.assert_eq(next_up.keycode, KC_Q, "only once")
	end)

	-- With a non-Latin input source hs.keycodes.map has no Latin letter, and
	-- the chord silently kept the physical key code: Cmd + physical D (Ergopti
	-- e) went out as Cmd+D. macOS resolves a Command shortcut on the US
	-- positions there, so the fallback is the character's US key code
	-- (ILM-002, cmd-chord-us-key).
	helpers.it("finds a character's US key code for a source that lacks it (cmd-chord-us-key)", function()
		local M = fixture({ emulated_layout = "ergopti", ergopti_base = true })
		local table_of = require("core.text.engine.json").decode(assert(require("adapters.file_system").read(
			require("infra.paths").shared("layouts/data/mac_keycodes.json"))))
		helpers.assert_eq(M.us_keycode("e", table_of), 14, "kVK_ANSI_E")
		helpers.assert_eq(M.us_keycode("Z", table_of), 6, "kVK_ANSI_Z")
		helpers.assert_eq(M.us_keycode("1", table_of), 18, "kVK_ANSI_1")
		helpers.assert_eq(M.us_keycode(".", table_of), 47, "kVK_ANSI_Period")
		helpers.assert_nil(M.us_keycode("é", table_of), "no US key: none")
	end)

	helpers.it("types the Option level as AltGr and clears the Option flag", function()
		local M = fixture({ emulated_layout = "ergol", ergopti_base = true, ergopti_alt_gr = true })
		M.reload()
		local e = event({ alt = true, shift = false }, "œ")
		helpers.assert_true(not M.key_down(e, KC_Q), "kept")
		helpers.assert_eq(e.unicode, "^", "Ergo-L's AltGr symbol")
		helpers.assert_nil(e.flags.alt, "no application reads an Option chord")
	end)

	helpers.it("names the ISO key pair by the keyboard's geometry", function()
		local ansi = fixture({ emulated_layout = "ergopti", ergopti_base = true }, "ansi")
		ansi.reload()
		local on_ansi = event()
		ansi.key_down(on_ansi, KC_ISO_PAIR)
		helpers.assert_eq(on_ansi.unicode, "ê", "code 10 is the ISO key left of Z behind the ANSI virtual keyboard")
		local iso = fixture({ emulated_layout = "ergopti", ergopti_base = true }, "iso")
		iso.reload()
		local on_iso = event()
		iso.key_down(on_iso, KC_ISO_PAIR)
		helpers.assert_eq(on_iso.unicode, "$", "code 10 is the key left of 1 on an ISO keyboard")
	end)

	helpers.it("lets the physical magic key and a paused driver through", function()
		local M, record = fixture({ emulated_layout = "ergopti_plus", ergopti_base = true })
		M.reload()
		record.magic = "KeyC"
		local magic = event({}, "c")
		helpers.assert_true(not M.key_down(magic, KC_C), "kept")
		helpers.assert_nil(magic.unicode, "the magic key owns its unshifted press")
		record.paused = true
		local paused = event({}, "q")
		M.key_down(paused, KC_Q)
		helpers.assert_nil(paused.unicode, "a paused driver types the system layout")
	end)

	helpers.it("leaves a row switched off to the system layout (emulation-row-switch-null-registry)", function()
		-- The registry is decoded losslessly, as in production: its JSON nulls
		-- must still read as character keys for the rows to exist at all.
		local M = fixture({ ergopti_base = true, ergopti_variant = "ergopti_plus", emulate_top_row = false })
		helpers.assert_true(M.reload(), "Ergopti+ loads with the top row off")
		local top = event()
		helpers.assert_true(not M.key_down(top, KC_Q), "the top-row key is not deleted")
		helpers.assert_nil(top.unicode, "the top row types the system layout")
		local home = event()
		M.key_down(home, KC_D)
		helpers.assert_true(home.unicode ~= nil, "the home row is still emulated")
	end)

	helpers.it("turns itself off with an error on a layout it cannot read", function()
		local M = fixture({ emulated_layout = "missing", ergopti_base = true })
		helpers.assert_true(not M.reload(), "the reload refuses")
		helpers.assert_true(M.status().error ~= nil, "the reason is kept for the menu")
		local e = event({}, "q")
		M.key_down(e, KC_Q)
		helpers.assert_nil(e.unicode, "the key is the system layout's")
	end)
end)


-- macOS key codes of the keys the source emulation cases press (ANSI numbering).
local KC_A, KC_SPACE, KC_TAB, KC_HOME, KC_INTL, KC_INSERT, KC_F1, KC_B, KC_END = 0, 49, 48, 115, 10, 114, 122, 11, 119

--- A module emulating the source fixture's compiled layout with the emulation
--- fixture's macOS table on top (_shared/tests/corpus/layouts/source/).
local function source_fixture(table_)
	local corpus = "tests/corpus/layouts/source/"
	local emulation = table_ or Json.decode(read_all(helpers.shared(corpus .. "emulation.json"))).macos
	return fixture({ emulated_layout = "composed", ergopti_base = true }, "ansi", function(id)
		if id ~= "composed" then return nil, "not composed" end
		return { id = id, text = read_all(helpers.shared(corpus .. "source.keylayout")), convention = "iso",
			composer = true, emulation = emulation }
	end)
end

helpers.describe("layout emulation (macOS): a layout source's records", function()
	helpers.it("types a held custom modifier's layer until its key-up (source-emulation)", function()
		local M = source_fixture()
		helpers.assert_true(M.reload(), "the composed layout and its table load")
		helpers.assert_true(M.key_down(event(), KC_INTL), "the modifier key-down is deleted")
		local repeated = event()
		repeated.autorepeat = true
		helpers.assert_true(M.key_down(repeated, KC_INTL), "its repeats are deleted")
		local e = event({}, "a")
		helpers.assert_true(not M.key_down(e, KC_A), "a key of its layer rides its own event")
		helpers.assert_eq(e.unicode, "α")
		helpers.assert_true(M.key_up(event(), KC_INTL), "the modifier key-up is deleted")
		local after = event({}, "a")
		helpers.assert_true(not M.key_down(after, KC_A))
		helpers.assert_eq(after.unicode, "a", "the keylayout types again")
	end)

	helpers.it("keeps a custom modifier held through a pause until its key-up (pause-keeps-held-modifier)", function()
		local M, record = source_fixture()
		helpers.assert_true(M.reload())
		helpers.assert_true(M.key_down(event(), KC_INTL), "the modifier is held")
		record.paused = true
		M.drop_pending_dead_key()
		record.paused = false
		local e = event({}, "a")
		helpers.assert_true(not M.key_down(e, KC_A))
		helpers.assert_eq(e.unicode, "α", "a full reset at pause would have dropped the hold")
		helpers.assert_true(M.key_up(event(), KC_INTL), "its key-up is still owned")
		local after = event({}, "a")
		M.key_down(after, KC_A)
		helpers.assert_eq(after.unicode, "a", "and ends the layer")
	end)

	helpers.it("toggles a locked modifier on its presses (source-emulation)", function()
		local M = source_fixture()
		helpers.assert_true(M.reload())
		helpers.assert_true(M.key_down(event(), KC_INSERT))
		helpers.assert_true(M.key_up(event(), KC_INSERT))
		local e = event({}, "a")
		M.key_down(e, KC_A)
		helpers.assert_eq(e.unicode, "あ")
		helpers.assert_true(M.key_down(event(), KC_INSERT), "a second press unlocks it")
		local after = event({}, "a")
		M.key_down(after, KC_A)
		helpers.assert_eq(after.unicode, "a")
	end)

	helpers.it("rewrites a shortcut and a remap to their key, key-up included (source-emulation)", function()
		local M = source_fixture()
		helpers.assert_true(M.reload())
		local e = event({ ctrl = true }, "a")
		helpers.assert_true(not M.key_down(e, KC_A))
		helpers.assert_eq(e.keycode, KC_B, "Ctrl+A becomes Ctrl+B")
		helpers.assert_eq(e.flags, { ctrl = true })
		local up = event()
		helpers.assert_true(not M.key_up(up, KC_A))
		helpers.assert_eq(up.keycode, KC_B, "its key-up releases B")
		local home = event({ shift = true })
		helpers.assert_true(not M.key_down(home, KC_HOME))
		helpers.assert_eq(home.keycode, KC_END)
		helpers.assert_eq(home.flags, { shift = true }, "a remap keeps the held modifiers")
	end)

	helpers.it("types a tap-hold's tap and adds its held modifier to the keys under it (source-emulation)", function()
		local M, record = source_fixture()
		helpers.assert_true(M.reload())
		record.now = 0
		helpers.assert_true(M.key_down(event(), KC_SPACE))
		record.now = 100
		helpers.assert_true(M.key_up(event(), KC_SPACE))
		helpers.assert_eq(record.posted, { " " }, "released before its threshold: the tap, posted")
		record.now = 1000
		helpers.assert_true(M.key_down(event(), KC_TAB))
		record.now = 1300
		local e = event({}, "a")
		helpers.assert_true(not M.key_down(e, KC_A))
		helpers.assert_eq(e.unicode, "A", "the keylayout types it shifted")
		local f1 = event({})
		helpers.assert_true(not M.key_down(f1, KC_F1), "a key the keylayout leaves to the system")
		helpers.assert_eq(f1.flags, { shift = true }, "goes out with the held Shift")
		helpers.assert_true(M.key_up(event(), KC_TAB))
		local after = event({}, "a")
		M.key_down(after, KC_A)
		helpers.assert_eq(after.unicode, "a", "the held Shift ends with the key")
	end)

	helpers.it("posts a settled tap before the press that settled it (source-emulation)", function()
		local M, record = source_fixture()
		helpers.assert_true(M.reload())
		record.now = 0
		helpers.assert_true(M.key_down(event(), KC_SPACE))
		record.now = 50
		helpers.assert_true(M.key_down(event({}, "a"), KC_A), "the press is replayed after the tap")
		helpers.assert_eq(record.posted, { " ", "a" })
	end)

	helpers.it("refuses a malformed table and drops held state on reset (source-emulation)", function()
		local bad = Json.decode(read_all(helpers.shared("tests/corpus/layouts/source/emulation.json"))).macos
		bad.version = 2
		local refused = source_fixture(bad)
		helpers.assert_true(not refused.reload(), "the reload fails")
		helpers.assert_true(not refused.key_down(event(), KC_INTL), "the key passes")
		local M = source_fixture()
		helpers.assert_true(M.reload())
		helpers.assert_true(M.key_down(event(), KC_INTL))
		M.reset()
		local e = event({}, "a")
		M.key_down(e, KC_A)
		helpers.assert_eq(e.unicode, "a", "the custom modifier no longer holds")
	end)
end)
