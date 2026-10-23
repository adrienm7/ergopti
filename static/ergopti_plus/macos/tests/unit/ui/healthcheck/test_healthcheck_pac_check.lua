--- tests/unit/ui/healthcheck/test_healthcheck_pac_check.lua

--- ==============================================================================
--- MODULE: Healthcheck PAC check
--- DESCRIPTION:
--- The diagnostics judge a company PAC like the managed downloader does, so a
--- failing step is named (issue #101): status, size, strict UTF-8, the
--- FindProxyForURL function, and no URL in any answer.
--- ==============================================================================

local helpers = require("tests.helpers")
local PacCheck = require("network.pac_check")

helpers.describe("PAC check", function()
	helpers.it("accepts an ASCII PAC that defines FindProxyForURL", function()
		local state, text = PacCheck.judge(200, "function FindProxyForURL(url, host) { return 'DIRECT'; }")
		helpers.assert_eq(state, "ok")
		helpers.assert_true(text:find("HTTP 200", 1, true) ~= nil and text:find("UTF-8", 1, true) ~= nil)
	end)

	helpers.it("accepts UTF-8 accents and a byte-order mark", function()
		local state = PacCheck.judge(200, "\239\187\191// r\195\169seau\nfunction FindProxyForURL() {}")
		helpers.assert_eq(state, "ok")
	end)

	helpers.it("refuses a Windows-1252 accent like the managed download", function()
		local state, text = PacCheck.judge(200, "// r\233seau\nfunction FindProxyForURL() {}")
		helpers.assert_eq(state, "error")
		helpers.assert_true(text:find("not UTF-8", 1, true) ~= nil)
	end)

	helpers.it("refuses overlong forms and surrogates", function()
		helpers.assert_eq((PacCheck.judge(200, "\192\128 FindProxyForURL")), "error")
		helpers.assert_eq((PacCheck.judge(200, "\237\160\128 FindProxyForURL")), "error")
	end)

	helpers.it("names a missing function, an empty body, a bad status and an oversized script", function()
		local _, missing = PacCheck.judge(200, "var x = 1;")
		helpers.assert_true(missing:find("FindProxyForURL", 1, true) ~= nil)
		helpers.assert_eq((PacCheck.judge(200, "")), "error")
		local _, status = PacCheck.judge(407, "x")
		helpers.assert_eq(status, "PAC download: HTTP 407")
		local _, failed = PacCheck.judge(nil, nil)
		helpers.assert_eq(failed, "PAC download failed")
		local _, big = PacCheck.judge(200, string.rep("a", PacCheck.MAX_BYTES + 1))
		helpers.assert_true(big:find("limit", 1, true) ~= nil)
	end)

	helpers.it("reads the PAC URL only when the system PAC is enabled", function()
		local on = "<dictionary> {\n  ProxyAutoConfigEnable : 1\n  ProxyAutoConfigURLString : http://pac.example.invalid/a.pac\n}"
		helpers.assert_eq(PacCheck.url_from_scutil(on), "http://pac.example.invalid/a.pac")
		helpers.assert_nil(PacCheck.url_from_scutil((on:gsub("Enable : 1", "Enable : 0"))))
		helpers.assert_nil(PacCheck.url_from_scutil(nil))
	end)
end)
