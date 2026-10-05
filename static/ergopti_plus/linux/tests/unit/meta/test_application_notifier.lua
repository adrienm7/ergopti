--- tests/unit/meta/test_application_notifier.lua

--- ==============================================================================
--- MODULE: Application Notification Captions
--- DESCRIPTION:
--- Records the actual native adapter boundary while preserving generic port
--- behavior. Shared application captions own branding before native decoration.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =======================================
-- =======================================
-- ======= 1/ Application Captions =======
-- =======================================
-- =======================================

helpers.describe("application notification captions", function()
	helpers.it("composes application labels without changing the generic port (application-caption-policy)", function()
		local Paths = require("infra.paths")
		local fixture = assert(loadfile(Paths.shared("tests/fixtures/application_notification_titles.lua")))()
		fixture.run(helpers.assert_eq, "linux", require("window_titles").compose, {
			default = "ErgoptiPlus", named = "ErgoptiPlus — Bare label", decorated = "ErgoptiPlus — ⚠ Bare label",
		})
	end)
end)
