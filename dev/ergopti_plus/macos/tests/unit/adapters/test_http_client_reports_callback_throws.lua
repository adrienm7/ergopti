--- tests/unit/adapters/test_http_client_reports_callback_throws.lua

--- ==============================================================================
--- MODULE: Regression — a throw in an HTTP completion callback must be reported
---         (http-callback-throws-reported)
--- DESCRIPTION:
--- The last two homes of the swallow-and-forget shape, after the LLM backends
--- were migrated: the HTTP adapter's four response paths, and the Ollama
--- non-streaming handler whose ENTIRE body sat inside one bare pcall.
---
--- ROOT CAUSE ENCODED: a pcall whose status is never inspected is not error
--- handling, it is error deletion. A throw in the LLM response handler — a
--- parser choking on a malformed body, a renderer hitting a nil field — became
--- indistinguishable from a request that never completed. No prediction, no
--- error, nothing to search the log for. The blast radius here is the whole
--- handler: status checks, JSON decode, result shaping and the success hand-off
--- all run inside that one wrapper.
---
--- The adapter cannot reuse the LLM layer's protected_call — adapters must not
--- depend on modules — so it carries the same contract locally: xpcall with a
--- traceback, because by the time the error surfaces the stack is gone, and
--- Logger.error, because an xpcall whose result is discarded deletes the error
--- exactly as the bare pcall did.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ================================================================
-- ================================================================
-- ======= 1/ The adapter reports instead of swallowing ===========
-- ================================================================
-- ================================================================

helpers.describe("http_client: a throwing completion callback is logged, not swallowed", function()
	helpers.it("reports the throw and contains it", function()
		local errors = {}
		package.loaded["lib.logger"] = nil
		local real_logger = require("lib.logger")
		local spy = setmetatable({}, { __index = real_logger })
		spy.error = function(_mod, fmt, ...)
			local ok, formatted = pcall(string.format, fmt, ...)
			errors[#errors + 1] = ok and formatted or tostring(fmt)
		end
		package.loaded["lib.logger"] = spy

		package.loaded["adapters.http_client"] = nil
		local HC = helpers.load_with_stubs("adapters.http_client", {
			http = {
				-- Deliver a response synchronously so the completion path runs
				-- inside this test rather than on a real run loop.
				asyncPost = function(_url, _body, _headers, cb)
					cb(200, "{}", {})
					return { cancel = function() end }
				end,
				asyncGet = function(_url, _headers, cb)
					cb(200, "{}", {})
					return { cancel = function() end }
				end,
			},
			timer = {
				doAfter = function(_d, _fn) return { stop = function() end } end,
			},
		})

		local reached = false
		local ok = pcall(function()
			HC.post("http://localhost/x", {}, "{}", function(_r) error("boom in the handler") end)
			reached = true
		end)

		helpers.assert_true(ok and reached,
			"the adapter must contain the throw: these run from HTTP completion handlers, where "
				.. "an escaping exception is reported far from its cause and takes the rest of the "
				.. "completion path with it")

		local reported = false
		for _, msg in ipairs(errors) do
			if msg:find("callback", 1, true) or msg:find("boom", 1, true) then reported = true end
		end
		helpers.assert_true(reported,
			"and it must LOG the failure. A pcall whose status is never inspected deletes the "
				.. "error, so a throw in the response handler is indistinguishable from a request "
				.. "that never completed — no prediction, no error, nothing to search for. "
				.. "Errors seen: " .. (#errors > 0 and table.concat(errors, " | ") or "(none)"))

		package.loaded["lib.logger"] = nil
		package.loaded["adapters.http_client"] = nil
	end)
end)




-- ================================================================
-- ================================================================
-- ======= 2/ No bare-pcall hand-off survives =====================
-- ================================================================
-- ================================================================

helpers.describe("the last swallow sites are migrated", function()
	helpers.it("http_client invokes no callback through a bare pcall", function()
		local src = helpers.read_driver_source("adapters.http_client")
		helpers.assert_true(src ~= nil and src ~= "", "http_client must be locatable")

		local code = src:gsub("%-%-[^\n]*", "")

		helpers.assert_true(code:find("pcall(callback", 1, true) == nil,
			"every response path must report a throwing callback instead of discarding the "
				.. "status — timeout, HTTP response, and both dispatch-failure paths")
		helpers.assert_true(code:find("xpcall", 1, true) ~= nil
			and code:find("debug.traceback", 1, true) ~= nil,
			"and it must use xpcall with a traceback: by the time the error surfaces the stack "
				.. "is gone, and the traceback is the only thing that says where it failed")

		local uses = 0
		for _ in code:gmatch("invoke_callback%(") do uses = uses + 1 end
		helpers.assert_true(uses >= 4,
			"all four response paths must route through the wrapper (found " .. uses
				.. ") — a guard that only forbids the old shape is satisfied by deleting the calls")
	end)

	helpers.it("the Ollama response handler reports its own throws", function()
		local src = helpers.read_driver_source("OLLAMA_KILL_SETTLE_SEC")
		local code = src:gsub("%-%-[^\n]*", "")

		local at = code:find("local status, body = r.status, r.body", 1, true)
		helpers.assert_true(at ~= nil, "the non-streaming response handler must be locatable")

		local body = code:sub(at, at + 300)
		helpers.assert_true(body:find("xpcall", 1, true) ~= nil,
			"the whole non-streaming path — status checks, JSON decode, result shaping and the "
				.. "success hand-off — runs inside this wrapper, so a bare pcall here deletes an "
				.. "error whose blast radius is the entire handler")
		-- Anchored so "xpcall(function()" does not match: a plain substring search
		-- for the broken spelling is satisfied by the FIXED one, which contains it.
		helpers.assert_true(body:find("[^x]pcall%(function%(%)") == nil,
			"and the bare-pcall spelling must be gone")
	end)
end)
