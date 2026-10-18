--- tests/support/native_webview_close_fixture.lua

--- ==============================================================================
--- MODULE: Native WebView Close Reference Fixture
--- DESCRIPTION:
--- Models libwebview.m at packaged pin 1469832361b4c3687ec7d589c1b4efe4d3b742ee:
--- windowWillClose releases udRef only with deleteOnClose; explicit visible
--- delete defers its close and tolerates the second userdata_gc invocation.
--- Native references remain independent of callers dropping their Lua owners.
--- ==============================================================================

--- Builds one isolated native window constructor over the scenario observations.
--- @param h table Contains windows, retained and deferred collections.
--- @return function new_window Native-shaped WebView constructor.
local function make_windows(h)
	local function gc(window)
		-- userdata_gc starts with luaL_testudata, so a retired userdata is a no-op.
		if window.disposed then return end
		window.disposed = true
		h.retained[window] = nil
		window.close_callback, window.navigation_callback = nil, nil
	end
	local function new_window()
		local window = { visible = false, disposed = false, delete_on_close = false, deletes = 0 }
		h.windows[#h.windows + 1] = window
		h.retained[window] = true -- HSWebViewWindow_toLua stores its own udRef.
		for _, name in ipairs({ "windowTitle", "windowStyle", "shadow", "allowTextEntry",
			"allowGestures", "level", "html" }) do
			window[name] = function(self) assert(not self.disposed); return self end
		end
		function window:deleteOnClose(value)
			assert(not self.disposed)
			if h.policy_refuses == "throw" then error("native deleteOnClose refusal") end
			if h.policy_refuses == "false" then return false end
			if h.policy_refuses == "nil" then return nil end
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
