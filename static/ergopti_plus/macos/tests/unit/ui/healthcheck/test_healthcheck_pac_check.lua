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
		-- issue #104: the transport reason is the only clue a field log carries.
		local _, reason = PacCheck.judge(0, "", "Network request failed: A server with the specified hostname could not be found.")
		helpers.assert_eq(reason, "PAC download failed: Network request failed: A server with the specified hostname could not be found.")
		local _, big = PacCheck.judge(200, string.rep("a", PacCheck.MAX_BYTES + 1))
		helpers.assert_true(big:find("limit", 1, true) ~= nil)
	end)

	helpers.it("strictly decodes UTF-16 in either byte order before judging the PAC", function()
		local script = "function FindProxyForURL(){return 'DIRECT';}"
		local le, be = {}, {}
		for index = 1, #script do
			local byte = script:sub(index, index)
			le[#le + 1], be[#be + 1] = byte .. "\0", "\0" .. byte
		end
		-- Accents, a surrogate pair and a literal replacement scalar are valid.
		local good_le = "\255\254" .. table.concat(le) .. "/\0/\0\233\0\61\216\0\222\253\255"
		local good_be = "\254\255" .. table.concat(be) .. "\0/\0/\0\233\216\61\222\0\255\253"
		helpers.assert_eq((PacCheck.judge(200, good_le)), "ok")
		helpers.assert_eq((PacCheck.judge(200, good_be)), "ok")
		for _, bytes in ipairs({
			"\255\254", "\254\255", "\255\254A", "\254\255\0",
			"\255\254\0\216", "\254\255\220\0", "\255\254A\0", "\254\255\0A",
			good_le .. "\0\0", good_be .. "\0\0", script .. "\0",
		}) do
			helpers.assert_eq((PacCheck.judge(200, bytes)), "error")
		end
		local expanded = good_le .. string.rep("\0\8", 400000)
		helpers.assert_true(#expanded < PacCheck.MAX_BYTES)
		helpers.assert_eq((PacCheck.judge(200, expanded)), "error")
	end)

	helpers.it("tells that the downloads go direct after a PAC failure", function()
		local _, failed = PacCheck.judge(0, "", "timed out")
		helpers.assert_eq(PacCheck.with_direct_fallback(failed),
			"PAC download failed: timed out; downloads then try a direct connection")
		helpers.assert_true(helpers.read_driver_source("detail = PacCheck.with_direct_fallback(text)") ~= nil,
			"the macOS proxy_pac probe names the direct fallback")
	end)

	helpers.it("reads the PAC URL only when the system PAC is enabled", function()
		local on = "<dictionary> {\n  ProxyAutoConfigEnable : 1\n  ProxyAutoConfigURLString : http://pac.example.invalid/a.pac\n}"
		helpers.assert_eq(PacCheck.url_from_scutil(on), "http://pac.example.invalid/a.pac")
		helpers.assert_nil(PacCheck.url_from_scutil((on:gsub("Enable : 1", "Enable : 0"))))
		helpers.assert_nil(PacCheck.url_from_scutil(nil))
	end)
end)
