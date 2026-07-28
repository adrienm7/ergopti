--- tests/unit/llm/test_api_remote_no_token_in_log.lua

--- ==============================================================================
--- MODULE: Regression — the API token must never reach the log file
---         (api-remote-no-token-in-log)
--- DESCRIPTION:
--- Configure a Gemini-format provider and type until one prediction dispatches,
--- then grep the log directory for `key=`: the full request URL is there,
--- including the decrypted API key in cleartext.
---
--- ROOT CAUSE ENCODED: Gemini authenticates by URL rather than by header
--- (`…/models/<model>:generateContent?key=<token>`), so the finished URL IS a
--- credential. One routine debug line logged it verbatim. The default log level
--- is DEBUG, retention is fourteen days, and the log is a file this project
--- actively tells users to consult and attach to support requests — so the key
--- was written on EVERY prediction, into a file designed to be shared.
---
--- That defeats the whole purpose of api_token_crypto, whose invariant is that
--- the cleartext token never lands on disk. The sibling call sites that build
--- the same URL — warmup and the availability check — never logged it, which is
--- why this survived: the leak was one line out of three that construct the
--- same string.
---
--- The assertion is deliberately made on the SINK rather than on the redactor:
--- what matters is that no line reaching a log destination contains the token,
--- regardless of which call site produced it or how it was assembled.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A token that cannot occur by accident, so finding it anywhere in the captured
--- output is unambiguous.
local SENTINEL_TOKEN = "SENTINEL-TOKEN-4f9a2b7c"




-- =========================================================================
-- =========================================================================
-- ======= 1/ No log line carries the token ================================
-- =========================================================================
-- =========================================================================

helpers.describe("api_remote: the API token never reaches the log", function()
	helpers.it("a dispatched Gemini request logs a redacted URL", function()
		package.loaded["modules.llm.api_remote"] = nil
		local api = helpers.load_with_stubs("modules.llm.api_remote", {})
		local logger = require("lib.logger")

		-- Capture EVERY line the logger emits, at every level — the leak was a
		-- debug line, and a capture restricted to errors would miss it entirely.
		local captured = {}
		local restored = false
		if type(logger.set_sink) == "function" then
			logger.set_sink(function(console_line, _variant)
				captured[#captured + 1] = tostring(console_line)
			end)
			restored = true
		end
		helpers.assert_true(restored,
			"the logger must expose set_sink — without it this test observes nothing and would pass vacuously")

		-- Asserted, never skipped. A conditional "only check this if the redactor
		-- exists" passes vacuously on exactly the build that has the bug — which
		-- is how the previous guard in this area came to defend the defect.
		helpers.assert_true(type(api.__redact_url_for_test) == "function",
			"api_remote must redact URLs before logging them — without a redactor the Gemini "
				.. "request URL, which carries the API key, is written to the log verbatim")

		local url = "https://generativelanguage.googleapis.com/v1beta/models/"
			.. "gemini-1.5-flash:generateContent?key=" .. SENTINEL_TOKEN
		logger.debug("test", "POST -> %s", api.__redact_url_for_test(url))

		if type(logger.set_sink) == "function" then
			logger.set_sink(nil)
		end

		local joined = table.concat(captured, "\n")
		helpers.assert_true(
			joined:find(SENTINEL_TOKEN, 1, true) == nil,
			"the API token appeared in a log line. Gemini authenticates by URL, so the finished "
				.. "URL is itself a credential — and the default log level is DEBUG with fourteen-day "
				.. "retention, in a file users are told to attach to support requests. Captured:\n" .. joined
		)
	end)

	helpers.it("redaction keeps the diagnostic part of the URL", function()
		package.loaded["modules.llm.api_remote"] = nil
		local api = helpers.load_with_stubs("modules.llm.api_remote", {})
		helpers.assert_true(type(api.__redact_url_for_test) == "function",
			"api_remote must expose its redactor for testing — the invariant is about what reaches the log, "
				.. "and that cannot be asserted without being able to run the thing that produces it")

		local url = "https://example.test/v1beta/models/gemini-1.5-flash:generateContent?key="
			.. SENTINEL_TOKEN
		local out = api.__redact_url_for_test(url)

		helpers.assert_true(out:find(SENTINEL_TOKEN, 1, true) == nil,
			"the token must be gone. Got: " .. out)
		helpers.assert_true(out:find("gemini-1.5-flash", 1, true) ~= nil,
			"the model must survive redaction — dropping the whole URL would remove the diagnostic "
				.. "this line exists for. Got: " .. out)
		helpers.assert_true(out:find("generateContent", 1, true) ~= nil,
			"the endpoint must survive redaction. Got: " .. out)
		helpers.assert_true(out:find("key=", 1, true) ~= nil,
			"the parameter NAME should remain, so a reader can see that auth was carried by URL. Got: " .. out)
	end)

	helpers.it("every credential-bearing parameter is redacted", function()
		package.loaded["modules.llm.api_remote"] = nil
		local api = helpers.load_with_stubs("modules.llm.api_remote", {})

		-- Gemini uses `key`; other providers and future ones use these spellings.
		-- Covering the family now costs nothing and removes the next instance of
		-- this bug before it is written.
		for _, param in ipairs({ "key", "api_key", "apikey", "access_token", "token" }) do
			local url = "https://example.test/v1?" .. param .. "=" .. SENTINEL_TOKEN
			local out = api.__redact_url_for_test(url)
			helpers.assert_true(out:find(SENTINEL_TOKEN, 1, true) == nil,
				"the '" .. param .. "' parameter must be redacted. Got: " .. out)
		end
	end)

	helpers.it("a parameter after the first is redacted too", function()
		package.loaded["modules.llm.api_remote"] = nil
		local api = helpers.load_with_stubs("modules.llm.api_remote", {})

		local url = "https://example.test/v1?alt=sse&key=" .. SENTINEL_TOKEN .. "&pretty=false"
		local out = api.__redact_url_for_test(url)

		helpers.assert_true(out:find(SENTINEL_TOKEN, 1, true) == nil,
			"a credential that is not the first query parameter must still be redacted. Got: " .. out)
		helpers.assert_true(out:find("alt=sse", 1, true) ~= nil,
			"unrelated parameters must survive — they are the diagnostic. Got: " .. out)
		helpers.assert_true(out:find("pretty=false", 1, true) ~= nil,
			"the redaction must stop at the parameter separator, not swallow the rest of the URL. Got: " .. out)
	end)

	helpers.it("a URL with no credential is unchanged", function()
		package.loaded["modules.llm.api_remote"] = nil
		local api = helpers.load_with_stubs("modules.llm.api_remote", {})

		local url = "https://api.openai.test/v1/chat/completions"
		helpers.assert_eq(api.__redact_url_for_test(url), url,
			"providers that authenticate by header must have their URL logged untouched — "
				.. "over-redacting would remove diagnostics for the common case")
	end)
end)




-- =========================================================================
-- =========================================================================
-- ======= 2/ No call site logs a raw URL ==================================
-- =========================================================================
-- =========================================================================

helpers.describe("api_remote: no site logs an unredacted URL", function()
	helpers.it("every URL passed to the logger goes through the redactor", function()
		-- Selected by a declaration unique to modules/llm/api_remote.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("function M.prewarm_active_entry_decrypt")
		helpers.assert_true(src ~= nil, "modules/llm/api_remote.lua source must be locatable")
		if not src then return end

		-- Any Logger call whose arguments mention a bare `url` variable is a
		-- candidate leak. Three sites build the credential-bearing URL and only
		-- one logged it, so the guard has to cover the shape, not the one line.
		-- Collect the lines once, so a Logger call can be followed across its
		-- continuations. The actual leak passed `url` on the SECOND line of the
		-- call, so a scanner that only inspected lines containing "Logger." saw
		-- the format string and nothing else — it would have reported the file
		-- clean while the credential was written on every prediction.
		local lines = {}
		for line in (src .. "\n"):gmatch("([^\n]*)\n") do
			lines[#lines + 1] = line
		end

		--- Strip string literals, so prose inside a format string ("empty
		--- base_url for provider") is never mistaken for a URL argument. A guard
		--- that cries wolf gets suppressed, which is worse than no guard.
		local function code_of(line)
			return (line:gsub('"[^"]*"', '""'):gsub("'[^']*'", "''"))
		end

		local offenders = {}
		for i, line in ipairs(lines) do
			if line:find("Logger%.") then
				-- Accumulate until the call's parentheses balance.
				local call, depth, j = "", 0, i
				repeat
					local c = code_of(lines[j] or "")
					call = call .. " " .. c
					depth = depth + select(2, c:gsub("%(", "")) - select(2, c:gsub("%)", ""))
					j = j + 1
				until depth <= 0 or j > #lines or j > i + 6

				if call:find("url") and not call:find("redact_url", 1, true) then
					offenders[#offenders + 1] = i .. ": " .. (lines[i]:gsub("^%s+", ""))
				end
			end
		end

		helpers.assert_eq(#offenders, 0,
			"a Logger call passes a URL without redacting it. For Gemini the URL carries the "
				.. "API key, so this writes the credential to a fourteen-day log at DEBUG level:\n  "
				.. table.concat(offenders, "\n  "))
	end)
end)
