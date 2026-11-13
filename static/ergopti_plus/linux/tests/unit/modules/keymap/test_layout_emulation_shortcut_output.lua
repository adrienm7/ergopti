--- tests/unit/modules/keymap/test_layout_emulation_shortcut_output.lua

--- ==============================================================================
--- MODULE: Layout Emulation Shortcut Output Custody
--- DESCRIPTION:
--- Presses an emulated shortcut through the emulation's production
--- collaborators (layout_emulation.production_deps) on the real uinput writer,
--- modifier broker and injector, recorded at the byte boundary. The chord must
--- go through the broker, which owns every write on the virtual keyboard: a
--- write beside it moves the writer's epoch under the broker, which then
--- refuses every later output — the next emulated key, every expansion and the
--- grab's own pass-through. Found by tests/hardware/run_layout_typing_live.lua
--- (Ctrl + Ergopti c copied, then nothing typed again).
--- ==============================================================================

local helpers = require("tests.helpers")
local Codes = require("platform.input.evdev_codes")

local KEY_W, KEY_X = 17, 45

--- Runs body with the real writer, broker and injector on a recording backend.
--- @param body function body(deps, rows, injector)
local function with_output(body)
	local Input = require("platform.input.event")
	local rows = {}
	local saved_hook = package.loaded["platform.input.keyboard_hook"]
	package.loaded["platform.input.keyboard_hook"] = {
		held_text_modifier_codes = function() return {} end,
		held_shortcut_modifier_codes = function() return {} end,
		held_forwarded_keys = function() return {} end,
		held_modifier_codes = function() return {} end,
		emergency_stop = function() end,
	}
	local path = os.tmpname()
	assert(assert(io.open(path, "wb")):close())
	local writer = helpers.load_module("platform.input.uinput_writer")
	writer._set_path_for_test(path)
	writer._set_backend({ open = function() return 7 end, ioctl = function() return true end,
		close = function() return true end, write = function(_, bytes)
			local event = Input.decode(bytes)
			if event.type == Input.EV_KEY then rows[#rows + 1] = event.code .. ":" .. event.value end
			return true
		end })
	local layout = helpers.load_module("adapters.keyboard_layout")
	-- AZERTY: z is KEY_W, x is KEY_X, both on the base level.
	layout._set_table_for_test({ z = { keycode = KEY_W, level = 1, mods = {} },
		x = { keycode = KEY_X, level = 1, mods = {} } })
	helpers.load_module("gestures.engine.combo_emitter")
	local injector = helpers.load_module("modules.hotstrings.injector")
	injector._set_nanosleep_for_test(function() end)
	local emulation = helpers.load_module("modules.keymap.layout_emulation")
	local ok, err = pcall(function()
		assert(injector.open_fast_channel(), "the recorded channel opens")
		local deps = emulation.production_deps({ injector = injector, is_paused = function() return false end,
			dispatch_char = function() end, magic_evdev = function() return nil end })
		body(deps, rows, injector)
	end)
	injector.close_fast_channel()
	layout._set_table_for_test(nil)
	writer._reset_backend()
	writer._set_path_for_test(nil)
	os.remove(path)
	package.loaded["platform.input.keyboard_hook"] = saved_hook
	if not ok then error(err, 0) end
end

helpers.describe("layout emulation: shortcut output custody", function()
	helpers.it("presses the emulated shortcut through the broker and keeps the output usable (emulation-shortcut-custody)", function()
		with_output(function(deps, rows, injector)
			helpers.assert_true(deps.emit_shortcut("z", 44, { ctrl = true }), "the emulated Ctrl+z is pressed")
			local broker = injector.output_broker()
			helpers.assert_true(broker ~= nil and broker.output_current(), "the broker still owns the output")
			local chord = table.concat(rows, " ")
			local typed = injector.type_directly("x")
			helpers.assert_true(typed.ok == true, "the next emulated key still types: " .. tostring(typed.error))
			helpers.assert_eq(chord,
				Codes.KEY_LEFTCTRL .. ":1 " .. KEY_W .. ":1 " .. KEY_W .. ":0 " .. Codes.KEY_LEFTCTRL .. ":0",
				"Ctrl is held around the key the session layout types z with")
		end)
	end)

	helpers.it("keeps a Shift the hand holds in the emulated chord (emulation-shortcut-custody)", function()
		with_output(function(deps, rows)
			helpers.assert_true(deps.emit_shortcut("z", 44, { ctrl = true, shift = true }), "Ctrl+Shift+z is pressed")
			local text = table.concat(rows, " ")
			helpers.assert_true(text:find(Codes.KEY_LEFTSHIFT .. ":1", 1, true) ~= nil
				and text:find(Codes.KEY_LEFTCTRL .. ":1", 1, true) ~= nil
				and text:find(KEY_W .. ":1 " .. KEY_W .. ":0", 1, true) ~= nil, "Ctrl and Shift hold the key: " .. text)
		end)
	end)

	-- _KLE_OnShortcut sends the logical character. Under a session layout that
	-- has no key for it (Cyrillic), the chord fell back to the PHYSICAL key:
	-- Ctrl + the key where Ergopti has c went out on KEY_X, which GTK and Qt
	-- read as cut. The fallback is the character's US key, as a toolkit
	-- resolves a shortcut on a non-Latin layout (ILL-003, emulation-shortcut-us-key).
	helpers.it("falls back to the character's US key when the session layout lacks it (emulation-shortcut-us-key)", function()
		with_output(function(deps, rows)
			helpers.assert_true(deps.emit_shortcut("c", KEY_X, { ctrl = true }), "Ctrl+c is pressed")
			helpers.assert_eq(table.concat(rows, " "),
				Codes.KEY_LEFTCTRL .. ":1 46:1 46:0 " .. Codes.KEY_LEFTCTRL .. ":0", "on KEY_C, not the physical KEY_X")
		end)
	end)
end)
