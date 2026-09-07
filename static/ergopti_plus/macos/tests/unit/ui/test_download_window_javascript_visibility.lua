--- tests/unit/ui/test_download_window_javascript_visibility.lua

--- ==============================================================================
--- MODULE: Download Window JavaScript Failure Visibility
--- DESCRIPTION:
--- Exercises every presentation dispatch path through the real window, with
--- native submission and completion failures independently controllable.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs one window scenario with isolated native presentation boundaries.
--- @param scenario function Receives the real window and observable fixture.
local function with_window(scenario)
	local names = {
		"ui.download_window", "ui.download_window.javascript", "ui.ui_builder",
		"infra.logger", "infra.deferred_work", "infra.paths", "infra.i18n",
		"infra.text_utils",
	}
	local saved, saved_hs = {}, _G.hs
	local saved_shell_runner = package.loaded["adapters.shell_runner"]
	for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	local fixture = { errors = {}, timers = {}, callbacks = {}, failure = nil }
	local noop = function() end
	package.loaded["infra.logger"] = {
		start = noop, success = noop, debug = noop, warn = noop,
		error = function(_, message, ...)
			fixture.errors[#fixture.errors + 1] = string.format(message, ...)
		end,
	}
	package.loaded["infra.deferred_work"] = {
		after = function(_, callback) fixture.timers[#fixture.timers + 1] = callback; return true end,
	}
	package.loaded["infra.paths"] = { shared = function() return "/assets" end }
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.text_utils"] = {}
	package.loaded["adapters.shell_runner"] = {}
	local view = {
		evaluateJavaScript = function(self, _, callback)
			if fixture.failure == "throw" then error("PRIVATE_NATIVE_SENTINEL") end
			if fixture.failure == "refuse" then return nil end
			if callback then fixture.callbacks[#fixture.callbacks + 1] = callback end
			return self
		end,
		delete = noop,
	}
	package.loaded["ui.ui_builder"] = {
		get_app_geometry = function() return { width = 460, height = 380 } end,
		show_webview = function(opts)
			fixture.navigation = opts.on_navigation
			if opts.on_webview_created then opts.on_webview_created(view) end
			return view
		end,
	}
	_G.hs = {
		webview = { usercontent = { new = function() return { setCallback = noop } end } },
		screen = { mainScreen = function()
			return { frame = function() return { x = 0, y = 0, w = 1920, h = 1080 } end }
		end },
		drawing = { windowLevels = { floating = 1 } },
		timer = { secondsSinceEpoch = function() return 1 end },
	}
	local ok, err = xpcall(function()
		local window = require("ui.download_window")
		helpers.assert_true(window.show({ kind = "mlx_install" }))
		scenario(window, fixture)
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	package.loaded["adapters.shell_runner"] = saved_shell_runner
	_G.hs = saved_hs
	if not ok then error(err, 0) end
end

helpers.describe("download-window-javascript-visibility", function()
	for _, path in ipairs({ "queued", "immediate", "fallback" }) do
		helpers.it("reports native evaluation throws on the " .. path .. " path", function()
			with_window(function(window, fixture)
				if path == "immediate" then fixture.navigation("didFinishNavigation") end
				fixture.failure = "throw"
				if path == "queued" then fixture.navigation("didFinishNavigation")
				elseif path == "fallback" then fixture.timers[1]()
				else window.set_detail("PRIVATE_PAYLOAD_SENTINEL") end
				helpers.assert_eq(#fixture.errors, 1, "native failures must reach the central logger")
				helpers.assert_true(fixture.errors[1]:find("PRIVATE_", 1, true) == nil)
			end)
		end)
	end

	helpers.it("observes asynchronous script failures and bounds repeated errors", function()
		with_window(function(window, fixture)
			fixture.navigation("didFinishNavigation")
			window.set_detail("PRIVATE_PAYLOAD_SENTINEL")
			helpers.assert_true(#fixture.callbacks >= 2, "queued and immediate scripts need completion observers")
			for _, callback in ipairs(fixture.callbacks) do
				callback(nil, { localizedDescription = "PRIVATE_ERROR_SENTINEL" })
			end
			helpers.assert_eq(#fixture.errors, 1)
			helpers.assert_true(fixture.errors[1]:find("PRIVATE_", 1, true) == nil)
		end)
	end)

	helpers.it("reports nonthrowing native submission refusal", function()
		with_window(function(_, fixture)
			fixture.failure = "refuse"
			fixture.navigation("didFinishNavigation")
			helpers.assert_eq(#fixture.errors, 1)
		end)
	end)
end)
