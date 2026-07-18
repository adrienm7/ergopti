--- tests/unit/modules/keylogger/test_virtual_synthetic_telemetry.lua

--- ==============================================================================
--- MODULE: Virtual synthetic telemetry source regression tests
--- DESCRIPTION: Clipboard insertion has no per-character OS events. The
--- keylogger must therefore materialise logical synthetic events immediately,
--- then discard only the delayed physical echoes of direct key injection.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("keylogger: virtual synthetic telemetry for clipboard output", function()
	local function source()
		local text = helpers.read_driver_source("function M.notify_synthetic")
		helpers.assert_not_nil(text, "cannot find keylogger synthetic telemetry source")
		return text
	end

	helpers.it("records logical chars before queuing only discard echoes", function()
		local body = source():match("function M%.notify_synthetic.-\nend")
		helpers.assert_true(body ~= nil, "cannot locate notify_synthetic")
		helpers.assert_true(body:find("append_virtual(utf8.char(code))", 1, true) ~= nil,
			"logical synthetic output must enter buffer_events even for Cmd+V")
		helpers.assert_true(body:find("discard = true", 1, true) ~= nil,
			"direct OS echoes must be marked for discard, not re-aggregated")
		helpers.assert_true(body:find("local echo_text = type(physical_echo)", 1, true) ~= nil,
			"physical echo must be an explicit, separate input")
	end)

	helpers.it("flushes a virtual paste so output cannot wait forever for a key event", function()
		local body = source():match("function M%.notify_synthetic.-\nend")
		helpers.assert_true(body ~= nil, "cannot locate notify_synthetic")
		helpers.assert_true(body:find("LogManager.flush_buffer()", 1, true) ~= nil,
			"virtual clipboard output must be persisted without waiting for another key")
	end)

	helpers.it("does not add a second LLM manifest trigger", function()
		local text = source()
		helpers.assert_true(text:find("LogManager.increment_manifest_stat(target_app, \"llm_triggers\")", 1, true) == nil,
			"the synthetic typing burst must remain the sole llm_triggers source")
	end)
end)
