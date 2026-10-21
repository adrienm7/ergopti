--- tests/support/download_window_fixture.lua

--- ==============================================================================
--- MODULE: Download Window Native Test Fixture
--- DESCRIPTION:
--- Shares observable WebView behavior without retaining state between test cases.
--- ==============================================================================

--- Creates native overrides and observations for one isolated window scenario.
--- @return table overrides Native overrides for helpers.load_with_stubs.
--- @return function get_evaluated Recorded JavaScript submissions.
--- @return function fire_navigation Completion of the latest native navigation.
--- @return table state Native acquisition and deletion observations.
local function make_webview_overrides()
	local evaluated = {}
	local nav_callback = nil
	local state = {creates = 0, delete_throws = false, deletes = 0}
	local overrides = {
		webview = {
			new = function()
				state.creates = state.creates + 1
				local wv
				wv = {
					hswindow           = function(_self) return nil end,
					bringToFront       = function(self) return self end,
					frame              = function(_self) return { x = 0, y = 0, w = 460, h = 380 } end,
					evaluateJavaScript = function(self, code)
						evaluated[#evaluated + 1] = code
						return self
					end,
					delete             = function(_self)
						state.deletes = state.deletes + 1
						if state.delete_throws then error("synthetic download window delete refusal") end
						setmetatable(_self, nil)
					end,
					navigationCallback = function(self, fn) nav_callback = fn; return self end,
					windowCallback     = function(self, fn) self.close_callback = fn; return self end,
					windowTitle        = function(self) return self end,
					windowStyle        = function(self) return self end,
					level              = function(self) return self end,
					allowTextEntry     = function(self) return self end,
					allowGestures      = function(self) return self end,
					shadow             = function(self) return self end,
					allowNewWindows    = function(self, value)
						if value == nil then return self.allow_new_windows ~= false end
						assert(type(value) == "boolean", "allowNewWindows expects a boolean")
						self.allow_new_windows = value
						return self
					end,
					deleteOnClose      = function(self, value)
						if value == nil then return self.delete_on_close == true end
						self.delete_on_close = value
						return self
					end,
					html               = function(self) return self end,
					show               = function(self) return self end,
				}
				setmetatable(wv, {})
				return wv
			end,
			usercontent = {
				new = function(_name) return { setCallback = function(self, _fn) return self end } end,
			},
			windowMasks = {},
		},
		screen = {
			mainScreen = function()
				return { frame = function() return { x = 0, y = 0, w = 1920, h = 1080 } end }
			end,
		},
	}
	return overrides,
		function() return evaluated end,
		function() if nav_callback then nav_callback("didFinishNavigation") end end,
		state
end

return { make_webview_overrides = make_webview_overrides }
