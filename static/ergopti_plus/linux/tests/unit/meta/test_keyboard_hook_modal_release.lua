--- tests/unit/meta/test_keyboard_hook_modal_release.lua

--- ==============================================================================
--- MODULE: A Dialog Gets The Keyboard
--- DESCRIPTION:
--- Tray dialogs (zenity) run inside a menu callback and block the event loop,
--- which is the only path from the grabbed keyboard to the desktop. Nothing
--- could be typed into them: not an API key, not a delay. The hook now hands
--- the keyboard back for the dialog's lifetime and takes it again afterwards,
--- releasing the virtual keys it held and forgetting what was typed meanwhile.
--- ==============================================================================

local helpers = require("tests.helpers")

local EV_KEY = 1
local KEY_A = 30

helpers.describe("keyboard_hook.while_released: a dialog runs with the keyboard released", function()

	helpers.it("releases held keys, ungrabs, runs the dialog, then grabs back", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		local Reader = require("adapters.evdev_reader")
		local trail = {}
		local originals = { grab = Reader.grab, ungrab = Reader.ungrab }
		Reader.ungrab = function(slot) trail[#trail + 1] = "ungrab"; return originals.ungrab(slot) end
		Reader.grab = function(slot) trail[#trail + 1] = "grab"; return originals.grab(slot) end
		local returned, desynced = nil, false
		kh._test_drive({ { type = EV_KEY, code = KEY_A, value = 1 } }, {
			onChar = function()
				returned = kh.while_released(function()
					trail[#trail + 1] = "dialog"
					return "typed value"
				end)
			end,
			onDesync = function() desynced = true end,
			onEmitRaw = function(code, value)
				trail[#trail + 1] = string.format("emit %d:%d", code, value)
				return true
			end,
		}, true)
		Reader.grab, Reader.ungrab = originals.grab, originals.ungrab

		local text = table.concat(trail, ", ")
		local function at(entry)
			for index, value in ipairs(trail) do if value == entry then return index end end
			return nil
		end
		helpers.assert_eq(returned, "typed value", "the dialog's answer reaches the caller")
		helpers.assert_true(at("emit 30:0") and at("emit 30:0") < at("ungrab"),
			"the A the daemon forwarded is released before the desktop takes the keyboard: " .. text)
		helpers.assert_true(at("ungrab") < at("dialog") and at("dialog") < at("grab"),
			"the dialog runs between the release and the new grab: " .. text)
		helpers.assert_true(desynced, "text typed before the dialog no longer describes the caret")
	end)

	helpers.it("runs the dialog directly when nothing is grabbed", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		helpers.assert_eq(kh.while_released(function() return 42 end), 42)
	end)

	helpers.it("takes the keyboard back even when the dialog raises", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		local Reader = require("adapters.evdev_reader")
		local grabbed = 0
		local original = Reader.grab
		Reader.grab = function(slot) grabbed = grabbed + 1; return original(slot) end
		local raised
		kh._test_drive({ { type = EV_KEY, code = KEY_A, value = 1 } }, {
			onChar = function()
				local before = grabbed
				local ok, err = pcall(kh.while_released, function() error("dialog failed", 0) end)
				raised = not ok and err == "dialog failed" and grabbed == before + 1
			end,
			onEmitRaw = function() return true end,
		}, true)
		Reader.grab = original
		helpers.assert_true(raised, "the error propagates after the keyboard is grabbed again")
	end)

end)
