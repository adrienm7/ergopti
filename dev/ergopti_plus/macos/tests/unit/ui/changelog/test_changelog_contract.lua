--- tests/unit/ui/changelog/test_changelog_contract.lua

--- ==============================================================================
--- MODULE: Changelog Native Table Bridge Contract
--- DESCRIPTION:
--- Exercises native table messages only after a real controller commits its view.
--- Retains the real HTTP URL allowlist and native HTTP dispatch boundaries.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_changelog = require("tests.support.changelog_fixture").with_changelog

helpers.describe("Changelog Bridge Contract", function()
	helpers.it("opens a repository release link posted as a native table (F-MED-14)", function()
		with_changelog(function(changelog, state, post)
			hs.json.decode = function() error("native bridge tables must not be JSON decoded") end
			helpers.assert_true(changelog.open())
			helpers.assert_eq(state.creates, 1)
			local url = "https://github.com/adrienm7/ergopti/releases/tag/v1.0.0"
			post({ action = "open_url", url = url })
			helpers.assert_eq(state.urls[#state.urls], url)
		end)
	end)

	helpers.it("refuses and logs every link outside this repository (versions-url-allowlist-macos)", function()
		with_changelog(function(changelog, state, post)
			helpers.assert_true(changelog.open())
			local logged = {}
			local Logger = package.loaded["infra.logger"]
			local original_warn = Logger.warn
			Logger.warn = function(_, fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end
			for _, refused in ipairs({
				"shortcuts://run-shortcut?name=fixture",
				"file:///tmp/fixture",
				"javascript:alert(1)",
				"https:///missing-host",
				"https://safe.example/path\nshortcuts://run-shortcut",
				"https://example.test/releases",
				"HtTpS://github.com/adrienm7/ergopti/releases",
				"http://github.com/adrienm7/ergopti/releases",
				"https://github.com/adrienm7/ergopti-evil/releases",
				"https://github.com/someone-else/ergopti/releases",
				"https://github.com.evil.test/adrienm7/ergopti",
			}) do
				local before = #state.urls
				post({ action = "open_url", url = refused })
				helpers.assert_eq(#state.urls, before, "not opened: " .. refused)
			end
			post({ action = "open_url" })
			post({ action = "open_url", url = 42 })
			Logger.warn = original_warn
			helpers.assert_eq(#state.urls, 0, "nothing outside the repository reaches the system handler")
			helpers.assert_eq(#logged, 13, "each refusal is logged")
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
