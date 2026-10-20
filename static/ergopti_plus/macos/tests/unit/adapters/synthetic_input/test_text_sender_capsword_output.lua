--- tests/unit/adapters/synthetic_input/test_text_sender_capsword_output.lua

--- ==============================================================================
--- MODULE: TextSender Reports Its Output To CapsWord
--- DESCRIPTION:
--- Text the driver types (a replayed delimiter, an accepted prediction, a
--- paste) may never cross the CapsWord watcher's eventtap, yet a delimiter in it
--- must end CapsWord as typed output. TextSender reports every accepted text to
--- infra/capsword_output, and nothing it failed to send.
--- ==============================================================================

local helpers = require("tests.helpers")

local function load_sender(emitted)
	package.loaded["adapters.text_sender"] = nil
	package.loaded["adapters.synthetic_input"] = {
		emit_key_strokes = function() return emitted end,
		defer_after_callback = function(_label, callback) callback(); return true end,
	}
	return helpers.load_with_stubs("adapters.text_sender", {
		eventtap = { keyStroke = function() end, keyStrokes = function() end },
	})
end

helpers.describe("TextSender reports driver output to CapsWord", function()
	helpers.it("an accepted text reaches the CapsWord relay, a refused one does not", function()
		helpers.with_stub_scope({ "adapters.text_sender", "adapters.synthetic_input", "infra.capsword_output" }, function()
			package.loaded["infra.capsword_output"] = nil
			local Output = require("infra.capsword_output")
			local reported = {}
			helpers.assert_true(Output.set_observer(function(text) reported[#reported + 1] = text end))
			local Sender = load_sender(true)
			helpers.assert_eq(Sender.send("; ", { mode = "direct" }), true)
			helpers.assert_eq(reported, { "; " }, "the typed text is reported")
			local Refused = load_sender(false)
			helpers.assert_eq(Refused.send(".", { mode = "direct" }), false)
			helpers.assert_eq(reported, { "; " }, "a refused text is not reported")
			Output.set_observer(nil)
		end)
	end)
end)
