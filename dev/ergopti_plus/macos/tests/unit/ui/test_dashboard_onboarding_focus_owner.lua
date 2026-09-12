--- tests/unit/ui/test_dashboard_onboarding_focus_owner.lua

--- ==============================================================================
--- MODULE: Dashboard and Onboarding Deferred Focus Ownership
--- DESCRIPTION:
--- Exercises real open and close paths while a native focus retry remains pending.
--- ==============================================================================

local helpers = require("tests.helpers")

local with_window = require("tests.support.dashboard_window_fixture")
helpers.describe("dashboard and onboarding focus ownership", function()
	helpers.it("(metrics-cleanup-authority) refused deletion revokes bridge and data continuations", function()
		with_window("ui.metrics_apps", function(dashboard, state)
			local pending, discoveries = {}, 0
			package.loaded["adapters.timer_scheduler"].after = function(_, callback)
				local handle = { timer = {} }
				pending[#pending + 1] = function() handle.timer = nil; callback() end
				return handle, true
			end
			helpers.with_fresh_modules({ "infra.app_picker" }, function()
				package.loaded["infra.app_picker"] = {
					discover_apps = function() discoveries = discoveries + 1 end,
				}
				helpers.assert_true(dashboard.show())
				local startup_count = #pending
				state.receiver({ body = { action = "pick" } })
				pending[#pending]()
				helpers.assert_eq(discoveries, 1, "a live bridge must dispatch application discovery")
				state.receiver({ body = { action = "pick" } })
				local queued_pick = pending[#pending]
				state.refused = true
				helpers.assert_eq(dashboard.close(), false)
				local count = #pending
				state.receiver({ body = { action = "pick" } })
				helpers.assert_eq(#pending, count, "cleanup-only bridge must not acquire new work")
				queued_pick()
				helpers.assert_eq(discoveries, 1, "previously queued actions must also lose authority")
				helpers.assert_eq(dashboard.push_live_update(), false)
				for index = 1, startup_count do pending[index]() end
				helpers.assert_eq(#pending, count, "retired bootstrap must not schedule a data refresh")
				state.refused = false
				helpers.assert_true(dashboard.close(), "exact native cleanup must remain retryable")
				helpers.assert_eq(state.deleted, 2)
				helpers.assert_true(dashboard.show(), "settled cleanup must allow a new generation")
				state.receiver({ body = { action = "pick" } })
				pending[#pending]()
				helpers.assert_eq(discoveries, 2)
			end)
		end)
	end)
	helpers.it("(metrics-cleanup-authority) late native close settles a retired exact owner", function()
		with_window("ui.metrics_apps", function(dashboard, state)
			helpers.assert_true(dashboard.show())
			local old_view, old_receiver = state.view, state.receiver
			state.refused = true
			helpers.assert_eq(dashboard.close(), false)
			old_view.options.on_close()
			helpers.assert_nil(dashboard._wv)
			helpers.assert_eq(state.deleted, 1, "native settlement must not retry deletion")
			state.refused = false
			helpers.assert_true(dashboard.show())
			local current = dashboard._wv
			old_view.options.on_close()
			old_receiver({ body = { action = "pick" } })
			helpers.assert_eq(dashboard._wv, current, "old native close must not retire its successor")
			helpers.assert_true(dashboard.close())
		end)
	end)

	for _, refused in ipairs({ false, true }) do
		helpers.it("(webview-focus-owner) dashboard retirement revokes focus, delete refused=" .. tostring(refused), function()
			with_window("ui.metrics_apps", function(dashboard, state)
				helpers.assert_true(dashboard.show())
				require("tests.support.webview_focus_fixture").check(state.view,
					function() return dashboard.show() end,
					function() state.refused = refused; helpers.assert_eq(dashboard.close(), not refused) end,
					state.view.options)
			end)
		end)
		helpers.it("(webview-focus-owner) onboarding retirement revokes focus, delete refused=" .. tostring(refused), function()
			with_window("ui.onboarding", function(onboarding, state)
				helpers.assert_true(onboarding.run("/virtual/config.toml"))
				require("tests.support.webview_focus_fixture").check(state.view,
					function() return onboarding.run("/virtual/config.toml") end,
					function()
						if refused then
							state.refused = true
							state.receiver({ body = { action = "finish", answers = { locale = "en" } } })
							helpers.assert_eq(state.deleted, 1)
						else
							state.view.options.on_close()
						end
					end, state.view.options)
			end)
		end)
	end
	helpers.it("(webview-focus-owner) onboarding constructor close revokes factory focus", function()
		with_window("ui.onboarding", function(onboarding, state)
			state.close_during_create = true
			helpers.assert_eq(onboarding.run("/virtual/config.toml"), false)
			helpers.assert_eq(state.view.options.is_current(), false)
		end)
	end)
end)
