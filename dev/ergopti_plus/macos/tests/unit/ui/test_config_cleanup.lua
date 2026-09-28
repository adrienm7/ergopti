--- tests/unit/ui/test_config_cleanup.lua

local helpers = require("tests.helpers")
local Json = require("json")

local function with_host(controls, run)
	local context = { sessions = {}, views = {}, callbacks = {}, scripts = {} }
	local current_hs = _G.hs
	local logger = {}
	for _, name in ipairs({ "start", "success", "info", "error", "warn" }) do logger[name] = function() end end
	local stubs = {
		["infra.logger"] = logger,
		["infra.i18n"] = { get = function(key) return key end },
		["infra.paths"] = { shared = function(path) return "/shared/" .. path end },
		["config_cleanup_session"] = { new = function(options)
			local session = { calls = {}, closed = 0, options = options }
			session.token = "session-" .. (#context.sessions + 1)
			function session:handle(payload)
				self.calls[#self.calls + 1] = payload
				if payload == "ready" then return { session = self.token, status = "ready", keys = {} } end
			end
			function session:close() self.closed = self.closed + 1 end
			context.sessions[#context.sessions + 1] = session
			return session
		end },
	}
	stubs["ui.ui_builder"] = {
		get_app_geometry = function() return { width = 720, height = 560 } end,
		force_focus = function() context.focused = true; return true end,
		show_webview = function(options)
			context.options = options
			local view = { deleted = 0 }
			function view:delete()
				self.deleted = self.deleted + 1
				return controls.delete ~= false
			end
			function view:evaluateJavaScript(script) context.scripts[#context.scripts + 1] = script end
			context.views[#context.views + 1] = view
			options.on_webview_created(view)
			if controls.show == false then return nil end
			return view
		end,
	}
	_G.hs = {
		json = Json,
		screen = { mainScreen = function()
			return { frame = function() return { x = 10, y = 20, w = 640, h = 400 } end }
		end },
		webview = { windowMasks = { titled = 1, closable = 2, resizable = 8 }, usercontent = { new = function(name)
			context.bridge = name
			return { setCallback = function(self, callback)
				if callback then context.callbacks[#context.callbacks + 1] = callback end
				return self
			end }
		end } },
	}
	local saved, names = {}, { "ui.config_cleanup" }
	for name in pairs(stubs) do names[#names + 1] = name end
	for _, name in ipairs(names) do saved[name] = { package.loaded[name] }; package.loaded[name] = stubs[name] end
	local ok, detail = xpcall(function() run(require("ui.config_cleanup"), context) end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name][1] end
	_G.hs = current_hs
	if not ok then error(detail, 0) end
end

helpers.describe("configuration cleanup WebView (macOS)", function()
	helpers.it("opens without scanning, clamps geometry, and delivers ready through the shared bridge", function()
		with_host({}, function(host, context)
			helpers.assert_eq(host.open({ path = "/trusted/config.toml" }), true)
			helpers.assert_eq(#context.sessions[1].calls, 0)
			helpers.assert_eq(context.bridge, "config_cleanup_bridge")
			helpers.assert_eq(context.options.style_masks, 11, "the settings window must be resizable")
			helpers.assert_eq(context.options.frame, { x = 10, y = 20, w = 640, h = 400 })
			context.callbacks[1]({ body = "ready" })
			helpers.assert_eq(#context.scripts, 1)
			helpers.assert_contains(context.scripts[1], "window.receiveConfigCleanup(")
			helpers.assert_contains(context.scripts[1], '"session":"session-1"')
			helpers.assert_contains(context.scripts[1], '"keys":[]')
		end)
	end)
	helpers.it("focuses the current window without replacing its session", function()
		with_host({}, function(host, context)
			host.open({ path = "/trusted/config.toml" })
			helpers.assert_eq(host.open({ path = "/trusted/config.toml" }), true)
			helpers.assert_eq(#context.sessions, 1)
			helpers.assert_eq(context.focused, true)
		end)
	end)
	helpers.it("rejects stale closes and fences callbacks after native close and reopen", function()
		with_host({}, function(host, context)
			host.open({ path = "/trusted/config.toml" })
			local first, old_close = context.callbacks[1], context.options.on_close
			first({ body = "ready" })
			first({ body = { action = "close", session = "wrong" } })
			helpers.assert_eq(context.views[1].deleted, 0)
			old_close()
			helpers.assert_eq(context.sessions[1].closed, 1)
			host.open({ path = "/trusted/config.toml" })
			first({ body = "ready" })
			old_close()
			helpers.assert_eq(#context.scripts, 1)
			helpers.assert_eq(context.sessions[2].closed, 0)
		end)
	end)
	helpers.it("closes only for the displayed session token", function()
		with_host({}, function(host, context)
			host.open({ path = "/trusted/config.toml" })
			context.callbacks[1]({ body = "ready" })
			context.callbacks[1]({ body = { action = "close", session = "session-1" } })
			helpers.assert_eq(context.views[1].deleted, 1)
			helpers.assert_eq(context.sessions[1].closed, 1)
		end)
	end)
	helpers.it("retains a failed native deletion and refuses another owner until retry succeeds", function()
		local controls = { show = false, delete = false }
		with_host(controls, function(host, context)
			helpers.assert_eq(host.open({ path = "/trusted/config.toml" }), false)
			helpers.assert_eq(host.open({ path = "/trusted/config.toml" }), false)
			helpers.assert_eq(#context.sessions, 1)
			controls.show, controls.delete = true, true
			helpers.assert_eq(host.open({ path = "/trusted/config.toml" }), true)
			helpers.assert_eq(#context.sessions, 2)
		end)
	end)
end)
