--- tests/unit/ui/test_changelog_fetch_generation.lua

--- ==============================================================================
--- MODULE: Changelog fetch generation regression
--- DESCRIPTION:
--- Channel switches start independent HTTP requests. Only the newest request may
--- publish into the singleton webview, even when an older response arrives last.
--- ==============================================================================

local helpers = require("tests.helpers")

local with_changelog = require("tests.support.changelog_fixture").with_changelog

helpers.describe("changelog delayed navigation ownership", function()
	for _, boundary in ipairs({ "before navigation", "after navigation", "delete refused" }) do
		helpers.it("rejects retired work " .. boundary .. " (changelog-navigation-owner)", function()
			with_changelog(function(changelog, state, post)
				helpers.assert_true(changelog.open({ channel = "dev" }))
				local old_view, fallback = state.view, state.timers[1].callback
				if boundary ~= "before navigation" then old_view.options.on_navigation("didFinishNavigation") end
				local navigation = state.timers[2] and state.timers[2].callback
				state.delete_throws = boundary == "delete refused"
				helpers.assert_eq(changelog.close(), not state.delete_throws)
				if not state.delete_throws then helpers.assert_true(changelog.open({ channel = "main" })) end
				local timers_before = #state.timers
				old_view.options.on_navigation("didFinishNavigation")
				helpers.assert_eq(#state.timers, timers_before, "retired navigation must not even schedule work")
				if navigation then navigation() end
				helpers.assert_eq(#state.callbacks, 0, "retired navigation must not start a request")
				post({ action = "fetch", channel = "main" })
				if not state.delete_throws then state.callbacks[1](200, state.main_body, {})
				else helpers.assert_eq(#state.callbacks, 0, "cleanup-only sessions cannot request data") end
				helpers.assert_eq(#state.evaluations, 0)
				fallback()
				helpers.assert_eq(#state.evaluations, 0, "retired fallback must not mark a different session ready")
			end)
		end)
	end

	for _, boundary in ipairs({ "before navigation", "after navigation" }) do
		helpers.it("preserves a newer singleton channel " .. boundary .. " (changelog-navigation-owner)", function()
			with_changelog(function(changelog, state)
				helpers.assert_true(changelog.open({ channel = "dev" }))
				if boundary == "after navigation" then state.view.options.on_navigation("didFinishNavigation") end
				helpers.assert_true(changelog.open({ channel = "main" }))
				if boundary == "before navigation" then state.view.options.on_navigation("didFinishNavigation") end
				helpers.assert_eq(#state.callbacks, 1)
				state.callbacks[1](200, state.main_body, {})
				helpers.assert_eq(#state.evaluations, 0)
				state.timers[2].callback()
				helpers.assert_eq(#state.callbacks, 1, "initial navigation must not overwrite a newer channel request")
				helpers.assert_eq(#state.evaluations, 1, "current navigation still flushes the newer queued response")
				helpers.assert_true(state.evaluations[1]:find('"main"', 1, true) ~= nil)
			end)
		end)
	end

	helpers.it("allows current initial navigation to fetch once (changelog-navigation-owner)", function()
		with_changelog(function(changelog, state)
			helpers.assert_true(changelog.open({ channel = "dev" }))
			state.view.options.on_navigation("didFinishNavigation")
			state.timers[2].callback()
			helpers.assert_eq(#state.callbacks, 1)
			state.callbacks[1](200, state.dev_body, {})
			helpers.assert_eq(#state.evaluations, 1)
			helpers.assert_true(state.evaluations[1]:find('"dev"', 1, true) ~= nil)
			state.timers[2].callback()
			helpers.assert_eq(#state.callbacks, 1)
		end)
	end)

	helpers.it("does not fetch after queue publication replaces its owner (changelog-navigation-owner)", function()
		with_changelog(function(changelog, state, post)
			helpers.assert_true(changelog.open({ channel = "dev" }))
			state.view.options.on_navigation("didFinishNavigation")
			local navigation = state.timers[2].callback
			post({ action = "fetch", channel = "dev" })
			state.callbacks[1](200, state.dev_body, {})
			state.on_evaluate = function()
				state.on_evaluate = nil
				changelog.close()
				changelog.open({ channel = "main" })
			end
			navigation()
			helpers.assert_eq(state.creates, 2)
			helpers.assert_eq(#state.callbacks, 1)
		end)
	end)
end)

helpers.describe("changelog: only the newest channel request may publish", function()
	for _, refused in ipairs({ false, true }) do
		helpers.it("(webview-focus-owner) changelog retirement revokes focus, delete refused=" .. tostring(refused), function()
			with_changelog(function(changelog, state)
				helpers.assert_true(changelog.open({ channel = "dev" }))
				require("tests.support.webview_focus_fixture").check(state.view,
					function() return changelog.open({ channel = "dev" }) end,
					function() state.delete_throws = refused; helpers.assert_eq(changelog.close(), not refused) end,
					state.view.options)
			end)
		end)
	end

	helpers.it("drops a slow Dev response after a newer Stable response", function()
		with_changelog(function(changelog, state, post_message)
			changelog.open({channel = "dev"})
			post_message("ready")
			post_message({action = "fetch", channel = "dev"})
			post_message({action = "fetch", channel = "main"})
			helpers.assert_eq(#state.callbacks, 2,
				"both user requests must reach the asynchronous HTTP boundary")

			state.callbacks[2](200, state.main_body, {})
			state.callbacks[1](200, state.dev_body, {})

			helpers.assert_eq(#state.evaluations, 1,
				"the stale response must not publish after the newest response")
			helpers.assert_true(
				state.evaluations[1]:find("main-release", 1, true) ~= nil,
				"the newest Stable payload must win")
			helpers.assert_true(
				state.evaluations[1]:find('"main"', 1, true) ~= nil,
				"the winning payload must retain the requested channel")
		end)
	end)

	helpers.it("drops a response owned by a closed window session", function()
		with_changelog(function(changelog, state, post_message)
			changelog.open({channel = "dev"})
			post_message("ready")
			post_message({action = "fetch", channel = "dev"})
			helpers.assert_eq(#state.callbacks, 1)

			changelog.close()
			changelog.open({channel = "main"})
			post_message("ready")
			state.callbacks[1](200, state.dev_body, {})

			helpers.assert_eq(#state.evaluations, 0,
				"a closed window's response must not publish into its successor")
		end)
	end)

	helpers.it("does not publish a changelog closed synchronously during construction", function()
		with_changelog(function(changelog, state)
			state.close_during_show = true
			helpers.assert_eq(changelog.open({channel = "dev"}), false,
				"a synchronously closed construction candidate must not report success")
			helpers.assert_eq(state.creates, 1)
			helpers.assert_eq(changelog.open({channel = "main"}), true,
				"the closed candidate must not block a fresh changelog")
			helpers.assert_eq(state.creates, 2,
				"the retry must construct a new native changelog instead of reusing a ghost")
		end)
	end)

	helpers.it("retains a changelog whose native delete raises", function()
		with_changelog(function(changelog, state)
			changelog.open({channel = "dev"})
			state.delete_throws = true

			helpers.assert_eq(changelog.close(), false,
				"a throwing native delete must refuse the logical close")
			helpers.assert_eq(changelog.open({channel = "main"}), false)
			helpers.assert_eq(state.creates, 1,
				"a refused close must not permit a second native changelog")
			helpers.assert_eq(state.focuses, 0,
				"the retained native changelog owns cleanup, not live focus")
			helpers.assert_eq(state.deletes, 2, "open must retry exact native cleanup")

			state.delete_throws = false
			helpers.assert_true(changelog.close(),
				"the exact retained changelog must remain retryable")
			changelog.open({channel = "main"})
			helpers.assert_eq(state.creates, 2,
				"a successor may be created only after exact native deletion")
		end)
	end)
end)
