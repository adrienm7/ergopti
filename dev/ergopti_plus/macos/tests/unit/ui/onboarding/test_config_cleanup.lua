--- tests/unit/ui/onboarding/test_config_cleanup.lua

local helpers = require("tests.helpers")
local Json = require("json")

local function with_host(controls, run)
	local context = { sessions = {}, views = {}, callbacks = {}, scripts = {}, evaluations = {}, errors = {} }
	local current_hs = _G.hs
	local real_session = controls.real_session and require("config_cleanup_session") or nil
	local logger = {}
	for _, name in ipairs({ "start", "success", "info", "warn" }) do logger[name] = function() end end
	logger.error = function(_, message, ...) context.errors[#context.errors + 1] = string.format(message, ...) end
	local stubs = {
		["infra.logger"] = logger,
		["infra.i18n"] = { get = function(key) return key end },
		["infra.paths"] = { shared = function(path) return "/shared/" .. path end },
		["config_cleanup_session"] = { new = function(options)
			if real_session then
				local session = real_session.new(options)
				context.sessions[#context.sessions + 1] = session
				return session
			end
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
			function view:evaluateJavaScript(script, done)
				context.scripts[#context.scripts + 1] = script
				context.evaluations[#context.evaluations + 1] = { script = script, done = done }
				if controls.submit then return controls.submit(self, done) end
				return self
			end
			context.views[#context.views + 1] = view
			options.on_webview_created(view)
			if controls.show == false then return nil end
			return view
		end,
	}
	_G.hs = {
		json = { encode = function(value)
			if controls.encode then return controls.encode(value) end
			return Json.encode(value)
		end },
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
			helpers.assert_eq(context.options.app_id, "config_cleanup",
				"(window-title-brand-once) the shared manifest names the window")
			helpers.assert_nil(context.options.title, "(window-title-brand-once) no caller caption competes with the manifest")
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

helpers.describe("configuration cleanup JavaScript receipts", function()
	for _, mode in ipairs({ "nil", "false", "foreign", "throw" }) do
		helpers.it("(cleanup-js-receipts) native submission " .. mode .. " is visible and bounded", function()
			with_host({ submit = function(self)
				if mode == "throw" then error("PRIVATE_CONFIG_PATH") end
				if mode == "false" then return false end
				if mode == "foreign" then return {} end
				if mode == "nil" then return nil end
				return self
			end }, function(host, context)
				helpers.assert_eq(host.open({ path = "/PRIVATE_CONFIG_PATH/config.toml" }), true)
				for _ = 1, 3 do context.callbacks[1]({ body = "ready" }) end
				helpers.assert_eq(#context.evaluations, 3)
				helpers.assert_eq(#context.errors, 1, "one exact owner reports a repeated refusal only once")
				helpers.assert_nil(context.errors[1]:find("PRIVATE_CONFIG_PATH", 1, true))
			end)
		end)
	end
	for _, error_value in ipairs({ false, { code = 42, message = "PRIVATE_CONFIG_PATH" },
		{ code = 0, domain = "PRIVATE_CONFIG_PATH" } }) do
		helpers.it("(cleanup-js-receipts) a native execution error is observed privately: " .. tostring(type(error_value) == "table" and error_value.code or error_value), function()
			with_host({}, function(host, context)
				helpers.assert_eq(host.open({ path = "/trusted/config.toml" }), true)
				context.callbacks[1]({ body = "ready" })
				local done = context.evaluations[1].done
				helpers.assert_type(done, "function", "native evaluation needs its completion receipt")
				done(nil, error_value)
				done(nil, error_value)
				helpers.assert_eq(#context.errors, 1)
				helpers.assert_nil(context.errors[1]:find("PRIVATE_CONFIG_PATH", 1, true))
			end)
		end)
	end
	for _, sentinel in ipairs({ "nil", "zero" }) do
		helpers.it("(cleanup-js-receipts) native success " .. sentinel .. " remains healthy", function()
			with_host({}, function(host, context)
				helpers.assert_eq(host.open({ path = "/trusted/config.toml" }), true)
				context.callbacks[1]({ body = "ready" })
				local done = context.evaluations[1].done
				helpers.assert_type(done, "function")
				local native_error
				if sentinel == "zero" then native_error = { code = 0 } end
				done(nil, native_error)
				helpers.assert_eq(#context.errors, 0)
			end)
		end)
	end
	for _, mode in ipairs({ "nil", "throw" }) do
		helpers.it("(cleanup-js-receipts) encoding " .. mode .. " is bounded and never dispatched", function()
			with_host({ encode = function()
				if mode == "throw" then error("PRIVATE_CONFIG_PATH") end
			end }, function(host, context)
				helpers.assert_eq(host.open({ path = "/trusted/config.toml" }), true)
				for _ = 1, 3 do context.callbacks[1]({ body = "ready" }) end
				helpers.assert_eq(#context.evaluations, 0)
				helpers.assert_eq(#context.errors, 1)
				helpers.assert_nil(context.errors[1]:find("PRIVATE_CONFIG_PATH", 1, true))
			end)
		end)
	end
	helpers.it("(cleanup-js-receipts) a retired owner's completion cannot report against its successor", function()
		with_host({}, function(host, context)
			host.open({ path = "/trusted/config.toml" })
			context.callbacks[1]({ body = "ready" })
			local done = context.evaluations[1].done
			helpers.assert_type(done, "function")
			context.options.on_close()
			helpers.assert_eq(host.open({ path = "/trusted/config.toml" }), true)
			done(nil, { message = "PRIVATE_CONFIG_PATH" })
			helpers.assert_eq(#context.errors, 0)
			context.callbacks[2]({ body = "ready" })
			context.evaluations[2].done(nil, { message = "PRIVATE_CONFIG_PATH" })
			helpers.assert_eq(#context.errors, 1, "the replacement owns independent diagnostic authority")
		end)
	end)
	helpers.it("(cleanup-js-receipts) encoding reentry cannot dispatch to a retired view", function()
		local controls = {}
		with_host(controls, function(host, context)
			host.open({ path = "/trusted/config.toml" })
			controls.encode = function(value)
				context.options.on_close()
				helpers.assert_eq(host.open({ path = "/trusted/config.toml" }), true)
				return Json.encode(value)
			end
			context.callbacks[1]({ body = "ready" })
			helpers.assert_eq(#context.evaluations, 0)
			helpers.assert_eq(#context.errors, 0, "a retired owner cannot publish diagnostics either")
			helpers.assert_eq(context.sessions[1].closed, 1)
			helpers.assert_eq(context.sessions[2].closed, 0)
		end)
	end)
end)

helpers.it("(cleanup-js-receipts) the real cleanup preview observes the native delivery refusal", function()
	helpers.with_fresh_modules({ "config_cleanup_session", "config_unused_keys" }, function()
		with_host({ real_session = true, submit = function() return nil end }, function(host, context)
			local reads = 0
			helpers.assert_eq(host.open({
				path = "/trusted/config.toml", collect = function() end,
				file_adapter = { read_with_status = function(path)
					helpers.assert_eq(path, "/trusted/config.toml")
					reads = reads + 1
					return "[unused]\nkey = 1\n", "ok"
				end },
			}), true)
			helpers.assert_eq(reads, 0, "opening must not start a filesystem scan")
			context.callbacks[1]({ body = "ready" })
			helpers.assert_eq(reads, 1)
			helpers.assert_eq(#context.evaluations, 1)
			local state = Json.decode(assert(context.scripts[1]:match("window%.receiveConfigCleanup%((.*)%)$")))
			helpers.assert_eq(state.status, "ready")
			helpers.assert_eq(#state.keys, 1)
			helpers.assert_eq(state.keys[1].path, { "unused", "key" })
			helpers.assert_eq(#context.errors, 1, "a real session result cannot be silently lost at WebKit")
		end)
	end)
end)
