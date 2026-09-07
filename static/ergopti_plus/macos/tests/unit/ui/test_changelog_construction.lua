--- tests/unit/ui/test_changelog_construction.lua

--- ==============================================================================
--- MODULE: Changelog Construction Transactions
--- DESCRIPTION:
--- Exercises public construction, rollback, and retry with exact native resources.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_changelog = require("tests.support.changelog_fixture").with_changelog

helpers.describe("changelog construction transactions", function()
	helpers.it("native close releases its exact bridge (changelog-construction)", function()
		with_changelog(function(changelog, state)
			helpers.assert_true(changelog.open())
			local old_bridge = state.bridges[1]
			state.view.options.on_close()
			helpers.assert_eq(state.controllers[1].callback, nil)
			old_bridge({ body = { action = "fetch", channel = "dev" } })
			helpers.assert_eq(#state.callbacks, 0)
			helpers.assert_true(changelog.open())
			helpers.assert_eq(#state.controllers, 2)
		end)
	end)

	helpers.it("cleanup failure diagnostics cannot recursively reopen retained resources (changelog-construction)", function()
		with_changelog(function(changelog, state)
			helpers.assert_true(changelog.open())
			state.delete_throws = true
			local attempts = 0
			package.loaded["infra.logger"].error = function()
				attempts = attempts + 1
				helpers.assert_eq(changelog.open(), false)
			end
			helpers.assert_eq(changelog.close(), false)
			helpers.assert_eq(attempts, 1)
			helpers.assert_eq(state.creates, 1)
			helpers.assert_eq(state.deletes, 1)
			state.delete_throws = false
			helpers.assert_true(changelog.close())
		end)
	end)

	helpers.it("failed rollback retains the candidate until exact deletion commits (changelog-construction)", function()
		with_changelog(function(changelog, state)
			local builder = package.loaded["ui.ui_builder"]
			local factory = builder.show_webview
			builder.show_webview = function(options)
				factory(options)
				error("native setup failure")
			end
			state.delete_throws = true
			helpers.assert_eq(changelog.open(), false)
			helpers.assert_eq(state.deletes, 1)
			helpers.assert_eq(changelog.open(), false)
			helpers.assert_eq(state.creates, 1)
			helpers.assert_eq(#state.controllers, 1)
			state.delete_throws = false
			builder.show_webview = factory
			helpers.assert_true(changelog.open())
			helpers.assert_eq(state.deletes, 3)
			helpers.assert_eq(state.creates, 2)
			helpers.assert_eq(state.controllers[1].callback, nil)
		end)
	end)

	for _, mode in ipairs({ "constructor", "registration", "geometry", "html", "factory entry", "factory allocated" }) do
		helpers.it("rolls back " .. mode .. " failure (changelog-construction)", function()
			with_changelog(function(changelog, state)
				local logger, builder = package.loaded["infra.logger"], package.loaded["ui.ui_builder"]
				local errors, successes, releases = {}, 0, 0
				logger.error = function(_, message, ...) errors[#errors + 1] = string.format(message, ...) end
				logger.success = function() successes = successes + 1 end
				local original_new = hs.webview.usercontent.new
				hs.webview.usercontent.new = function(...)
					if mode == "constructor" then error("private native detail") end
					local controller = original_new(...)
					local setter = controller.setCallback
					controller.setCallback = function(self, callback)
						if callback and mode == "registration" then error("private native detail") end
						if not callback then releases = releases + 1 end
						return setter(self, callback)
					end
					return controller
				end
				local geometry, html, factory = builder.get_app_geometry, builder.build_injected_html, builder.show_webview
				if mode == "geometry" then builder.get_app_geometry = function() return nil end end
				if mode == "html" then builder.build_injected_html = function() error("private native detail") end end
				builder.show_webview = function(options)
					if mode == "factory entry" then error("private native detail") end
					local view = factory(options)
					if mode == "factory allocated" then error("private native detail") end
					return view
				end
				helpers.assert_eq(changelog.open({ channel = "main" }), false)
				helpers.assert_eq(successes, 0)
				helpers.assert_eq(#errors, 1)
				helpers.assert_eq(errors[1]:find("private native detail", 1, true), nil)
				helpers.assert_eq(releases, mode == "constructor" and 0 or 1)
				helpers.assert_eq(state.deletes, mode == "factory allocated" and 1 or 0)
				if state.controllers[1] then helpers.assert_eq(state.controllers[1].callback, nil) end
				helpers.assert_true(changelog.close())
				hs.webview.usercontent.new = original_new
				builder.get_app_geometry, builder.build_injected_html, builder.show_webview = geometry, html, factory
				helpers.assert_true(changelog.open({ channel = "main" }))
				helpers.assert_eq(successes, 1)
			end)
		end)
	end

	helpers.it("retains bridge-only cleanup debt until exact release succeeds (changelog-construction)", function()
		with_changelog(function(changelog, state)
			local builder = package.loaded["ui.ui_builder"]
			local geometry = builder.get_app_geometry
			builder.get_app_geometry = function() return nil end
			local original_new = hs.webview.usercontent.new
			local refuse, releases = true, 0
			hs.webview.usercontent.new = function(...)
				local controller = original_new(...)
				local setter = controller.setCallback
				controller.setCallback = function(self, callback)
					if callback == nil then
						releases = releases + 1
						if refuse then error("native release failure") end
					end
					return setter(self, callback)
				end
				return controller
			end
			helpers.assert_eq(changelog.open(), false)
			helpers.assert_eq(releases, 1)
			local old_bridge = state.bridges[1]
			old_bridge({ body = { action = "fetch", channel = "dev" } })
			helpers.assert_eq(#state.callbacks, 0)
			helpers.assert_eq(changelog.close(), false)
			builder.get_app_geometry = geometry
			helpers.assert_eq(changelog.open(), false)
			helpers.assert_eq(#state.controllers, 1)
			refuse = false
			helpers.assert_true(changelog.open())
			helpers.assert_eq(#state.controllers, 2)
			helpers.assert_eq(state.controllers[1].callback, nil)
		end)
	end)

	for _, operation in ipairs({ "close", "open" }) do
		helpers.it("contains " .. operation .. " reentry during controller allocation (changelog-construction)", function()
			with_changelog(function(changelog, state)
				local original_new = hs.webview.usercontent.new
				local once, nested = true, nil
				hs.webview.usercontent.new = function(...)
					local controller = original_new(...)
					if once then
						once = false
						if operation == "close" then nested = changelog.close() else nested = changelog.open() end
					end
					return controller
				end
				helpers.assert_eq(changelog.open(), operation == "open")
				helpers.assert_eq(nested, false)
				helpers.assert_eq(#state.controllers, 1)
				helpers.assert_eq(state.creates, operation == "open" and 1 or 0)
			end)
		end)
	end
end)
