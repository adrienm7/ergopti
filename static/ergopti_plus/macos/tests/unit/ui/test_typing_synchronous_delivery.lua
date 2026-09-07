--- tests/unit/ui/test_typing_synchronous_delivery.lua

--- ==============================================================================
--- MODULE: Typing Synchronous Delivery Tests
--- DESCRIPTION:
--- Refuses known execution failure even when native submission returned its view.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_delivery = require("tests.support.typing_delivery_fixture")

helpers.describe("typing synchronous JavaScript delivery", function()
	helpers.it("(typing-sync-delivery) reopen returns false for execution failure before admission", function()
		with_delivery(function(dashboard, context, _, errors)
			context.webview.evaluateJavaScript = function(self, _, done)
				done(nil, { localizedDescription = "PRIVATE_DETAIL" })
				return self
			end
			helpers.assert_eq(dashboard.show(), false)
			helpers.assert_eq(#errors, 1)
			helpers.assert_nil(errors[1]:find("PRIVATE_DETAIL", 1, true))
		end)
	end)
end)
