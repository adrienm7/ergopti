--- tests/unit/modules/keystats/context_tracker/test_context_tracker_unanswered_window.lua

--- ==============================================================================
--- REGRESSION: an application that waits out the Accessibility timeout
--- DESCRIPTION:
--- Right after a wake, loginwindow answers no Accessibility read, and each read
--- holds the main thread for the 0.5 s messaging timeout. The post-wake context
--- capture read its focused window, title and full-screen state in a row and
--- held the main thread 1512 ms (field run 2026-10-31 09:53:15). A focused-window
--- read that waits the timeout out now skips the other reads, and the
--- application is not asked again during its cooldown
--- (context-unanswered-window).
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("context tracker with an unanswering application (context-unanswered-window)", function()
	helpers.it("skips the window details after a read that waited out the timeout", function()
		helpers.with_stub_scope({ "modules.keystats.context_tracker", "adapters.accessibility_permission",
			"infra.i18n" }, function()
			package.loaded["adapters.accessibility_permission"] = nil
			local clock_ns = 0
			local reads = { window = 0, title = 0, fullscreen = 0 }
			local tracker = helpers.load_with_stubs("modules.keystats.context_tracker", {
				window = { focusedWindow = function()
					reads.window = reads.window + 1
					-- The read returns only once the 0.5 s messaging timeout expired
					clock_ns = clock_ns + 500 * 1e6
					return {
						isFullScreen = function() reads.fullscreen = reads.fullscreen + 1; return false end,
						title = function() reads.title = reads.title + 1; return "Login" end,
					}
				end },
				timer = {
					absoluteTime = function() return clock_ns end,
					secondsSinceEpoch = function() return clock_ns / 1e9 end,
				},
				application = { frontmostApplication = function()
					return { pid = function() return 391 end }
				end },
				axuielement = { windowElement = function() return nil end },
			})
			local state = {}
			tracker.init(state, {}, function() return false end)

			tracker.update_private_status()
			helpers.assert_eq(reads.window, 1)
			helpers.assert_eq(reads.title, 0, "the title read would wait out the timeout too")
			helpers.assert_eq(reads.fullscreen, 0)
			helpers.assert_eq(state.is_private_window, false)

			tracker.update_private_status()
			helpers.assert_eq(reads.window, 1, "the unanswering application is not asked during its cooldown")
		end)
	end)
end)
