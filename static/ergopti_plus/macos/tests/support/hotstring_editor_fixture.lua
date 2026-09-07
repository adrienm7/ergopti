--- tests/support/hotstring_editor_fixture.lua

--- ==============================================================================
--- MODULE: Hotstring Editor Test Fixture
--- DESCRIPTION:
--- Loads an isolated real editor with observable native and persistence boundaries.
--- No fixture state survives a call.
--- ==============================================================================

--- Runs one isolated real editor without filesystem side effects.
--- @param test function Behavioral assertions.
local function with_editor(test)
	local loaded, original_hs = {}, _G.hs
	for name, value in pairs(package.loaded) do loaded[name] = value end
	local state = {
		callbacks = {}, views = {}, options = {}, writes = 0, reloads = 0,
		errors = {}, notifications = 0,
	}
	local ok, err = xpcall(function()
		package.loaded["infra.logger"] = {
			debug = function() end,
			error = function(_, message, ...)
				state.errors[#state.errors + 1] = string.format(message, ...)
				if state.on_error then state.on_error() end
			end,
			callback = function(_, _, callback, ...) return pcall(callback, ...) end,
		}
		package.loaded["infra.paths"] = { shared = function(path) return "/virtual/" .. path end }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.notifications"] = { notify = function()
			state.notifications = state.notifications + 1
		end }
		package.loaded["adapters.file_system"] = { read_with_status = function() return "source", "ok" end }
		package.loaded["infra.toml.reader"] = {
			parse = function() return { sections_order = {}, sections = {} }, true end,
		}
		package.loaded["infra.toml.writer"] = { write_if_unchanged = function(_, document, snapshot)
			state.last_written = document
			state.last_snapshot = snapshot
			state.writes = state.writes + 1
			if state.on_write then state.on_write() end
			return true, nil, "source"
		end }
		_G.hs = { json = { encode = function()
			if state.on_encode then state.on_encode() end
			if state.encode_mode == "throw" then error("private content") end
			if state.encode_mode == "nil" then return nil end
			return "{}"
		end }, webview = {
			windowMasks = {}, usercontent = { new = function()
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
					if state.eval_mode == "throw" then error("private content") end
					if state.eval_mode == "nil" then return nil end
					if state.eval_mode == "false" then return false end
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
		package.loaded["ui.hotstring_editor"] = nil
		local editor = require("ui.hotstring_editor")
		editor.init("/virtual/source.toml", { reload_toml = function()
			state.reloads = state.reloads + 1
			return true
		end })
		test(editor, state)
	end, debug.traceback)
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	_G.hs = original_hs
	if not ok then error(err, 0) end
end

return { with_editor = with_editor }
