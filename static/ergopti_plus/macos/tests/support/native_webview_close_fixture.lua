--- tests/support/native_webview_close_fixture.lua

--- ==============================================================================
--- MODULE: Native WebView Close Reference Fixture
--- DESCRIPTION:
--- Models libwebview.m at packaged pin 1469832361b4c3687ec7d589c1b4efe4d3b742ee:
--- Explicit visible delete defers its close and retires the exact userdata.
--- This reference fixture omits native re-wrapping during recursive GC; the
--- separate webview_recursive_close_fixture models that unsafe flag's cycle.
--- Native references remain independent of callers dropping their Lua owners.
--- ==============================================================================

--- Builds one isolated native window constructor over the scenario observations.
--- @param h table Contains windows, retained and deferred collections.
--- @return function new_window Native-shaped WebView constructor.
local function make_windows(h)
	--- Drains native fades and accepted zero-delay scheduler callbacks separately
	--- from the synchronous business close notification.
	function h.drain_native_close()
		for _ = 1, 40 do
			local progressed = false
			local deferred_count = #h.deferred
			for _ = 1, deferred_count do progressed = true; table.remove(h.deferred, 1)() end
			local candidates, seen = {}, {}
			for _, timer in ipairs(h.timers or {}) do candidates[#candidates + 1] = timer; seen[timer] = true end
			for _, timer in ipairs(hs.timer.__timers or {}) do
				if not seen[timer] then candidates[#candidates + 1] = timer end
			end
			for _, timer in ipairs(candidates) do
				if timer.delay == 0 and (timer.active == true or timer.running == true) then
					progressed = true
					if timer.receive then timer.receive()
					elseif timer.deliver then timer:deliver()
					else timer:fire() end
				end
			end
			if not progressed then return end
		end
		error("native close cleanup did not settle")
	end
	local function gc(window)
		-- userdata_gc starts with luaL_testudata, so a retired userdata is a no-op.
		if window.disposed then return end
		window.disposed = true
		setmetatable(window, nil)
		h.retained[window] = nil
		window.close_callback, window.navigation_callback = nil, nil
	end
	local function new_window()
		local window = setmetatable({ visible = false, disposed = false, delete_on_close = false, deletes = 0 }, {})
		h.windows[#h.windows + 1] = window
		h.retained[window] = true -- HSWebViewWindow_toLua stores its own udRef.
		for _, name in ipairs({ "windowTitle", "windowStyle", "shadow", "allowTextEntry",
			"allowGestures", "level", "html" }) do
			window[name] = function(self) assert(not self.disposed); return self end
		end
		function window:deleteOnClose(value)
			assert(not self.disposed)
			if value == nil then return self.delete_on_close end
			self.policy_calls = (self.policy_calls or 0) + 1
			if self.policy_calls >= (h.policy_refuses_after_call or 1) then
				if h.policy_refuses == "throw" then error("native deleteOnClose refusal") end
				if h.policy_refuses == "false" then return false end
				if h.policy_refuses == "nil" then return nil end
			end
			self.delete_on_close = value
			return self
		end
		function window:windowCallback(callback) self.close_callback = callback; return self end
		function window:navigationCallback(callback) self.navigation_callback = callback; return self end
		function window:show() assert(not self.disposed); self.visible = true; return self end
		function window:hswindow()
			assert(not self.disposed)
			local native = {}
			for _, name in ipairs({ "moveToScreen", "unminimize", "raise", "focus" }) do
				native[name] = function(self) return self end
			end
			return native
		end
		function window:user_close()
			assert(not self.disposed)
			self.visible = false
			if self.close_callback then self.close_callback("closing", self) end
			if self.delete_on_close then gc(self) end
		end
		function window:delete()
			assert(not self.disposed, "native methods cannot reuse a consumed userdata")
			self.deletes = self.deletes + 1
			local function finish()
				self:user_close()
				gc(self) -- fade completion invokes GC after windowWillClose did so.
			end
			-- Public delete() always passes delay=0; visible windows use fadeOut.
			if self.visible then h.deferred[#h.deferred + 1] = finish else finish() end
		end
		return window
	end
	return new_window
end

return make_windows
