--- tests/unit/llm/test_callbacks_never_swallowed.lua

--- ==============================================================================
--- MODULE: Regression — an LLM callback that throws must not vanish
---         (llm-callbacks-never-swallowed)
--- DESCRIPTION:
--- Every backend hands its result to a caller-supplied callback, and all of
--- those hand-offs were written as bare `pcall(on_x, ...)`. pcall whose result
--- is never inspected is not error handling, it is error deletion: an
--- engine-side throw — a parser choking on a malformed body, a renderer hitting
--- a nil field — became indistinguishable from a request that simply never
--- completed. No prediction, no error, nothing to search the log for. That is
--- the exact shape of the "green but no prediction" reports.
---
--- ROOT CAUSE ENCODED: the adapters were already ratcheted against precisely
--- this shape after the same bug in text_sender and http_client. The LLM
--- backends were never brought in line and grew to seventy such sites across
--- seven modules.
---
--- The wrapper uses xpcall with a traceback rather than plain pcall: by the
--- time an error surfaces the stack is gone, and the traceback is the only
--- thing that says WHICH callback failed and where. It contains the error
--- rather than rethrowing, because these run from HTTP completion handlers and
--- timer callbacks where an escaping exception is reported far from its cause.
--- ==============================================================================

local helpers = require("tests.helpers")

local function api_common()
	return helpers.load_with_stubs("modules.llm.api_common", {})
end




-- =========================================================================
-- =========================================================================
-- ======= 1/ The wrapper reports instead of swallowing ====================
-- =========================================================================
-- =========================================================================

helpers.describe("api_common.protected_call: a throwing callback is reported", function()
	helpers.it("contains the exception rather than letting it escape", function()
		local A = api_common()
		helpers.assert_true(type(A.protected_call) == "function",
			"api_common must expose the protected call wrapper")

		-- Both witnesses matter. "It did not throw" alone is satisfied by a
		-- wrapper that never calls the callback at all, which is the very
		-- silence this fix exists to remove.
		local invoked, resumed = false, false
		local _, err = pcall(function()
			A.protected_call(function()
				invoked = true
				error("boom")
			end, "on_success", "payload")
			resumed = true
		end)

		helpers.assert_eq(invoked, true,
			"the callback must actually be invoked — a wrapper that quietly skips it would pass a "
				.. "did-not-crash check while deleting the result just as thoroughly")
		helpers.assert_eq(resumed, true,
			"the throw must be contained: execution has to continue past the hand-off. These run "
				.. "from HTTP completion handlers and timer callbacks, where an escaping exception "
				.. "is reported far from its cause and takes the rest of the completion path with it")
		helpers.assert_eq(err, nil, "nothing may escape the wrapper")
	end)

	helpers.it("forwards every argument on the nominal path", function()
		local A = api_common()
		local seen = {}
		A.protected_call(function(a, b, c) seen = { a, b, c } end, "on_result", "first", 42, false)

		helpers.assert_eq(seen[1], "first", "the first argument must arrive unchanged")
		helpers.assert_eq(seen[2], 42, "the second argument must arrive unchanged")
		helpers.assert_eq(seen[3], false,
			"a FALSE argument must arrive too — several callbacks take booleans, and an "
				.. "implementation that stopped at the first nil-or-false would silently drop them")
	end)

	helpers.it("a non-function callback is a no-op", function()
		local A = api_common()

		local _, nil_err = pcall(A.protected_call, nil, "on_partial", "payload")
		helpers.assert_eq(nil_err, nil,
			"several backends leave on_partial and on_cancel unset by design, so a nil callback "
				.. "must be a no-op — exactly what the type(x) == \"function\" guards at the call "
				.. "sites already expressed")

		local _, table_err = pcall(A.protected_call, {}, "on_cancel")
		helpers.assert_eq(table_err, nil,
			"and the guard must test callability rather than mere presence: a value that is set "
				.. "but not a function has to be ignored too, not called")
	end)

	helpers.it("uses xpcall with a traceback, not bare pcall", function()
		local src = helpers.read_driver_source("protected_call")
		helpers.assert_true(src ~= nil and src ~= "",
			"api_common must be locatable by its protected_call symbol")

		local at = src:find("function M.protected_call", 1, true)
		helpers.assert_true(at ~= nil, "protected_call must exist")
		local body = src:sub(at, at + 700):gsub("%-%-[^\n]*", "")

		helpers.assert_true(body:find("xpcall", 1, true) ~= nil,
			"the wrapper must use xpcall. By the time the error surfaces the stack is gone, and "
				.. "the traceback is the only thing that identifies WHICH callback failed")
		helpers.assert_true(body:find("debug.traceback", 1, true) ~= nil,
			"and pass debug.traceback as its handler")
		helpers.assert_true(body:find("Logger.error", 1, true) ~= nil,
			"and log the failure at ERROR — an xpcall whose result is discarded deletes the error "
				.. "exactly as the bare pcall did")
	end)
end)




-- =========================================================================
-- =========================================================================
-- ======= 2/ No bare pcall callback site survives =========================
-- =========================================================================
-- =========================================================================

helpers.describe("llm backends: no callback is invoked through a bare pcall", function()
	helpers.it("every backend routes its callbacks through the wrapper", function()
		local src = helpers.read_driver_source("protected_call")
		helpers.assert_true(src ~= nil and src ~= "",
			"the LLM backend sources must be locatable")

		local code = src:gsub("%-%-[^\n]*", "")

		local offenders = {}
		local lineno = 0
		for line in (code .. "\n"):gmatch("([^\n]*)\n") do
			lineno = lineno + 1
			if line:find("pcall%(on_[A-Za-z_]") then
				offenders[#offenders + 1] = lineno .. ": " .. line:gsub("^%s+", "")
			end
		end

		helpers.assert_eq(#offenders, 0,
			"a callback is still invoked through a bare pcall. Its result is never inspected, so "
				.. "an engine-side throw is deleted rather than handled and becomes "
				.. "indistinguishable from a request that never completed:\n  "
				.. table.concat(offenders, "\n  "))
	end)

	helpers.it("the wrapper is actually used, not merely defined", function()
		local src = helpers.read_driver_source("protected_call")
		local uses = 0
		local pos = 1
		while true do
			local at = src:find("protected_call(", pos, true)
			if not at then break end
			uses = uses + 1
			pos = at + 1
		end
		-- Seventy hand-offs across the MLX, Ollama and remote backends, plus the
		-- definition and this file's own references.
		helpers.assert_true(uses >= 50,
			"the backends must route their callbacks through the wrapper (found only " .. uses
				.. " reference(s)) — a guard that only forbids the old shape is satisfied by "
				.. "deleting the calls instead of wrapping them")
	end)
end)
