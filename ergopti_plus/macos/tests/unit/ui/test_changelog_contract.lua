--- tests/unit/ui/test_changelog_contract.lua

--- ==============================================================================
--- MODULE: Changelog Native Table Bridge Contract
--- DESCRIPTION:
--- Exercises native table messages only after a real controller commits its view.
--- Retains the real HTTP URL allowlist and native HTTP dispatch boundaries.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_changelog = require("tests.support.changelog_fixture").with_changelog

helpers.describe("Changelog Bridge Contract", function()
	helpers.it("correctly handles open_url messages posted as a native table (F-MED-14)", function()
		with_changelog(function(changelog, state, post)
			local builder = package.loaded["ui.ui_builder"]
			package.loaded["ui.ui_builder"] = nil
			builder.open_http_url = require("ui.ui_builder").open_http_url
			package.loaded["ui.ui_builder"] = builder
			local opened_url
			hs.urlevent.openURL = function(url) opened_url = url return true end
			hs.json.decode = function() error("native bridge tables must not be JSON decoded") end
			helpers.assert_true(changelog.open())
			helpers.assert_eq(state.creates, 1)
			local url = "https://github.com/adrienm7/ergopti/releases/tag/v1.0.0"
			post({ action = "open_url", url = url })
			helpers.assert_eq(opened_url, url)
			for _, blocked_url in ipairs({
				"shortcuts://run-shortcut?name=fixture",
				"file:///tmp/fixture",
				"javascript:alert(1)",
				"https:///missing-host",
				"https://safe.example/path\nshortcuts://run-shortcut",
			}) do
				opened_url = nil
				post({ action = "open_url", url = blocked_url })
				helpers.assert_nil(opened_url, "the real allowlist must reject malformed and non-HTTP URLs")
			end
			local mixed = "HtTpS://example.test/releases"
			post({ action = "open_url", url = mixed })
			helpers.assert_eq(opened_url, mixed)
		end)
	end)

	helpers.it("correctly handles fetch messages posted as a native table (F-MED-14)", function()
		with_changelog(function(changelog, state, post)
			hs.json.decode = function() error("native bridge tables must not be JSON decoded") end
			helpers.assert_true(changelog.open())
			post({ action = "fetch", channel = "dev" })
			helpers.assert_eq(#state.callbacks, 1)
			helpers.assert_type(state.callbacks[1], "function")
		end)
	end)
end)
