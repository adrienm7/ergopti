--- tests/unit/modules/keymap/test_clipboard_synthetic_telemetry.lua

--- ==============================================================================
--- MODULE: Clipboard synthetic telemetry regression tests
--- DESCRIPTION: Clipboard expansions must keep their physical echo empty while
--- passing their complete logical output to keylogger.notify_synthetic. Without
--- this split, Cmd+V inserted text reaches neither raw typing events nor the
--- hotstring/LLM counters used by the source-filtered WPM UI.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
helpers.load_with_stubs("infra.logger")

local KU = helpers.load_with_stubs("modules.keymap.utils")

helpers.describe("clipboard output reaches synthetic telemetry", function()
	helpers.it("emit_text keeps paste echoes empty but returns the full logical output", function()
		local logical = ("p"):rep(60)
		local count, physical, received_logical = KU.emit_text(logical)
		helpers.assert_eq(count, 60)
		helpers.assert_eq(physical, "", "Cmd+V must not populate expected_synthetic_chars")
		helpers.assert_eq(received_logical, logical, "telemetry must receive every pasted codepoint")
	end)

	helpers.it("emit_tokens includes pasted text in logical output but not physical echo", function()
		local pasted = ("a"):rep(60)
		local count, physical, logical = KU.emit_tokens({
			{ kind = "text", value = "Hi " },
			{ kind = "text", value = pasted },
		})
		helpers.assert_eq(count, 63)
		helpers.assert_eq(physical, "Hi ")
		helpers.assert_eq(logical, "Hi " .. pasted)
	end)

	helpers.it("perform_text_replacement forwards logical clipboard output separately", function()
		local received = nil
		package.loaded["modules.keylogger"] = {
			notify_synthetic = function(text, source, deletes, variant, physical)
				received = { text = text, source = source, deletes = deletes, variant = variant, physical = physical }
			end,
			set_buffer = function() end,
		}
		local E = helpers.load_with_stubs("modules.keymap.expander")
		local state = {
			buffer = "abc", expected_synthetic_chars = "", expected_synthetic_deletes = 0,
			magic_key = "*", repeat_enabled = false,
			is_repeat_feature_enabled = function() return false end,
			suppress_rescan = function() end,
		}
		E.init(state, { is_terminator = function() return false end }, {
			get_llm_enabled = function() return false end,
			update_preview = function() end,
		})
		local pasted = ("z"):rep(60)
		E.perform_text_replacement(3, function() return 60, "", pasted end,
			function() state.buffer = pasted end, false, false, "llm", "test")
		helpers.assert_eq(state.expected_synthetic_chars, "")
		helpers.assert_true(received ~= nil, "keylogger must receive the logical paste")
		helpers.assert_eq(received.text, pasted)
		helpers.assert_eq(received.physical, "")
		helpers.assert_eq(received.deletes, 3)
		package.loaded["modules.keylogger"] = nil
	end)
end)
