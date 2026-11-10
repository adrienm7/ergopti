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
local Json = require("json")

local function read_all(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

local KEYCODES = Json.decode(read_all(helpers.shared("modules/layouts/mac_keycodes.json")))
local REGISTRY = Json.decode_lossless(read_all(helpers.shared("data/keycodes/physical_keys.json")))
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
	return e
end

--- A fresh module with recorded collaborators and the given [layout] table.
local function fixture(layout, form)
	package.loaded["modules.keymap.layout_emulation"] = nil
	local M = require("modules.keymap.layout_emulation")
	local record = { paused = false, magic = nil }
	M.init({
		read_config = function() return { layout = layout } end,
		default_for = require("infra.manifest_reader").default_for,
		source = function(id)
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

	helpers.it("moves a Cmd chord to the system layout's key of the Command-level character", function()
		local M = fixture({ emulated_layout = "ergopti", ergopti_base = true })
		M.reload()
		local e = event({ cmd = true }, "q")
		helpers.assert_true(not M.key_down(e, KC_Q), "the chord is kept")
		helpers.assert_eq(e.keycode, 6, "Cmd+Z where Ergopti has z")
		helpers.assert_nil(e.unicode, "a chord's text is the application's")
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
