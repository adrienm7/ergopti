--- tests/unit/ui/test_ui_builder_owned_async.lua

local helpers = require("tests.helpers")

local function build_fixture(options)
	options = options or {}
	local state = {
		acquired = false,
		deleted = 0,
		mutations_before_acquire = 0,
		raw_timers = 0,
		scheduled = {},
	}
	local webview = { live = true }
	local function mutation(name)
		if state.acquired ~= true then
			state.mutations_before_acquire = state.mutations_before_acquire + 1
		end
		if options.throw_on == name then error("fixture " .. name .. " failure") end
		return webview
	end
	function webview:windowTitle() return mutation("windowTitle") end
	function webview:windowStyle() return mutation("windowStyle") end
	function webview:level() return mutation("level") end
	function webview:allowTextEntry() return mutation("allowTextEntry") end
	function webview:allowGestures() return mutation("allowGestures") end
	function webview:allowNewWindows() return mutation("allowNewWindows") end
	function webview:windowCallback(callback)
		state.window_callback = callback
		return mutation("windowCallback")
	end
	function webview:navigationCallback(callback)
		state.navigation_callback = callback
		return mutation("navigationCallback")
	end
	function webview:html()
		state.html_calls = (state.html_calls or 0) + 1
		return mutation("html")
	end
	function webview:show()
		state.show_calls = (state.show_calls or 0) + 1
		return mutation("show")
	end
	function webview:hswindow() return nil end
	function webview:delete()
		state.deleted = state.deleted + 1
		self.live = false
		return self
	end

	local timer = {
		doAfter = function()
			state.raw_timers = state.raw_timers + 1
			return {}
		end,
	}
	local webview_api = {
		windowMasks = { titled = 1, closable = 2, utility = 16 },
		new = function()
			state.created = webview
			return webview
		end,
	}
	local Builder = helpers.load_with_stubs("ui.ui_builder", {
		timer = timer,
		webview = webview_api,
		drawing = { windowLevels = { floating = 1 } },
		focus = function() return true end,
	})
	return Builder, state, webview
end

helpers.describe("ui_builder exact owned async descendants", function()
	helpers.it("publishes the webview before mutation and delegates every timer", function()
		local Builder, state, webview = build_fixture()
		local current = true
		local result = Builder.show_webview({
			frame = { x = 0, y = 0, w = 100, h = 100 },
			html_string = "<html></html>",
			on_webview_created = function(candidate)
				helpers.assert_true(candidate == webview)
				state.acquired = true
				return true
			end,
			is_current = function() return current end,
			schedule_after = function(delay, callback, label)
				state.scheduled[#state.scheduled + 1] = {
					delay = delay,
					callback = callback,
					label = label,
				}
				return true
			end,
		})
		helpers.assert_true(result == webview)
		helpers.assert_eq(state.mutations_before_acquire, 0)
		helpers.assert_eq(state.raw_timers, 0)
		helpers.assert_eq(#state.scheduled, 1)
		helpers.assert_eq(state.scheduled[1].label, "webview focus retry")

		state.navigation_callback("didFinishNavigation", webview, {})
		helpers.assert_eq(#state.scheduled, 2)
		helpers.assert_eq(state.scheduled[2].label, "webview i18n injection")
		helpers.assert_eq(state.raw_timers, 0)
		current = false
		state.scheduled[2].callback()
		helpers.assert_eq(state.html_calls, 1)
	end)

	helpers.it("returns the exact acquired candidate to caller cleanup on refusal", function()
		local Builder, state, webview = build_fixture({ throw_on = "windowTitle" })
		local result = Builder.show_webview({
			frame = { x = 0, y = 0, w = 100, h = 100 },
			html_string = "<html></html>",
			on_webview_created = function(candidate)
				helpers.assert_true(candidate == webview)
				state.acquired = true
				return true
			end,
			is_current = function() return true end,
			schedule_after = function() return true end,
		})
		helpers.assert_nil(result)
		helpers.assert_true(state.acquired)
		helpers.assert_true(webview.live,
			"the exact owner, not the factory, must settle an acquired candidate")
		helpers.assert_eq(state.deleted, 0)
	end)

	helpers.it("stops mutation immediately when ownership is revoked", function()
		local Builder, state, webview = build_fixture()
		local current = true
		local result = Builder.show_webview({
			frame = { x = 0, y = 0, w = 100, h = 100 },
			html_string = "<html></html>",
			on_webview_created = function(candidate)
				helpers.assert_true(candidate == webview)
				state.acquired = true
				current = false
				return false
			end,
			is_current = function() return current end,
			schedule_after = function() return true end,
		})
		helpers.assert_nil(result)
		helpers.assert_eq(state.mutations_before_acquire, 0)
		helpers.assert_eq(state.show_calls or 0, 0)
		helpers.assert_true(webview.live)
	end)
end)
