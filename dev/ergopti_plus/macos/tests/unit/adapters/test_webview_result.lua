--- tests/unit/adapters/test_webview_result.lua

--- Keeps the native nil-error sentinel distinct from real and malformed errors.
local helpers = require("tests.helpers")
local Result = require("adapters.webview_result")

helpers.describe("native WebView error result", function()
	helpers.it("accepts only an absent error or the exact nil-NSError representation", function()
		helpers.assert_eq(Result.is_error(nil), false)
		helpers.assert_eq(Result.is_error({ code = 0 }), false)
		for _, value in ipairs({ {}, false, true, 0, "", { code = "0" }, { code = false }, { code = 1 },
			{ code = 0, domain = "WKErrorDomain" }, { code = 0, localizedDescription = "" },
			setmetatable({ code = 0 }, { __pairs = function() return next, { code = 0 }, nil end }) }) do
			helpers.assert_eq(Result.is_error(value), true)
		end
	end)
end)
