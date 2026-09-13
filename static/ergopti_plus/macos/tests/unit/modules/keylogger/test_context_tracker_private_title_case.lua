--- tests/unit/modules/keylogger/test_context_tracker_private_title_case.lua

--- ==============================================================================
--- REGRESSION: Private window title casing
--- DESCRIPTION:
--- Exercises the real context tracker so a stubbed privacy flag cannot hide a
--- mismatch with the shared case-insensitive private-window contract.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_tracker(callback)
	helpers.with_stub_scope({ "modules.keylogger.context_tracker", "infra.i18n" }, function()
		local title = "Private Browsing"
		local tracker = helpers.load_with_stubs("modules.keylogger.context_tracker", {
			window = { focusedWindow = function()
				return {
					isFullScreen = function() return false end,
					title = function() return title end,
				}
			end },
			timer = { absoluteTime = function() return 0 end },
			axuielement = { windowElement = function() return nil end },
		})
		local state = {}
		tracker.init(state, {}, function() return false end)
		callback(function(next_title)
			title = next_title
			tracker.update_private_status()
			return state.is_private_window
		end, require("infra.i18n"))
	end)
end

helpers.describe("context tracker private title casing", function()

	helpers.it("recognizes case variants and clears the flag for public windows", function()
		with_tracker(function(observe)
			for _, marker in ipairs({ "Private Browsing", "PRIVATE BROWSING", "private browsing", "INCOGNITO", "inprivate" }) do
				helpers.assert_true(observe("Example - " .. marker), "Private title must be recognized: " .. marker)
				helpers.assert_eq(observe("Public document"), false, "Public title must clear the previous private flag")
			end
		end)
	end)

	helpers.it("uses the current localized marker without retaining previous languages", function()
		with_tracker(function(observe, i18n)
			local localized = "Confidential Mode"
			i18n.get = function() return localized end
			helpers.assert_true(observe("CONFIDENTIAL MODE"))
			localized = "Hidden Session"
			helpers.assert_eq(observe("Confidential Mode"), false)
			helpers.assert_true(observe("HIDDEN SESSION"))
			localized = "keylogger.category_private"
			helpers.assert_eq(observe("Hidden Session"), false)
			helpers.assert_eq(observe("keylogger.category_private"), false)
			helpers.assert_true(observe("INCOGNITO"))
		end)
	end)

end)
