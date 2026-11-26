--- tests/unit/platform/input/keyboard/test_secure_role_unanswered_cooldown.lua

--- ==============================================================================
--- MODULE: Secure-field classification of an application that does not answer
--- DESCRIPTION:
--- Field run 2026-11-03, after a wake: loginwindow left the AXRole and
--- AXSubrole reads unanswered (1045 ms), and the post-wake focused-window read
--- of the same application then held the main thread another 1005 ms, because
--- nothing had put it in the unanswered cooldown the later readers consult.
--- ==============================================================================

local helpers = require("tests.helpers")

local LOGINWINDOW_PID = 449

--- Classifies one field whose reads answer `answer`.
--- @param refusal string|nil Error both reads return with a nil value.
--- @return boolean secure Classification result.
--- @return boolean askable Whether later readers may still ask the application.
local function classify(refusal)
	return helpers.with_stub_scope({ "platform.focus.secure_field_detector", "adapters.accessibility_permission",
		"core.logger.engine.logger", "hs", "tests.stubs.hs" }, function()
		package.loaded["adapters.accessibility_permission"] = nil
		local field = {
			attributeValue = function(_, attribute)
				if refusal then return nil, refusal end
				return attribute == "AXRole" and "AXTextField" or nil
			end,
			pid = function() return LOGINWINDOW_PID end,
		}
		local detector = helpers.load_with_stubs("platform.focus.secure_field_detector", {
			processInfo = { processID = 1 },
		})
		local permission = require("adapters.accessibility_permission")
		permission.reset_unanswered_for_tests()
		local secure = detector.isElementSecure(field)
		return secure, permission.is_askable(LOGINWINDOW_PID)
	end)
end

helpers.describe("secure-field classification of an unanswering application", function()
	helpers.it("puts an application that left the reads unanswered in the cooldown", function()
		local secure, askable = classify("Messaging failed")
		helpers.assert_eq(secure, true, "an incomplete classification still fails closed")
		helpers.assert_eq(askable, false, "the next readers must skip loginwindow")
	end)

	helpers.it("keeps asking an application that refused for another reason", function()
		local secure, askable = classify("Illegal argument")
		helpers.assert_eq(secure, true)
		helpers.assert_eq(askable, true, "only an unanswered read starts the cooldown")
	end)

	helpers.it("keeps asking an application that answered", function()
		local secure, askable = classify(nil)
		helpers.assert_eq(secure, false)
		helpers.assert_eq(askable, true)
	end)
end)
