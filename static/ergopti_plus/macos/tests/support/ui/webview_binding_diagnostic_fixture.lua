--- tests/support/ui/webview_binding_diagnostic_fixture.lua

--- ==============================================================================
--- MODULE: Native Binding Diagnostic Execution Fixture
--- DESCRIPTION:
--- Executes the actual Lua diagnostic, factory and close owner with controlled
--- native ports. These observations are portable, never Cocoa qualification.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED = { "ui.ui_builder", "ui.webview_close_owner", "infra.deferred_work", "infra.logger",
	"adapters.json_codec", "adapters.timer_scheduler", "infra.locale", "json", "locale.core",
	"webview.i18n_seed", "webview.presentation", "window_titles", "adapters.webview_result", "hs.json", "lfs" }

--- Runs one diagnostic transaction with native messages and completions held apart.
--- @param scenario function Assertions over the controlled observation.
local function with_diagnostic(scenario)
	local previous_lfs = rawget(_G, "lfs")
	local scoped, scope_error = pcall(helpers.with_stub_scope, OWNED, function()
		local json, lfs = require("json"), require("lfs")
		local output = os.tmpname()
		assert(os.remove(output)); assert(lfs.mkdir(output))
		local driver = helpers.driver_root()
		local root = assert(driver:match("^(.*)/static/ergopti_plus/macos/$"))
		local h = { now = 0, timers = {}, views = {}, posts = {}, writes = {}, states = {}, sequence = 0 }
		local config = { output_dir = output, expected_version = "1.1.1", nonce = "execution-owned",
			source_revision = string.rep("a", 40), production_root = root .. "/static/ergopti_plus" }
		local function timer(delay, callback)
			h.sequence = h.sequence + 1
			local t = { due = h.now + delay, sequence = h.sequence, callback = callback, active = false }
			function t:start() self.active = true; h.timers[self] = true; return self end
			function t:stop() self.active = false; h.timers[self] = nil; return self end
			function t:running() return self.active end
			return t
		end
		function h.step()
			local candidate
			for t in pairs(h.timers) do
				if t.active and (not candidate or t.due < candidate.due
					or (t.due == candidate.due and t.sequence < candidate.sequence)) then candidate = t end
			end
			assert(candidate, "diagnostic lost its observation timer")
			h.now = candidate.due
			candidate:stop(); candidate.callback()
		end
		function h.until_condition(condition)
			for _ = 1, 1000 do if condition() then return end; h.step() end
			error("diagnostic did not reach the requested execution boundary")
		end
		local methods, metadata = {}, {}
		metadata.__index = methods
		local function close(view)
			local state = h.states[view]
			state.visible = false
			if not state.closed then
				state.closed = true
				if state.callback then state.callback("closing", view) end
			end
		end
		local function consume(view)
			if getmetatable(view) == nil then return end
			close(view)
			h.states[view].callback = nil
			debug.setmetatable(view, nil)
		end
		for _, name in ipairs({ "windowTitle", "windowStyle", "shadow", "allowTextEntry", "allowGestures", "level" }) do
			methods[name] = function(self) return self end
		end
		function methods:deleteOnClose(value)
			if value == nil then return h.states[self].delete_on_close end
			h.states[self].delete_on_close = value; return self
		end
		function methods:allowNewWindows(value)
			if value == nil then return h.states[self].allow_new_windows end
			h.states[self].allow_new_windows = value; return self
		end
		function methods:windowCallback(fn) h.states[self].callback = fn; return self end
		function methods:navigationCallback(fn) h.states[self].navigation = fn; return self end
		function methods:html()
			local state = h.states[self]
			timer(0, function() if state.navigation then state.navigation("didFinishNavigation", self) end end):start()
			return self
		end
		function methods:show() h.states[self].visible = true; return self end
		function methods:hide() h.states[self].visible = false; return self end
		function methods:isVisible() return h.states[self].visible end
		function methods:hswindow()
			local view = self
			return { id = function() return h.states[view].id end,
				application = function() return { pid = function() return 711 end } end,
				close = function() close(view); return true end }
		end
		function methods:delete()
			if h.states[self].visible then timer(0, function() consume(self) end):start()
			else consume(self) end
		end
		function h.deliver(post, source)
			local fn = post.controller.callback
			if fn then fn({ name = "ergopti_binding", webView = source or post.view, body = post.payload }) end
		end
		function h.complete(post, value, failure) post.complete(value == nil and true or value, failure or { code = 0 }) end
		function methods:evaluateJavaScript(script, callback)
			local payload = json.decode(assert(script:match("postMessage%((.*)%)%; true$"), "unexpected actual post expression"))
			local post = { payload = payload, view = self, controller = h.states[self].controller, complete = callback }
			h.posts[payload.kind] = post
			if payload.kind ~= "current-b-after-a-gc" then
				timer(0, function() h.deliver(post); h.complete(post) end):start()
			end
		end
		local logger = helpers.make_logger_stub()
		logger.initialize_privacy = function() return true end
		package.loaded["infra.logger"] = logger
		local function new_view(_, _, controller)
			-- A closed file supplies actual userdata without retaining an OS file.
			-- Its test metatable models the native view, never WebKit behavior.
			local view = assert(io.tmpfile()); assert(view:close())
			debug.setmetatable(view, metadata)
			h.views[#h.views + 1] = view
			h.states[view] = { id = #h.views, controller = controller, visible = false,
				delete_on_close = false, allow_new_windows = true }
			return view
		end
		local function new_controller()
			local controller = {}
			function controller:setCallback(fn) self.callback = fn; return self end
			return controller
		end
		local native_json = { read = function() return config end, encode = json.encode,
			write = function(value, path)
				h.writes[path:match("[^/]+$")] = value
				local file = assert(io.open(path, "wb")); assert(file:write(json.encode(value))); assert(file:close()); return true
			end }
		local builder = helpers.load_with_stubs("ui.ui_builder", {
			webview = { new = new_view, usercontent = { new = new_controller }, windowMasks = { titled = 1, closable = 2 } },
			timer = { new = timer, doAfter = function(delay, fn) return timer(delay, fn):start() end,
				absoluteTime = function() return h.now * 1e9 end },
			processInfo = { processID = 711, version = "1.1.1" }, json = native_json,
			console = { getConsole = function() return "" end },
		})
		assert(builder)
		package.loaded["hs.json"] = native_json
		local environment = setmetatable({ hs = hs, package = { path = package.path } }, { __index = _G })
		environment._G = environment
		local ok, failure = xpcall(function()
			assert(loadfile(root .. "/tools/diagnostics/macos_webview_binding.lua", "t", environment))()
			h.probe = environment.ERGOPTI_WEBVIEW_BINDING_PROBE
			function h.result() return h.writes["result.json.tmp"] end
			scenario(h)
		end, debug.traceback)
		if hs.shutdownCallback then hs.shutdownCallback() end
		for name in lfs.dir(output) do if name ~= "." and name ~= ".." then assert(os.remove(output .. "/" .. name)) end end
		assert(lfs.rmdir(output))
		if not ok then error(failure, 0) end
	end)
	rawset(_G, "lfs", previous_lfs)
	if not scoped then error(scope_error, 0) end
end

return with_diagnostic
