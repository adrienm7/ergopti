--- tests/support/webview_recursive_close_fixture.lua

--- ==============================================================================
--- MODULE: Recursive Native WebView Close Fixture
--- DESCRIPTION:
--- Models the packaged libwebview.m close/GC cycle, including toLua creating a
--- fresh userdata after udRef was removed. This is distinct from treating a
--- second GC on the same consumed userdata as harmless. No Cocoa execution is
--- claimed by this portable model of pin 1469832361b4c3687ec7d589c1b4efe4d3b742ee.
--- ==============================================================================

--- Constructs native-shaped WebViews and independent reference observations.
--- @param h table Scenario state with deferred callbacks and retained windows.
--- @return function constructor
local function make_windows(h)
	local methods = {}
	local metatable = { __index = methods }
	local close, gc
	local function to_lua(state)
		if not state.udref then
			state.udref = setmetatable({ native = state }, metatable)
			h.retained[state] = true
		end
		return state.udref
	end
	close = function(state)
		h.notification_depth = h.notification_depth + 1
		state.visible = false
		if state.callback then state.callback("closing", to_lua(state)) end
		if state.delete_on_close and state.canary then
			-- windowWillClose:148 repushes self after userdata_gc:3049 removed
			-- udRef; toLua:2722 creates another valid userdata for the same window.
			if h.notification_depth >= 8 then
				h.errors[#h.errors + 1] = "C stack overflow"
			else gc(to_lua(state)) end
		end
		h.notification_depth = h.notification_depth - 1
	end
	gc = function(view)
		if getmetatable(view) == nil then return end
		local state = view.native
		setmetatable(view, nil)
		state.udref, state.callback = nil, nil
		close(state) -- native GC closes BEFORE destroying its canary/delegate.
		state.canary = false
		h.retained[state] = nil
	end
	for _, name in ipairs({ "windowTitle", "windowStyle", "shadow", "allowTextEntry",
		"allowGestures", "level", "html" }) do
		methods[name] = function(self) return self end
	end
	function methods:allowNewWindows(value)
		if value == nil then return self.native.allow_new_windows ~= false end
		assert(type(value) == "boolean", "allowNewWindows expects a boolean")
		self.native.allow_new_windows = value
		return self
	end
	function methods:deleteOnClose(value)
		if value == nil then return self.native.delete_on_close end
		self.native.policy_calls = (self.native.policy_calls or 0) + 1
		if h.policy_refuses == "throw" then error("native policy setter raised") end
		if h.policy_refuses == "false" then return false end
		if h.policy_refuses == "nil" then return nil end
		self.native.delete_on_close = value
		return self
	end
	function methods:windowCallback(callback) self.native.callback = callback; return self end
	function methods:navigationCallback(callback) self.native.navigation = callback; return self end
	function methods:show() self.native.visible = true; return self end
	function methods:hswindow() return { focus = function() end, raise = function() end } end
	function methods:user_close() close(self.native) end
	function methods:delete()
		local state = self.native
		state.deletes = state.deletes + 1
		if h.delete_refuses == "throw" then error("native delete raised before consumption") end
		if h.delete_refuses == "false" then return false end
		if state.visible then
			h.deferred[#h.deferred + 1] = function()
				close(state)
				-- fadeOut:257 looks up udRef after the callback, rather than
				-- retaining the original public delete() argument on its stack.
				if state.udref then gc(state.udref)
				else h.errors[#h.errors + 1] = "fade completion has no userdata reference" end
			end
		else close(state); gc(self) end
		if h.delete_after_consumption then error("native delete raised after consumption") end
	end
	return function()
		local state = { visible = false, delete_on_close = false, canary = true, deletes = 0 }
		local view = to_lua(state)
		h.windows[#h.windows + 1] = view
		return view
	end
end

return make_windows
