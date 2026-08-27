--- tests/unit/ui/test_changelog_fetch_generation.lua

--- ==============================================================================
--- MODULE: Changelog fetch generation regression
--- DESCRIPTION:
--- Channel switches start independent HTTP requests. Only the newest request may
--- publish into the singleton webview, even when an older response arrives last.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_changelog(callback)
	local previous_hs = rawget(_G, "hs")
	local ok, err = xpcall(function()
		helpers.with_fresh_modules({
			"ui.changelog",
			"ui.ui_builder",
			"infra.deferred_work",
			"infra.i18n",
			"infra.logger",
			"infra.paths",
			"hs",
			"tests.stubs.hs",
		}, function()
			local state = {
				callbacks = {},
				evaluations = {},
			}
			local hs_stub = require("tests.stubs.hs")
			hs_stub.__reset()
			hs_stub.http.asyncGet = function(_url, _headers, on_response)
				state.callbacks[#state.callbacks + 1] = on_response
			end
			hs_stub.json.decode = function(body)
				if body == "dev-body" then
					return {{tag_name = "dev-release", prerelease = true}}
				end
				if body == "main-body" then
					return {{tag_name = "main-release", prerelease = false}}
				end
				return nil
			end
			hs_stub.json.encode = function(releases)
				local first = releases[1]
				return first and ('[{"tag_name":"' .. first.tag_name .. '"}]') or "[]"
			end
			_G.hs = hs_stub
			package.loaded["hs"] = hs_stub

			local bridge_callback
			hs_stub.webview.usercontent.new = function()
				local bridge = {}
				function bridge:setCallback(fn)
					bridge_callback = fn
					return true
				end
				return bridge
			end
			package.loaded["infra.deferred_work"] = {
				after = function() return true end,
			}
			package.loaded["infra.i18n"] = {
				get = function(key) return key end,
			}
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.paths"] = {
				shared = function(relative) return "/shared/" .. tostring(relative) end,
			}
			package.loaded["ui.ui_builder"] = {
				build_injected_html = function() return "<html><head></head></html>" end,
				force_focus = function() return true end,
				get_app_geometry = function() return {width = 800, height = 600} end,
				get_centered_frame = function(width, height)
					return {x = 0, y = 0, w = width, h = height}
				end,
				show_webview = function(options)
					local view = {options = options}
					function view:evaluateJavaScript(script)
						state.evaluations[#state.evaluations + 1] = script
						return true
					end
					function view:delete() return true end
					state.view = view
					return view
				end,
				open_http_url = function() return true end,
			}

			local changelog = require("ui.changelog")
			callback(changelog, state, function(message)
				helpers.assert_type(bridge_callback, "function",
					"the real changelog bridge must be registered")
				bridge_callback({body = message})
			end)
		end)
	end, debug.traceback)
	_G.hs = previous_hs
	if not ok then error(err, 0) end
end

helpers.describe("changelog: only the newest channel request may publish", function()
	helpers.it("drops a slow Dev response after a newer Stable response", function()
		with_changelog(function(changelog, state, post_message)
			changelog.open({channel = "dev"})
			post_message("ready")
			post_message({action = "fetch", channel = "dev"})
			post_message({action = "fetch", channel = "main"})
			helpers.assert_eq(#state.callbacks, 2,
				"both user requests must reach the asynchronous HTTP boundary")

			state.callbacks[2](200, "main-body", {})
			state.callbacks[1](200, "dev-body", {})

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
			state.callbacks[1](200, "dev-body", {})

			helpers.assert_eq(#state.evaluations, 0,
				"a closed window's response must not publish into its successor")
		end)
	end)
end)
