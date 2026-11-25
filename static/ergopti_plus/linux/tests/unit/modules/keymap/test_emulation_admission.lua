--- tests/unit/modules/keymap/test_emulation_admission.lua

--- ==============================================================================
--- MODULE: Layout Emulation Inside Ergopti's Own Windows (Linux)
--- DESCRIPTION:
--- Field report, Arch Linux, KDE Plasma Wayland, 2026-11-25: with the layout
--- emulation on, the user typed his physical layout inside Ergopti's own text
--- fields, while the emulation kept typing in a password manager. The daemon's
--- whole key consumption sat behind the input capture gate an Ergopti text
--- field holds, the layout emulation included. These cases drive the real gate:
--- the emulation types while it is held, every other consumer waits, and a
--- key the emulation leaves passes raw.
--- ==============================================================================

local helpers = require("tests.helpers")
local Admission = require("modules.keymap.emulation_admission")
local CaptureGate = require("platform.input.capture_gate")

local KEY_Q = 16

--- A consumer over the real gate, an emulation that types « a » for Q, and a
--- recorder of the ordinary consumers.
local function fixture()
	local gate = CaptureGate.new()
	local seen = { emulated = 0, ordinary = 0, repeated = 0, released = 0 }
	local function emulate(detail)
		if detail.code ~= KEY_Q then return false end
		seen.emulated = seen.emulated + 1
		return true, function() seen.repeated = seen.repeated + 1; return true end,
			function() seen.released = seen.released + 1 end
	end
	local function ordinary(detail)
		seen.ordinary = seen.ordinary + 1
		return emulate(detail)
	end
	return Admission.consumer(gate, emulate, ordinary), gate, seen
end

helpers.describe("layout emulation admission (emulation-in-own-window)", function()
	helpers.it("types the emulated key in an Ergopti text field holding the gate (emulation-in-own-window)", function()
		local consume, gate, seen = fixture()
		helpers.assert_true(gate.acquire("hotstring_editor"), "the editor's text field holds the gate")
		local verdict = consume({ code = KEY_Q, char = "q", mods = {} })
		helpers.assert_eq(type(verdict), "table", "the emulated key is consumed and typed in its place")
		helpers.assert_eq(verdict.consume, true)
		helpers.assert_eq(seen.emulated, 1)
		helpers.assert_eq(seen.ordinary, 0, "hotstrings, shortcuts and the AI stay withheld")
		helpers.assert_true(verdict.repeat_callback({ code = KEY_Q }), "its repeats type too")
		verdict.release_callback()
		helpers.assert_eq({ seen.repeated, seen.released }, { 1, 1 }, "and it owns its release")
	end)

	helpers.it("passes a key the emulation leaves raw while the gate is held (emulation-in-own-window)", function()
		local consume, gate, seen = fixture()
		gate.acquire("hotstring_editor")
		local verdict = consume({ code = 30, char = "a", mods = {} })
		helpers.assert_true(not verdict, "not consumed: the field receives the key itself")
		helpers.assert_eq(seen.ordinary, 0)
	end)

	helpers.it("runs every consumer once the gate is released (emulation-in-own-window)", function()
		local consume, gate, seen = fixture()
		gate.acquire("hotstring_editor")
		gate.release("hotstring_editor")
		consume({ code = KEY_Q, char = "q", mods = {} })
		helpers.assert_eq(seen.ordinary, 1)
	end)

	helpers.it("is the consumption callback the daemon gives the hook (emulation-in-own-window)", function()
		local source = assert(helpers.read_module_source("ergopti_hotstrings"))
		local wired = source:find('local on_consume = require("modules.keymap.emulation_admission").consumer(', 1, true)
		helpers.assert_true(wired ~= nil, "the daemon builds on_consume through the admission")
		helpers.assert_true(source:find("local on_consume = input_capture_gate.guard(", 1, true) == nil,
			"the gate no longer withholds the whole consumption, the emulation included")
	end)
end)
