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
local Json = require("core.text.engine.json")

local function read_all(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

local KEYCODES = Json.decode(read_all(Paths.shared("layouts/data/mac_keycodes.json")))
local REGISTRY = Json.decode_lossless(read_all(Paths.shared("layouts/data/keycodes/physical_keys.json")))
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

	-- A pause stops typing (EDD-1, maintainer decision 2026-11-12): a paused
	-- daemon leaves every key to the system layout, and types again on resume.
	helpers.it("types nothing while paused and the layout again on resume (edd1-real-pause)", function()
		local M, record = fixture({ ergopti_base = true, ergopti_variant = "ergopti" })
		helpers.assert_true(M.reload(), "the shipped Ergopti layout loads")
		record.paused = true
		helpers.assert_true(not press(M, KEY_Q, {}, "q"), "a paused daemon lets the key through")
		helpers.assert_eq(#record.typed, 0, "nothing is typed while paused")
		helpers.assert_eq(#record.dispatched, 0, "nothing reaches the character path while paused")
		record.paused = false
		helpers.assert_true(press(M, KEY_Q, {}, "q"), "the resumed daemon emulates again")
		helpers.assert_eq(record.typed, { "è" })
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

	helpers.it("drops a pending dead key at a pause so it never composes after the resume (pause-drops-dead-key)", function()
		local M, record = fixture({ ergopti_base = true, ergopti_variant = "ergopti" })
		M.reload()
		helpers.assert_eq(M.drop_pending_dead_key(), false, "nothing pending, nothing dropped")
		helpers.assert_true(press(M, KEY_BACKSLASH), "the dead key is consumed")
		record.paused = true
		helpers.assert_eq(M.drop_pending_dead_key(), true, "the pause drops the pending dead key")
		record.paused = false
		helpers.assert_true(press(M, KEY_D), "then e")
		helpers.assert_eq(record.typed, { "e" }, "the resumed key types alone, no stale circumflex")
	end)

	helpers.it("presses the Command-level key of a shortcut chord", function()
		local M, record = fixture({ emulated_layout = "ergopti", ergopti_base = true })
		M.reload()
		helpers.assert_true(press(M, KEY_Q, { ctrl = true }), "Ctrl+key is replaced")
		helpers.assert_eq(record.shortcuts, { "z" }, "Ergopti's Command level")
		helpers.assert_true(not press(M, KEY_F1, { ctrl = true }), "a key outside the layout passes")
	end)

	-- Windows registers a keyboard slot on the key that types its letter in the
	-- emulated layout; Linux matched the system layout's key (ILX-001).
	helpers.it("names the emulated letter of a chord for the shortcut slots, typing nothing (ilx-001-slot-emulated-letter)", function()
		local M, record = fixture({ emulated_layout = "ergopti", ergopti_base = true })
		M.reload()
		helpers.assert_eq(M.chord_key({ code = KEY_Q, mods = { ctrl = true } }), "z", "Ctrl on Q is Ergopti's z")
		helpers.assert_eq(M.chord_key({ code = KEY_Q, mods = { alt = true } }), "z")
		helpers.assert_nil(M.chord_key({ code = KEY_Q, mods = {} }), "no chord, no slot letter")
		helpers.assert_nil(M.chord_key({ code = KEY_F1, mods = { ctrl = true } }), "a key outside the layout")
		helpers.assert_eq(record.shortcuts, {}, "the query sends nothing")
		helpers.assert_eq(record.typed, {}, "and types nothing")
		record.paused = true
		helpers.assert_nil(M.chord_key({ code = KEY_Q, mods = { ctrl = true } }), "a paused emulation names nothing")
		local off = fixture({ emulated_layout = "" })
		off.reload()
		helpers.assert_nil(off.chord_key({ code = KEY_Q, mods = { ctrl = true } }), "no emulated layout")
	end)

	-- A chord of two modifiers sends the key of the layout's character, as a
	-- single-modifier chord does, the held modifiers kept (ILD-1, decided by the
	-- maintainer on 2026-11-11: the logical key everywhere; two-modifier-chord).
	helpers.it("sends the layout's key for a chord of two modifiers (two-modifier-chord)", function()
		local sent = {}
		local M = fixture({ emulated_layout = "ergopti", ergopti_base = true }, {
			emit_shortcut = function(char, _, mods)
				local names = {}
				for name, held in pairs(mods) do if held then names[#names + 1] = name end end
				table.sort(names)
				sent[#sent + 1] = char .. ":" .. table.concat(names, "+")
				return true
			end,
		})
		M.reload()
		helpers.assert_true(press(M, KEY_Q, { ctrl = true, shift = true }), "Ctrl+Shift+key is replaced")
		helpers.assert_true(press(M, KEY_Q, { ctrl = true, alt = true }), "Ctrl+Alt+key is replaced")
		helpers.assert_eq(sent, { "z:ctrl+shift", "z:alt+ctrl" }, "Ergopti's z with the held modifiers")
	end)

	-- Ctrl+AltGr is Ctrl and the key's logical character with AltGr suspended,
	-- the rule macOS now follows too (ILD-2, decided by the maintainer on
	-- 2026-11-11; ctrl-altgr-logical): the production chord carries no AltGr.
	helpers.it("presses Ctrl and the logical key for Ctrl+AltGr, AltGr suspended (ctrl-altgr-logical)", function()
		local saved = { combo = package.loaded["modules.gestures.combo_emitter"],
			layout = package.loaded["adapters.keyboard_layout"] }
		local chords = {}
		package.loaded["modules.gestures.combo_emitter"] = {
			KEYSYM_TO_CODE = { z = 44 },
			press_codes = function(modifiers, keys)
				chords[#chords + 1] = { modifiers = modifiers, keys = keys }
				return true
			end,
		}
		package.loaded["adapters.keyboard_layout"] = { shortcut_keycode = function(_, us_code) return us_code, {} end }
		local ok, problem = pcall(function()
			package.loaded["modules.keymap.layout_emulation"] = nil
			local M = require("modules.keymap.layout_emulation")
			local deps = M.production_deps({ injector = {}, is_paused = function() return false end,
				dispatch_char = function() return false end, magic_evdev = function() return nil end, dry_run = false })
			helpers.assert_true(deps.emit_shortcut("z", KEY_Q, { ctrl = true, altgr = true }))
			helpers.assert_true(deps.emit_shortcut("z", KEY_Q, { ctrl = true, shift = true, altgr = true }))
		end)
		package.loaded["modules.gestures.combo_emitter"] = saved.combo
		package.loaded["adapters.keyboard_layout"] = saved.layout
		package.loaded["modules.keymap.layout_emulation"] = nil
		if not ok then error(problem, 0) end
		local Codes = require("infra.evdev_codes")
		helpers.assert_eq(chords, {
			{ modifiers = { Codes.KEY_LEFTCTRL }, keys = { 44 } },
			{ modifiers = { Codes.KEY_LEFTCTRL, Codes.KEY_LEFTSHIFT }, keys = { 44 } },
		}, "Ctrl and the logical z, with no AltGr in the chord")
	end)

	-- AHK's ^SCxxx hotkeys fire on every auto-repeat and macOS rewrites each
	-- repeated key-down; Linux consumed the chord with no repeat callback, so
	-- the hook swallowed every repeat: holding Ctrl+z undid once (ILL-004,
	-- emulation-shortcut-repeat).
	helpers.it("repeats an emulated chord while its key is held (emulation-shortcut-repeat)", function()
		local M, record = fixture({ emulated_layout = "ergopti", ergopti_base = true })
		M.reload()
		local consumed, repeat_callback = M.on_key({ code = KEY_Q, mods = { ctrl = true }, char = "q" })
		helpers.assert_true(consumed, "the chord is the emulation's")
		helpers.assert_type(repeat_callback, "function", "and so are its repeats")
		helpers.assert_true(repeat_callback({ code = KEY_Q, mods = { ctrl = true }, char = "q" }), "a repeat presses it again")
		helpers.assert_eq(record.shortcuts, { "z", "z" })
		helpers.assert_true(not repeat_callback({ code = KEY_D, mods = { ctrl = true }, char = "d" }),
			"another key's repeat is not its own")
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
		local passed, pass_repeat = press(M, KEY_F1)
		helpers.assert_true(passed, "a key the keylayout leaves to the OS")
		helpers.assert_eq(record.keys, { "F1+shift" }, "it goes out with the held Shift")
		-- Held, it repeats under the held Shift, as with a real one (ilx-002-held-modifier-repeat).
		helpers.assert_eq(type(pass_repeat), "function", "the passed key owns its repeat")
		helpers.assert_true(pass_repeat({ code = KEY_F1, mods = {}, value = 2 }))
		helpers.assert_eq(record.keys, { "F1+shift", "F1+shift" }, "each repeat presses it again")
		helpers.assert_true(not pass_repeat({ code = KEY_A, mods = {}, value = 2 }), "another key's repeat is not its own")
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
