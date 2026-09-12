--- tests/support/hotstrings_config_window_fixture.lua

--- ==============================================================================
--- MODULE: Hotstrings Configuration Window Test Fixture
--- DESCRIPTION:
--- Loads an isolated real controller with observable native owners and failures.
--- No fixture state survives a call.
--- ==============================================================================

--- Runs an isolated controller with observable native owners.
--- @param test function Behavioral assertions.
local function with_window(test)
	local loaded, original_hs = {}, _G.hs
	for name, value in pairs(package.loaded) do loaded[name] = value end
	local state = { callbacks = {}, views = {}, options = {}, writes = 0, errors = {} }
	local ok, err = xpcall(function()
		package.loaded["infra.logger"] = {
			debug = function() end, info = function() end,
			error = function(_, message, ...)
				state.errors[#state.errors + 1] = string.format(message, ...)
				if state.on_error then state.on_error() end
			end,
			callback = function(_, _, callback, ...) return pcall(callback, ...) end,
		}
		package.loaded["infra.paths"] = { shared = function(path) return "/virtual/" .. path end }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.fs_dir"] = { entries = function() return {} end }
		package.loaded["modules.keymap"] = {}
		package.loaded["modules.hotstrings.hotstrings_config"] = {
			set_override = function() state.writes = state.writes + 1 return true end,
			resolve = function() return {} end, get_toml_defaults = function() return {} end,
			get_user_override = function() return {} end, get_sections = function() return {} end,
		}
		_G.hs = { json = { encode = function()
			if state.on_encode then state.on_encode() end
			if state.encode_mode == "throw" then error("private payload") end
			if state.encode_mode == "nil" then return nil end
			return "{}"
		end }, webview = {
			usercontent = { new = function()
				return { setCallback = function(self, callback)
					if callback then state.callbacks[#state.callbacks + 1] = callback end
					return self
				end }
			end },
		} }
		package.loaded["ui.ui_builder"] = {
			get_app_geometry = function() return { width = 10, height = 10 } end,
			get_centered_frame = function() return {} end, force_focus = function() end,
			show_webview = function(options)
				if state.throw_before_create then error("injected factory entry failure") end
				local view = { deletes = 0, javascript = 0 }
				function view:delete()
					self.deletes = self.deletes + 1
					if state.refuse_delete then error("injected delete failure") end
				end
				function view:evaluateJavaScript(_, completion)
					self.javascript = self.javascript + 1
					state.completion = completion
					if state.eval_mode == "throw" then error("private payload") end
					if state.eval_mode == "nil" then return nil end
					if state.eval_mode == "false" then return false end
					if state.eval_mode == "sync_error" and completion then completion(nil, { message = "private payload" }) end
					if state.on_javascript then state.on_javascript() end
					return self
				end
				state.views[#state.views + 1] = view
				state.options[#state.options + 1] = options
				if options.on_webview_created then options.on_webview_created(view) end
				if state.throw_after_create then error("injected factory post-allocation failure") end
				if state.close_during_show then options.on_close() end
				return view
			end,
		}
		package.loaded["ui.hotstrings_config_window"] = nil
		test(require("ui.hotstrings_config_window"), state)
	end, debug.traceback)
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	_G.hs = original_hs
	if not ok then error(err, 0) end
end

return { with_window = with_window }
