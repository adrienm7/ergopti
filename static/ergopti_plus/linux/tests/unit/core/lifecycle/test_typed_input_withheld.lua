--- tests/unit/core/lifecycle/test_typed_input_withheld.lua

--- ==============================================================================
--- MODULE: Typed Input Withheld Counters Tests
--- DESCRIPTION:
--- The counters Main's text callback keeps when it withholds a character: one
--- count per closed reason, the last reason and stamp, a refused prediction's
--- error type, never its message, and a summary naming every reason.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A fresh owner over a controlled clock.
--- @param now number Milliseconds the clock reads.
--- @return table counters
local function fresh(now)
	package.loaded["infra.typed_input_withheld"] = nil
	local saved = package.loaded["infra.monotonic"]
	package.loaded["infra.monotonic"] = { now_ms = function() return now end }
	local counters = require("infra.typed_input_withheld")
	return counters, function() package.loaded["infra.monotonic"] = saved end
end

helpers.describe("typed input withheld counters", function()
	helpers.it("counts each closed reason and keeps the last one with its stamp", function()
		local counters, restore = fresh(4321.7)
		local ok, err = pcall(function()
			counters.record("field_not_admitted")
			counters.record("field_not_admitted")
			counters.record("queued_during_injection")
			local snapshot = counters.snapshot()
			helpers.assert_eq(snapshot.counts, { queued_during_injection = 1, press_not_admitted = 0,
				field_not_admitted = 2, prediction_refused = 0 })
			helpers.assert_eq(snapshot.last_reason, "queued_during_injection")
			helpers.assert_eq(snapshot.last_ms, 4321)
			helpers.assert_nil(snapshot.last_error_type)
		end)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("keeps a refused prediction's error type and never its message", function()
		local counters, restore = fresh(10)
		local ok, err = pcall(function()
			counters.record("prediction_refused", "typed secret text in the message")
			local summary = counters.summary()
			helpers.assert_eq(counters.snapshot().last_error_type, "string")
			helpers.assert_true(summary:find("prediction_refused=1", 1, true) ~= nil, summary)
			helpers.assert_true(summary:find("prediction error type string", 1, true) ~= nil, summary)
			helpers.assert_nil(summary:find("secret", 1, true), "the message must never reach the summary")
		end)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("names every reason in the summary, zero included, and refuses an unknown one", function()
		local counters, restore = fresh(0)
		local ok, err = pcall(function()
			helpers.assert_eq(counters.summary(), "Typed input withheld from the engines: queued_during_injection=0"
				.. " press_not_admitted=0 field_not_admitted=0 prediction_refused=0.")
			local refused, detail = pcall(counters.record, "typo_reason")
			helpers.assert_eq(refused, false)
			helpers.assert_contains(tostring(detail), "unknown reason typo_reason")
			counters.record("press_not_admitted")
			counters._reset_for_test()
			helpers.assert_eq(counters.snapshot().counts.press_not_admitted, 0)
		end)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("records Main's silent text returns without a logger in the callback", function()
		-- The harnesses compile handle_char alone, with no central logger: the
		-- counters must be reached by require, never through Logger.
		local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
		local source = assert(file:read("*a")); assert(file:close())
		local first = assert(source:find("\tlocal function handle_char(", 1, true))
		local last = assert(source:find("\n\ton_char = input_capture_gate.guard(handle_char)", first, true))
		local body = source:sub(first, last)
		helpers.assert_true(body ~= "", "handle_char must be found")
		for _, reason in ipairs({ "queued_during_injection", "press_not_admitted", "field_not_admitted", "prediction_refused" }) do
			helpers.assert_true(body:find('require("infra.typed_input_withheld").record("' .. reason .. '"', 1, true) ~= nil,
				"handle_char must count " .. reason)
		end
	end)
end)

return true
