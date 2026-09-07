--- tests/unit/ui/test_changelog_bridge_retirement.lua

--- ==============================================================================
--- MODULE: Changelog Bridge Retirement
--- DESCRIPTION:
--- Revoked native controllers and failed deletions retain no publication authority.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_changelog = require("tests.support.changelog_fixture").with_changelog

helpers.describe("changelog bridge retirement", function()
	for _, replacement in ipairs({ false, true }) do
		helpers.it("rejects old bridge messages, successor=" .. tostring(replacement) .. " (changelog-bridge-owner)", function()
			with_changelog(function(changelog, state, post)
				helpers.assert_true(changelog.open({ channel = "dev" }))
				local old_bridge = state.bridges[1]
				local old_controller = state.view.options.usercontent
				helpers.assert_true(changelog.close())
				if replacement then helpers.assert_true(changelog.open({ channel = "main" })) end
				old_bridge({ body = { action = "fetch", channel = "dev" } })
				old_bridge({ body = { action = "open_url", url = "https://example.test/releases" } })
				helpers.assert_eq(#state.callbacks, 0)
				helpers.assert_eq(#state.urls, 0)
				if replacement then
					helpers.assert_true(state.view.options.usercontent ~= old_controller,
						"queued native messages must not be rebound to a successor controller")
					post({ action = "fetch", channel = "main" })
					state.callbacks[1](200, "main-body", {})
					old_bridge({ body = "ready" })
					helpers.assert_eq(#state.evaluations, 0)
					post("ready")
					helpers.assert_eq(#state.evaluations, 1)
					helpers.assert_true(state.evaluations[1]:find('"main"', 1, true) ~= nil)
				end
			end)
		end)
	end

	helpers.it("failed deletion retires replies and messages but preserves exact cleanup (changelog-bridge-owner)", function()
		with_changelog(function(changelog, state, post)
			helpers.assert_true(changelog.open({ channel = "dev" }))
			post("ready")
			post({ action = "fetch", channel = "dev" })
			local old_bridge = state.bridges[1]
			state.delete_throws = true
			helpers.assert_eq(changelog.close(), false)
			state.callbacks[1](200, "dev-body", {})
			helpers.assert_eq(#state.evaluations, 0)
			old_bridge({ body = { action = "fetch", channel = "dev" } })
			helpers.assert_eq(#state.callbacks, 1)
			helpers.assert_eq(changelog.open({ channel = "main" }), false)
			helpers.assert_eq(state.creates, 1)
			helpers.assert_eq(state.focuses, 0)
			helpers.assert_eq(state.deletes, 2, "reopening must retry the exact retained deletion")
			state.delete_throws = false
			helpers.assert_true(changelog.open({ channel = "main" }))
			helpers.assert_eq(state.deletes, 3)
			helpers.assert_eq(state.creates, 2)
			post("ready")
			post({ action = "fetch", channel = "main" })
			state.callbacks[2](200, "main-body", {})
			helpers.assert_eq(#state.evaluations, 1)
		end)
	end)

	helpers.it("fetch logging cannot dispatch after its window retires (changelog-bridge-owner)", function()
		with_changelog(function(changelog, state, post)
			helpers.assert_true(changelog.open({ channel = "dev" }))
			package.loaded["infra.logger"].trace = function() changelog.close() end
			post({ action = "fetch", channel = "dev" })
			helpers.assert_eq(#state.callbacks, 0)
			helpers.assert_eq(state.deletes, 1)
		end)
	end)
end)
