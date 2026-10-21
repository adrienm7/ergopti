--- tests/support/ui/physical_close_diagnostic_fixture.lua

--- ==============================================================================
--- MODULE: Physical Close Diagnostic Execution Fixture
--- DESCRIPTION:
--- Runs the actual diagnostic, host, factory and scheduler with controlled native
--- boundaries. These portable observations never qualify native Cocoa behavior.
--- ==============================================================================

local helpers = require("tests.helpers")
local OWNED = { "ui.physical_shortcuts", "ui.ui_builder", "ui.webview_close_owner", "infra.deferred_work",
	"adapters.timer_scheduler", "infra.logger", "infra.paths", "infra.i18n", "webview.i18n_seed", "window_titles",
	"adapters.file_system", "adapters.json_codec", "shortcuts.physical_slots", "shortcuts.physical_editor_window",
	"shortcuts.physical_availability", "infra.locale", "locale.core", "webview.presentation", "hs.webview", "json" }

--- Executes the actual diagnostic with individual retirement facts held back.
--- @param blocked string|nil Boundary whose observed acknowledgement is withheld.
--- @param scenario function Assertions over the returned observation.
local function run(blocked, scenario)
	helpers.with_stub_scope(OWNED, function()
		local h = { now = 0, timers = {}, states = {}, sequence = 0, views = {}, refs = {} }
		local driver = helpers.driver_root()
		local root = assert(driver:match("^(.*)/static/ergopti_plus/macos/$"))
		local logger = helpers.make_logger_stub()
		logger.initialize_privacy = function() return true end
		package.loaded["infra.logger"] = logger
		package.loaded["infra.paths"] = { shared = function(path) return path end }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["webview.i18n_seed"] = {}
		package.loaded["window_titles"] = { compose = function(key) return key end }
		package.loaded["adapters.file_system"] = { read = function() return "{}" end }
		package.loaded["shortcuts.physical_slots"] = { new = function() return { candidates = function() return {} end } end }
		package.loaded["shortcuts.physical_editor_window"] = { new = function() return {
			retire = function() return true end, receive = function() return true end,
		} end }
		local function timer(delay, callback, diagnostic)
			h.sequence = h.sequence + 1
			local t = { due = h.now + delay, callback = callback, sequence = h.sequence, active = false }
			function t:start() self.active = true; h.timers[self] = true; return self end
			function t:stop()
				if blocked == "timer" and not diagnostic then return false end
				self.active = false; h.timers[self] = nil; return self
			end
			function t:running() return self.active end
			return t
		end
		function h.step()
			local next_timer
			for t in pairs(h.timers) do
				if t.active and (not next_timer or t.due < next_timer.due
					or (t.due == next_timer.due and t.sequence < next_timer.sequence)) then next_timer = t end
			end
			assert(next_timer, "diagnostic lost its timer")
			h.now = next_timer.due
			-- A native one-shot fires only once even if its stop acknowledgement fails.
			h.timers[next_timer] = nil; next_timer.callback()
		end
		function h.drain()
			for _ = 1, 1600 do if h.result then return end; h.step() end
			error("diagnostic did not publish its refusal")
		end
		local methods, bridge_methods = {}, {}
		local metadata, bridge_metadata = methods, bridge_methods
		metadata.__index, bridge_metadata.__index = methods, bridge_methods
		local function native_userdata(mt)
			local value = assert(io.tmpfile()); assert(value:close()); debug.setmetatable(value, mt); return value
		end
		local function notify(view)
			local s = h.states[view]
			if s.closed then return end
			s.visible, s.closed = false, true
			if s.callback then s.callback("closing", view) end
		end
		for _, name in ipairs({ "windowTitle", "windowStyle", "shadow", "allowTextEntry", "allowGestures", "level", "html" }) do
			methods[name] = function(self) return self end
		end
		function methods:deleteOnClose(value)
			if value == nil then return h.states[self].automatic end
			h.states[self].automatic = value; return self
		end
		function methods:allowNewWindows(value)
			if value == nil then return h.states[self].children end
			h.states[self].children = value; return self
		end
		function methods:windowCallback(fn) h.states[self].callback = fn; return self end
		function methods:navigationCallback() return self end
		function methods:evaluateJavaScript() return self end
		function methods:show() h.states[self].visible = true; return self end
		function methods:isVisible() return h.states[self].visible end
		function methods:hswindow()
			local view = self
			local window = { id = function() return h.states[view].id end,
				application = function() return { pid = function() return 711 end } end,
				close = function() notify(view); return true end }
			for _, name in ipairs({ "moveToScreen", "unminimize", "raise", "focus" }) do window[name] = function(self) return self end end
			return window
		end
		function methods:delete()
			local view, visible = self, h.states[self].visible
			local function consume()
				notify(view)
				if blocked ~= "consumption" then h.states[view].callback = nil; debug.setmetatable(view, nil) end
			end
			if visible then timer(0, consume, true):start() else consume() end
		end
		function bridge_methods:setCallback(fn)
			if fn ~= nil and blocked == "bind_throw" then error("actual binding boundary refused") end
			if fn == nil and blocked == "detach_throw" then error("actual detach boundary refused") end
			if fn == nil and blocked == "detach" then return false end
			if fn == nil and blocked == "callback" then h.retained_callback = h.refs[self] end
			h.refs[self] = fn; return self
		end
		local native = { new = function()
			local view = native_userdata(metadata)
			h.views[#h.views + 1] = view
			h.states[view] = { id = #h.views, automatic = false, children = true }
			return view
		end, usercontent = { new = function() return native_userdata(bridge_metadata) end },
			windowMasks = { titled = 1, closable = 2, resizable = 8 } }
		package.loaded["hs.webview"] = native
		local host = helpers.load_with_stubs("ui.physical_shortcuts", {
			webview = native, json = { decode = function() return {} end }, focus = function() end,
			processInfo = { processID = 711, version = "1.1.1", arch = "arm64" },
			screen = { mainScreen = function() return {} end },
			getObjectMetatable = function(name) return name == "hs.webview" and metadata or bridge_metadata end,
			timer = { new = timer, absoluteTime = function() return h.now * 1e9 end,
				doAfter = function(delay, fn) return timer(delay, fn, true):start() end },
		})
		assert(host)
		local builder = package.loaded["ui.ui_builder"]
		builder.get_app_geometry = function() return { width = 700, height = 600 } end
		builder.get_centered_frame = function() return {} end
		builder.build_injected_html = function() return "<html></html>" end
		local environment = setmetatable({ hs = hs, package = { path = package.path, loaded = package.loaded } }, { __index = _G })
		local probe = assert(loadfile(root .. "/tools/diagnostics/macos_physical_shortcuts_close.lua", "t", environment))()
		h.state = probe.run({ production_root = root .. "/static/ergopti_plus", expected_version = "1.1.1",
			nonce = "execution-owned", source_revision = string.rep("a", 40), source_manifest_digest = string.rep("b", 64) },
			function(result) h.result = result end)
		scenario(h)
	end)
end

return run
