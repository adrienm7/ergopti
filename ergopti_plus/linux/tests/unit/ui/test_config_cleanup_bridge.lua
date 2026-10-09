--- tests/unit/ui/test_config_cleanup_bridge.lua

local helpers = require("tests.helpers")

local function with_bridge(controls, run)
	local context = { sessions = {}, scripts = {}, shown = 0, hidden = 0, next_epoch = 0 }
	local logger = {}
	for _, name in ipairs({ "start", "success", "info", "error", "warn" }) do logger[name] = function() end end
	local manager = {
		current_epoch = function() return context.epoch end,
		show = function()
			context.shown = context.shown + 1
			if controls.show == false then return false end
			if not context.epoch then context.next_epoch = context.next_epoch + 1; context.epoch = context.next_epoch end
			return true
		end,
		eval_js = function(_, script) context.scripts[#context.scripts + 1] = script; return true end,
	}
	local stubs = {
		["logger.shim"] = logger, ["ui.webview_manager"] = manager,
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
	local saved, names = {}, { "ui.config_cleanup.bridge" }
	for name in pairs(stubs) do names[#names + 1] = name end
	for _, name in ipairs(names) do saved[name] = { package.loaded[name] }; package.loaded[name] = stubs[name] end
	local ok, detail = xpcall(function() run(require("ui.config_cleanup.bridge"), context) end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name][1] end
	if not ok then error(detail, 0) end
end

local function native_context(context)
	local epoch = context.epoch
	return { epoch = epoch, close_owned_window = function()
		if context.epoch ~= epoch then return false end
		context.hidden = context.hidden + 1
		context.epoch = nil
		return true
	end }
end

helpers.describe("configuration cleanup WebView (Linux)", function()
	helpers.it("opens without scanning and pushes the current ready state to the shared receiver", function()
		with_bridge({}, function(bridge, context)
			helpers.assert_eq(bridge.bridge_name, "config_cleanup_bridge")
			helpers.assert_eq(bridge.open({ path = "/trusted/config.toml" }), true)
			helpers.assert_eq(#context.sessions[1].calls, 0)
			bridge.on_message("ready", {}, native_context(context))
			helpers.assert_eq(#context.scripts, 1)
			helpers.assert_contains(context.scripts[1], "window.receiveConfigCleanup(")
			helpers.assert_contains(context.scripts[1], '"keys":[]')
		end)
	end)
	helpers.it("refuses headless native creation and closes the provisional session", function()
		with_bridge({ show = false }, function(bridge, context)
			helpers.assert_eq(bridge.open({ path = "/trusted/config.toml" }), false)
			helpers.assert_eq(context.sessions[1].closed, 1)
			bridge.on_message("ready", {}, { epoch = 1 })
			helpers.assert_eq(#context.scripts, 0)
		end)
	end)
	helpers.it("rejects missing and stale native epochs even for a ready message", function()
		with_bridge({}, function(bridge, context)
			bridge.open({ path = "/trusted/config.toml" })
			bridge.on_message("ready", {}, {})
			bridge.on_message("ready", {}, { epoch = context.epoch + 1 })
			helpers.assert_eq(#context.sessions[1].calls, 0)
			helpers.assert_eq(#context.scripts, 0)
		end)
	end)
	helpers.it("keeps the current session when the menu focuses its existing page", function()
		with_bridge({}, function(bridge, context)
			bridge.open({ path = "/trusted/config.toml" })
			helpers.assert_eq(bridge.open({ path = "/trusted/config.toml" }), true)
			helpers.assert_eq(#context.sessions, 1)
			helpers.assert_eq(context.shown, 2)
		end)
	end)
	helpers.it("closes only the displayed session and ignores its old close callback after reopen", function()
		with_bridge({}, function(bridge, context)
			bridge.open({ path = "/trusted/config.toml" })
			local old_context = native_context(context)
			bridge.on_message("ready", {}, old_context)
			bridge.on_message({ action = "close", session = "wrong" }, {}, old_context)
			helpers.assert_eq(context.hidden, 0)
			bridge.on_message({ action = "close", session = "session-1" }, {}, old_context)
			helpers.assert_eq(context.hidden, 1)
			bridge.open({ path = "/trusted/config.toml" })
			bridge.on_window_closed(old_context.epoch)
			bridge.on_message("ready", {}, old_context)
			helpers.assert_eq(context.sessions[2].closed, 0)
			helpers.assert_eq(#context.scripts, 1)
			bridge.on_message("ready", {}, native_context(context))
			helpers.assert_eq(#context.scripts, 2)
		end)
	end)
end)
