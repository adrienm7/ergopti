--- tests/unit/modules/keymap/test_layout_emulation.lua

--- ==============================================================================
--- MODULE: Layout Emulation (Linux)
--- DESCRIPTION:
--- Drives the consumption decision of modules/keymap/layout_emulation.lua with
--- the shipped registry layouts and recorded collaborators: the grabbed press is
--- replaced by the emulated layout's text, dead keys wait, shortcut chords
--- press the Command-level key, and every refusal lets the key through.
--- ==============================================================================

local helpers = require("tests.helpers")
local Paths = require("infra.paths")
local Json = require("json")

local function read_all(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

local KEYCODES = Json.decode(read_all(Paths.shared("modules/layouts/mac_keycodes.json")))
local REGISTRY = Json.decode_lossless(read_all(Paths.shared("data/keycodes/physical_keys.json")))
local INDEX = Json.decode(read_all(Paths.shared("../../layouts/registry/index.json")))

-- evdev codes of the keys the cases press (input-event-codes.h).
local KEY_Q, KEY_D, KEY_C, KEY_BACKSLASH, KEY_BACKSPACE, KEY_F1 = 16, 32, 46, 43, 14, 59

--- A fresh module with recorded collaborators and the given [layout] table.
local function fixture(layout, overrides)
	package.loaded["modules.keymap.layout_emulation"] = nil
	local M = require("modules.keymap.layout_emulation")
	local record = { typed = {}, dispatched = {}, shortcuts = {}, keys = {}, now = 0, paused = false, typable = true,
		magic = nil }
	local deps = {
		read_config = function() return { layout = layout } end,
		default_for = require("infra.manifest_reader").default_for,
		source = function(id)
			for _, entry in ipairs(INDEX.layouts) do
				if entry.id == id then
					return { id = id, text = read_all(Paths.shared("../../layouts/registry/" .. entry.file)),
						convention = entry.keycode_convention, composer = false }
				end
			end
			return nil, "not shipped"
		end,
		keycodes = function() return KEYCODES end,
		registry = function() return REGISTRY end,
		type_text = function(text)
			if not record.typable then return false end
			record.typed[#record.typed + 1] = text
			return true
		end,
		dispatch_char = function(char) record.dispatched[#record.dispatched + 1] = char end,
		emit_shortcut = function(char) record.shortcuts[#record.shortcuts + 1] = char return true end,
		emit_key = function(code, modifiers)
			record.keys[#record.keys + 1] = code .. "+" .. table.concat(modifiers, "+")
			return record.emittable ~= false
		end,
		now_ms = function() return record.now end,
		caps_locked = function() return false end,
		magic_evdev = function() return record.magic end,
		is_active = function() return not record.paused end,
	}
	for key, value in pairs(overrides or {}) do deps[key] = value end
	M.init(deps)
	return M, record
end

local function press(M, code, mods, char)
	return M.on_key({ code = code, mods = mods or {}, char = char, value = 1 })
end

helpers.describe("layout emulation (Linux consumption)", function()
	helpers.it("leaves every key to the system layout while no layout is emulated", function()
		local M, record = fixture({})
		helpers.assert_true(M.reload(), "an empty configuration reloads")
		helpers.assert_true(not M.status().active, "nothing is emulated")
		helpers.assert_true(not press(M, KEY_Q), "the key passes")
		helpers.assert_eq(#record.typed, 0, "nothing typed")
	end)

	helpers.it("types the built-in Ergopti variant in the grabbed key's place", function()
		local M, record = fixture({ ergopti_base = true, ergopti_variant = "ergopti" })
		helpers.assert_true(M.reload(), "the shipped Ergopti layout loads")
		helpers.assert_eq(M.status().id, "ergopti", "the variant's registry layout")
		local consumed, repeat_callback = press(M, KEY_Q, {}, "q")
		helpers.assert_true(consumed, "the press is consumed")
		helpers.assert_eq(record.typed, { "è" }, "Ergopti types è on the key right of Tab")
		helpers.assert_eq(record.dispatched, { "è" }, "the character path sees the emulated text")
		helpers.assert_true(repeat_callback({ code = KEY_Q, mods = {}, value = 2 }), "the held key repeats")
		helpers.assert_eq(record.typed, { "è", "è" }, "a repeat types again")
		helpers.assert_true(not repeat_callback({ code = KEY_D, mods = {}, value = 2 }), "another key's repeat is refused")
	end)

	helpers.it("waits on a dead key and composes the next key", function()
		local M, record = fixture({ ergopti_base = true, ergopti_variant = "ergopti" })
		M.reload()
		helpers.assert_true(press(M, KEY_BACKSLASH), "the dead key is consumed")
		helpers.assert_eq(#record.typed, 0, "nothing typed while it is pending")
		helpers.assert_true(press(M, KEY_D), "the next key is consumed")
		helpers.assert_eq(record.typed, { "ê" }, "circumflex + e")
		helpers.assert_true(press(M, KEY_BACKSLASH), "a new dead key")
		helpers.assert_true(not press(M, KEY_BACKSPACE), "Backspace passes")
		helpers.assert_true(press(M, KEY_D), "then e")
		helpers.assert_eq(record.typed, { "ê", "e" }, "Backspace dropped the dead key")
	end)

	helpers.it("presses the Command-level key of a shortcut chord", function()
		local M, record = fixture({ emulated_layout = "ergopti", ergopti_base = true })
		M.reload()
		helpers.assert_true(press(M, KEY_Q, { ctrl = true }), "Ctrl+key is replaced")
		helpers.assert_eq(record.shortcuts, { "z" }, "Ergopti's Command level")
		helpers.assert_true(not press(M, KEY_F1, { ctrl = true }), "a key outside the layout passes")
	end)

	helpers.it("lets the physical magic key, a pause and a failed typing through", function()
		local M, record = fixture({ emulated_layout = "ergopti_plus", ergopti_base = true })
		M.reload()
		record.magic = KEY_C
		helpers.assert_true(not press(M, KEY_C), "the magic key keeps its unshifted press")
		record.magic = nil
		record.paused = true
		helpers.assert_true(not press(M, KEY_Q), "a paused driver passes every key")
		record.paused = false
		record.typable = false
		helpers.assert_true(not press(M, KEY_Q), "an untyped text lets the key through")
		helpers.assert_eq(#record.dispatched, 0, "nothing reached the character path")
	end)

	helpers.it("keeps the AltGr layer alone when the base layer is off", function()
		local M, record = fixture({ emulated_layout = "ergol", ergopti_alt_gr = true })
		M.reload()
		helpers.assert_true(not press(M, KEY_Q), "the base level is the system layout's")
		helpers.assert_true(press(M, KEY_Q, { altgr = true }), "AltGr is emulated")
		helpers.assert_eq(record.typed, { "^" }, "Ergo-L's AltGr symbol")
	end)

	helpers.it("leaves a row switched off to the system layout (emulation-row-switch-null-registry)", function()
		-- The registry is decoded losslessly, as in production: its JSON nulls
		-- must still read as character keys for the rows to exist at all.
		local M, record = fixture({ ergopti_base = true, ergopti_variant = "ergopti_plus", emulate_top_row = false })
		helpers.assert_true(M.reload(), "Ergopti+ loads with the top row off")
		helpers.assert_true(not press(M, KEY_Q), "the top row types the system layout")
		helpers.assert_true(press(M, KEY_D), "the home row is still emulated")
		helpers.assert_eq(#record.typed, 1, "only the home-row key typed")
	end)

	helpers.it("turns itself off with an error on a layout it cannot read", function()
		local M = fixture({ emulated_layout = "missing", ergopti_base = true })
		helpers.assert_true(not M.reload(), "the reload refuses")
		local status = M.status()
		helpers.assert_true(not status.active and status.error ~= nil, "the reason is kept for the menu")
		helpers.assert_true(not press(M, KEY_Q), "the key passes")
	end)

	helpers.it("refuses a second initialization and missing collaborators", function()
		local M = fixture({})
		helpers.assert_true(not pcall(M.init, {}), "a second init raises")
		M._reset_for_test()
		helpers.assert_true(not pcall(M.init, { read_config = function() end }), "missing collaborators raise")
	end)
end)


-- evdev codes of the keys the source emulation cases press.
local KEY_A, KEY_SPACE, KEY_TAB, KEY_HOME, KEY_INTL, KEY_INSERT = 30, 57, 15, 102, 86, 110

--- A module emulating the source fixture's compiled layout with the emulation
--- fixture's Linux table on top (_shared/tests/corpus/layouts/source/).
local function source_fixture(table_)
	local corpus = "tests/corpus/layouts/source/"
	local emulation = table_ or Json.decode(read_all(Paths.shared(corpus .. "emulation.json"))).linux
	return fixture({ emulated_layout = "composed", ergopti_base = true }, {
		source = function(id)
			if id ~= "composed" then return nil, "not composed" end
			return { id = id, text = read_all(Paths.shared(corpus .. "source.keylayout")), convention = "iso",
				composer = true, emulation = emulation }
		end,
	})
end

helpers.describe("layout emulation (Linux): a layout source's records", function()
	helpers.it("types a held custom modifier's layer until the key's release (source-emulation)", function()
		local M, record = source_fixture()
		helpers.assert_true(M.reload(), "the composed layout and its table load")
		local consumed, on_repeat, on_release = press(M, KEY_INTL)
		helpers.assert_true(consumed, "the modifier key is consumed")
		helpers.assert_eq(type(on_release), "function", "it owns its release")
		helpers.assert_true(on_repeat({ code = KEY_INTL, mods = {} }), "its repeats are swallowed")
		helpers.assert_true(press(M, KEY_A), "a key of its layer is typed by the emulation")
		helpers.assert_eq(record.typed, { "α" })
		helpers.assert_eq(record.dispatched, { "α" }, "the character path sees the text")
		helpers.assert_true(on_release({ code = KEY_INTL, value = 0 }))
		helpers.assert_true(press(M, KEY_A), "the keylayout types again")
		helpers.assert_eq(record.typed, { "α", "a" })
	end)

	helpers.it("settles a lost release before a new press of a held key (source-emulation)", function()
		local M, record = source_fixture()
		helpers.assert_true(M.reload())
		helpers.assert_true(press(M, KEY_INTL))
		helpers.assert_true(press(M, KEY_INTL), "a second real press is a new hold, not a repeat")
		helpers.assert_true(press(M, KEY_A))
		helpers.assert_eq(record.typed, { "α" })
	end)

	helpers.it("toggles a locked modifier and presses its layer's keys (source-emulation)", function()
		local M, record = source_fixture()
		helpers.assert_true(M.reload())
		helpers.assert_true(press(M, KEY_INSERT))
		helpers.assert_true(press(M, KEY_A))
		helpers.assert_eq(record.typed, { "あ" })
		helpers.assert_true(press(M, KEY_INSERT), "a second press unlocks it")
		helpers.assert_true(press(M, KEY_A))
		helpers.assert_eq(record.typed, { "あ", "a" })
	end)

	helpers.it("sends a shortcut's own key and a remap's target (source-emulation)", function()
		local M, record = source_fixture()
		helpers.assert_true(M.reload())
		helpers.assert_true(press(M, KEY_A, { ctrl = true }))
		helpers.assert_true(press(M, KEY_HOME, { shift = true }))
		helpers.assert_eq(record.keys, { "KeyB+control", "End+shift" })
		helpers.assert_eq(record.shortcuts, {}, "the keylayout's own shortcut path is not used")
		record.emittable = false
		helpers.assert_true(not press(M, KEY_A, { ctrl = true }), "a key that cannot be pressed passes")
	end)

	helpers.it("types a tap-hold's tap and holds a modifier for the keys under it (source-emulation)", function()
		local M, record = source_fixture()
		helpers.assert_true(M.reload())
		record.now = 0
		local consumed, _, on_release = press(M, KEY_SPACE)
		helpers.assert_true(consumed)
		record.now = 100
		helpers.assert_true(on_release({ code = KEY_SPACE, value = 0 }))
		helpers.assert_eq(record.typed, { " " }, "released before its threshold: the tap")
		record.now = 1000
		local _, _, tab_release = press(M, KEY_TAB)
		record.now = 1300
		helpers.assert_true(press(M, KEY_A), "a key under the held Shift")
		helpers.assert_eq(record.typed, { " ", "A" }, "the keylayout types it shifted")
		helpers.assert_true(press(M, KEY_F1), "a key the keylayout leaves to the OS")
		helpers.assert_eq(record.keys, { "F1+shift" }, "it goes out with the held Shift")
		record.now = 1400
		helpers.assert_true(tab_release({ code = KEY_TAB, value = 0 }))
		helpers.assert_true(press(M, KEY_A))
		helpers.assert_eq(record.typed, { " ", "A", "a" }, "the held Shift ends with the key")
		helpers.assert_true(not press(M, KEY_F1), "and the OS has the key alone again")
	end)

	helpers.it("refuses a malformed table: the system layout types every key (source-emulation)", function()
		local table_ = Json.decode(read_all(Paths.shared("tests/corpus/layouts/source/emulation.json"))).linux
		table_.version = 2
		local M, record = source_fixture(table_)
		helpers.assert_true(not M.reload(), "the reload fails")
		helpers.assert_true(not M.status().active)
		helpers.assert_true(not press(M, KEY_INTL), "the key passes")
		helpers.assert_eq(record.typed, {})
	end)

	helpers.it("drops held source state on reset (source-emulation)", function()
		local M, record = source_fixture()
		helpers.assert_true(M.reload())
		helpers.assert_true(press(M, KEY_INTL))
		M.reset()
		helpers.assert_true(press(M, KEY_A))
		helpers.assert_eq(record.typed, { "a" }, "the custom modifier no longer holds")
	end)
end)
