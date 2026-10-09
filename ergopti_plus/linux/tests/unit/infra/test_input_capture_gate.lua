--- tests/unit/infra/test_input_capture_gate.lua

--- ==============================================================================
--- MODULE: Owned Input Capture Regression
--- DESCRIPTION:
--- Proves editor focus inhibits every guarded global input consumer and that a
--- stale page epoch cannot release a replacement WebView's ownership (LNX-050).
--- ==============================================================================

local helpers = require("tests.helpers")
local InputCaptureGate = helpers.load_module("infra.input_capture_gate")

helpers.describe("input capture gate: guarded input", function()
		helpers.it("runs no character, physical-key, or control side effect while owned", function()
		local resets = 0
		local blocked_bookkeeping = 0
		local calls = { chars = 0, physical = 0, controls = 0, llm = 0, holds = 0 }
		local gate = InputCaptureGate.new({ on_block = function() resets = resets + 1 end })
		local on_char = gate.guard(function() calls.chars = calls.chars + 1 end)
		local on_physical = gate.guard(function() calls.physical = calls.physical + 1 end,
			function() blocked_bookkeeping = blocked_bookkeeping + 1 end)
		local on_control = gate.guard(function() calls.controls = calls.controls + 1 end)
		local on_consume = gate.guard(function() calls.llm = calls.llm + 1 end)
		local on_hold = gate.guard(function() calls.holds = calls.holds + 1 end)

		local acquired, epoch = gate.acquire("hotstring_editor", 12)
		helpers.assert_true(acquired)
		helpers.assert_eq(epoch, 12)
		on_char("x", 45)
		on_physical(45, "x", "x", 1)
		on_control("backspace")
		on_consume({ key = "1" })
		on_hold(45, 100)
		helpers.assert_eq(calls, { chars = 0, physical = 0, controls = 0, llm = 0, holds = 0 })
		helpers.assert_eq(resets, 1, "the first owner must invalidate prior text state once")
		helpers.assert_eq(blocked_bookkeeping, 1,
			"local key-lifecycle bookkeeping may run without reaching a global consumer")

		helpers.assert_true(gate.release("hotstring_editor", 12))
		on_char("x", 45)
		on_physical(45, "x", "x", 1)
		on_control("backspace")
		on_consume({ key = "1" })
		on_hold(45, 100)
		helpers.assert_eq(calls, { chars = 1, physical = 1, controls = 1, llm = 1, holds = 1 })
	end)
end)

helpers.describe("input capture gate: page epochs", function()
	helpers.it("rejects a stale blur after a replacement page acquires ownership", function()
		local gate = InputCaptureGate.new()
		helpers.assert_true(gate.acquire("hotstring_editor", 20))
		helpers.assert_true(gate.release("hotstring_editor", 20))
		helpers.assert_true(gate.acquire("hotstring_editor", 21))
		helpers.assert_eq(gate.release("hotstring_editor", 20), false)
		helpers.assert_true(gate.blocks_text(), "the replacement page still owns input")
		helpers.assert_true(gate.release("hotstring_editor", 21))
		helpers.assert_eq(gate.blocks_text(), false)
	end)

	helpers.it("clears every owner during daemon shutdown", function()
		local gate = InputCaptureGate.new()
		gate.acquire("hotstring_editor", 4)
		gate.acquire("another_owned_editor", 7)
		gate.release_all()
		helpers.assert_eq(gate.blocks_text(), false)
	end)
end)

helpers.describe("input capture gate: daemon wiring", function()
	helpers.it("guards every keyboard-hook path that can inject, predict, or record", function()
		local source_path = debug.getinfo(1, "S").source:gsub("^@", "")
		local driver_root = source_path:match("^(.*)[/\\]tests[/\\]unit[/\\]infra[/\\]") or "."
		local fh = assert(io.open(driver_root .. "/ergopti_hotstrings.lua", "r"))
		local source = fh:read("*a")
		fh:close()

		local guard_count = 0
		for _ in source:gmatch("input_capture_gate%.guard%(") do guard_count = guard_count + 1 end
		helpers.assert_true(guard_count >= 5,
			"every side-effecting input route needs the same owned gate")
		local start_at = assert(source:find("keyboard_hook.start({", 1, true))
		local end_at = assert(source:find("Logger.info(LOG, \"Keyboard hook started", start_at, true))
		local wiring = source:sub(start_at, end_at)
		for _, assignment in ipairs({
			"onChar  = on_char", "onKey   = on_control", "onPhysical = on_physical",
			"onConsume = on_consume", "onHold = on_hold",
		}) do
			helpers.assert_contains(wiring, assignment,
				"the guarded callback is disconnected from the production hook: " .. assignment)
		end
	end)
end)
