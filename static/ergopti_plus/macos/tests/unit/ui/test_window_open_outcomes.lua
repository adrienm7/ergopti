--- tests/unit/ui/test_window_open_outcomes.lua
--- HS-135 regression coverage for truthful native-window publication.

local helpers = require("tests.helpers")

local function logger_spy(state)
	local logger = helpers.make_logger_stub()
	logger.error = function() state.errors = state.errors + 1 end
	logger.success = function() state.successes = state.successes + 1 end
	return logger
end

local function fresh_hs()
	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded.hs = hs_stub
	return hs_stub
end

local function with_download_window(controls, callback)
	helpers.with_fresh_modules({
		"ui.download_window", "ui.ui_builder", "infra.logger", "infra.deferred_work",
		"infra.paths", "infra.i18n", "infra.text_utils", "hs", "tests.stubs.hs",
	}, function()
		local hs_stub = fresh_hs()
		local state = { errors = 0, successes = 0, show_calls = 0 }
		package.loaded["infra.logger"] = logger_spy(state)
		package.loaded["infra.deferred_work"] = { after = function() return true end }
		package.loaded["infra.paths"] = { shared = function() return "/controlled/assets" end }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.text_utils"] = {
			applescript_format = function(value) return value end,
			shell_quote = function(value) return value end,
		}
		package.loaded["ui.ui_builder"] = {
			get_app_geometry = function() return controls.geometry end,
			show_webview = function(opts)
				state.show_calls = state.show_calls + 1
				state.last_opts = opts
				return controls.webview
			end,
		}
		hs_stub.webview.usercontent.new = function()
			return { setCallback = function() end }
		end
		callback(require("ui.download_window"), state)
	end)
end

local function with_onboarding(controls, callback)
	helpers.with_fresh_modules({
		"ui.onboarding", "ui.ui_builder", "infra.logger", "infra.i18n",
		"infra.toml.writer", "infra.toml.codec", "infra.notifications", "infra.paths",
		"infra.deferred_work", "infra.text_utils", "infra.manifest_reader",
		"infra.dialog_util", "ui.menu.menu_paths", "adapters.file_system",
		"adapters.storage", "hs", "tests.stubs.hs",
	}, function()
		local hs_stub = fresh_hs()
		local state = {
			errors = 0,
			successes = 0,
			bridges = 0,
			callbacks = 0,
			deletes = 0,
			releases = 0,
			show_calls = 0,
			focus_calls = 0,
		}
		package.loaded["infra.logger"] = logger_spy(state)
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.toml.writer"] = {}
		package.loaded["infra.toml.codec"] = {}
		package.loaded["infra.notifications"] = {}
		package.loaded["infra.paths"] = { shared = function() return "/controlled/assets" end }
		package.loaded["infra.deferred_work"] = { after = function() return true end }
		package.loaded["infra.text_utils"] = {}
		package.loaded["infra.manifest_reader"] = {}
		package.loaded["adapters.file_system"] = {}
		package.loaded["adapters.storage"] = {}
		package.loaded["infra.dialog_util"] = {block_alert = function() return true end}
		package.loaded["ui.menu.menu_paths"] = {
			persist_config_dir_for_wizard = function() return false, "synthetic persistence refusal" end,
		}
		package.loaded["ui.ui_builder"] = {
			get_app_geometry = function() return controls.geometry end,
			get_centered_frame = function(width, height) return { w = width, h = height } end,
			show_webview = function(opts)
				state.show_calls = state.show_calls + 1
				state.last_opts = opts
				if controls.owned_webview == true then
					local view = {}
					function view:delete()
						state.deletes = state.deletes + 1
						if controls.delete_throws then error("synthetic onboarding delete refusal") end
						return self
					end
					state.webview = view
					return view
				end
				return controls.webview
			end,
			force_focus = function()
				state.focus_calls = state.focus_calls + 1
				return true
			end,
		}
		hs_stub.webview.windowMasks = { titled = 1, closable = 2 }
		hs_stub.webview.usercontent.new = function()
			state.bridges = state.bridges + 1
			local bridge = {}
			function bridge:setCallback(callback_value)
				if callback_value == nil then
					state.releases = state.releases + 1
				else
					state.callbacks = state.callbacks + 1
					state.bridge_callback = callback_value
				end
			end
			return bridge
		end
		callback(require("ui.onboarding"), state)
	end)
end

local function with_healthcheck(controls, callback)
	controls = controls or {}
	helpers.with_fresh_modules({
		"ui.healthcheck.core", "ui.healthcheck.helpers", "healthcheck.snapshot",
		"infra.logger", "infra.paths", "infra.i18n", "ui.ui_builder",
		"infra.dialog_util", "adapters.timer_scheduler", "hs", "tests.stubs.hs",
	}, function()
		local hs_stub = fresh_hs()
		local state = {
			errors = 0,
			successes = 0,
			deletes = 0,
			show_calls = 0,
			focus_calls = 0,
		}
		package.loaded["infra.logger"] = logger_spy(state)
		package.loaded["ui.healthcheck.helpers"] = {}
		package.loaded["healthcheck.snapshot"] = {}
		package.loaded["infra.paths"] = { shared = function() return "/shared" end }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.dialog_util"] = { block_alert = function() return true end }
		package.loaded["adapters.timer_scheduler"] = {
			every = function() error("poll must not start before navigation") end,
			cancel = function() return true end,
			after = function() return true end,
		}
		package.loaded["ui.ui_builder"] = {
			build_injected_html = function() return "<html></html>" end,
			get_app_geometry = function() return { width = 740, height = 560 } end,
			force_focus = function() state.focus_calls = state.focus_calls + 1; return true end,
		}

		local webview = {}
		for _, method in ipairs({
			"windowStyle", "windowTitle", "allowTextEntry", "allowNewWindows",
			"allowGestures", "level", "windowCallback", "navigationCallback",
		}) do webview[method] = function(self) return self end end
		webview.html = function(self)
			if controls.reject_html == true then error("fixture page load refusal") end
			return self
		end
		webview.show = function(self)
			state.show_calls = state.show_calls + 1
			return self
		end
		webview.delete = function()
			state.deletes = state.deletes + 1
			return webview
		end
		hs_stub.webview.new = function() return webview end
		hs_stub.webview.windowMasks = { titled = 1, closable = 2, miniaturizable = 4 }
		hs_stub.screen.mainScreen = function()
			return { frame = function() return { x = 0, y = 0, w = 1440, h = 900 } end }
		end
		hs_stub.json.encode = function() return "{}" end

		local healthcheck = require("ui.healthcheck.core")
		healthcheck.run = function() return {} end
		healthcheck.format_plain = function() return "diagnostic" end
		callback(healthcheck, state)
	end)
end

helpers.describe("native windows publish truthful open outcomes", function()
	helpers.it("download window refuses missing geometry without a success banner", function()
		with_download_window({ geometry = nil }, function(window, state)
			helpers.assert_eq(window.show({ kind = "mlx_model", model = "fixture" }), false)
			helpers.assert_eq(window.is_active(), false)
			helpers.assert_eq(state.show_calls, 0)
			helpers.assert_true(state.errors > 0, "the geometry refusal must be surfaced")
			helpers.assert_eq(state.successes, 0)
		end)
	end)

	helpers.it("download window rejects a factory refusal without queuing page work", function()
		with_download_window({ geometry = { width = 460, height = 380 }, webview = nil },
			function(window, state)
				helpers.assert_eq(window.show({ kind = "mlx_model", model = "fixture" }), false)
				helpers.assert_eq(window.is_active(), false)
				helpers.assert_nil(window._current_model,
					"a refused occupant must not leak its model into the next window")
				helpers.assert_eq(state.show_calls, 1)
				helpers.assert_true(state.errors > 0, "the factory refusal must be surfaced")
				helpers.assert_eq(state.successes, 0)
			end)
	end)

	helpers.it("onboarding validates geometry before acquiring a native bridge", function()
		with_onboarding({ geometry = nil }, function(onboarding, state)
			helpers.assert_eq(onboarding.run("/controlled/config.toml"), false)
			helpers.assert_eq(state.bridges, 0)
			helpers.assert_eq(state.callbacks, 0)
			helpers.assert_eq(state.show_calls, 0)
			helpers.assert_true(state.errors > 0, "the geometry refusal must be surfaced")
			helpers.assert_eq(state.successes, 0)
		end)
	end)

	helpers.it("onboarding releases its staged bridge after a factory refusal", function()
		with_onboarding({ geometry = { width = 900, height = 700 }, webview = nil },
			function(onboarding, state)
				helpers.assert_eq(onboarding.run("/controlled/config.toml"), false)
				helpers.assert_eq(state.bridges, 1)
				helpers.assert_eq(state.callbacks, 1)
				helpers.assert_eq(state.releases, 1)
				helpers.assert_eq(state.show_calls, 1)
				helpers.assert_true(state.errors > 0, "the factory refusal must be surfaced")
				helpers.assert_eq(state.successes, 0)
			end)
	end)

	helpers.it("onboarding publishes success only for the exact returned webview", function()
		local webview = { delete = function() return true end }
		with_onboarding({ geometry = { width = 900, height = 700 }, webview = webview },
			function(onboarding, state)
				helpers.assert_eq(onboarding.run("/controlled/config.toml"), true)
				helpers.assert_eq(state.successes, 1)
				helpers.assert_eq(state.releases, 0)
				helpers.assert_true(state.last_opts.usercontent ~= nil)
				state.last_opts.on_close()
				helpers.assert_eq(state.releases, 1,
					"native close must release the committed bridge exactly once")
			end)
	end)

	helpers.it("onboarding retains a wizard whose native delete raises", function()
		local controls = {
			delete_throws = true,
			geometry = {width = 900, height = 700},
			owned_webview = true,
		}
		with_onboarding(controls, function(onboarding, state)
			helpers.assert_true(onboarding.run("/controlled/config.toml"))
			helpers.assert_type(state.bridge_callback, "function")
			local finish = {body = {action = "finish", answers = {config_dir = "/refused"}}}

			state.bridge_callback(finish)
			helpers.assert_eq(state.releases, 0,
				"the live bridge must not release before native deletion commits")
			helpers.assert_true(onboarding.run("/controlled/config.toml"))
			helpers.assert_eq(state.show_calls, 1,
				"a failed close must not allocate a second onboarding window")
			helpers.assert_eq(state.focus_calls, 1,
				"the retained onboarding window must remain the singleton target")

			controls.delete_throws = false
			state.bridge_callback(finish)
			helpers.assert_eq(state.deletes, 2,
				"the same bridge must retry the exact retained WebView")
			helpers.assert_eq(state.releases, 1,
				"the bridge must release only after native deletion commits")
			helpers.assert_true(onboarding.run("/controlled/config.toml"))
			helpers.assert_eq(state.show_calls, 2,
				"a successor may open only after exact native deletion")
	end)
	end)

	helpers.it("healthcheck deletes a page-load refusal before show or focus", function()
		with_healthcheck({ reject_html = true }, function(healthcheck, state)
			helpers.assert_eq(healthcheck.show_window(), false)
			helpers.assert_eq(state.deletes, 1)
			helpers.assert_eq(state.show_calls, 0)
			helpers.assert_eq(state.focus_calls, 0)
			helpers.assert_true(state.errors > 0, "the page-load refusal must be surfaced")
			helpers.assert_eq(state.successes, 0)
		end)
	end)

	helpers.it("healthcheck reports success only after page load and native show", function()
		with_healthcheck({}, function(healthcheck, state)
			helpers.assert_eq(healthcheck.show_window(), true)
			helpers.assert_eq(state.show_calls, 1)
			helpers.assert_eq(state.focus_calls, 1)
			helpers.assert_eq(state.deletes, 0)
			helpers.assert_eq(state.errors, 0)
			helpers.assert_eq(state.successes, 1)
		end)
	end)
end)
