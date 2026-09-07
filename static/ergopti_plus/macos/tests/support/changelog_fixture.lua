--- tests/support/changelog_fixture.lua

--- ==============================================================================
--- MODULE: Changelog Controller Test Fixture
--- DESCRIPTION:
--- Isolates real controller callbacks with observable native and HTTP boundaries.
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
				bridges = {},
				urls = {},
				timers = {},
				creates = 0,
				delete_throws = false,
				deletes = 0,
				evaluations = {},
				focuses = 0,
				close_during_show = false,
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
					state.bridges[#state.bridges + 1] = fn
					return true
				end
				return bridge
			end
			package.loaded["infra.deferred_work"] = {
				after = function(_, callback, label)
					state.timers[#state.timers + 1] = { callback = callback, label = label }
					return true
				end,
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
				force_focus = function()
					state.focuses = state.focuses + 1
					return true
				end,
				get_app_geometry = function() return {width = 800, height = 600} end,
				get_centered_frame = function(width, height)
					return {x = 0, y = 0, w = width, h = height}
				end,
				show_webview = function(options)
					state.creates = state.creates + 1
					local view = {options = options}
					function view:evaluateJavaScript(script)
						state.evaluations[#state.evaluations + 1] = script
						if state.on_evaluate then state.on_evaluate() end
						return true
					end
					function view:delete()
						state.deletes = state.deletes + 1
						if state.delete_throws then error("synthetic changelog delete refusal") end
						return self
					end
					state.view = view
					if type(options.on_webview_created) == "function"
						and options.on_webview_created(view) ~= true then return nil end
					if state.close_during_show then
						state.close_during_show = false
						options.on_close()
					end
					return view
				end,
				open_http_url = function(url)
					state.urls[#state.urls + 1] = url
					return true
				end,
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

return { with_changelog = with_changelog }
