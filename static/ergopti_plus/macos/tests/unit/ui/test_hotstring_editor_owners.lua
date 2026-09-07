--- tests/unit/ui/test_hotstring_editor_owners.lua

--- ==============================================================================
--- MODULE: Hotstring Editor Ownership Tests
--- DESCRIPTION:
--- Exercises the real editor through exact captured native session callbacks.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===================================
-- ===================================
-- ======= 1/ Native Ownership =======
-- ===================================
-- ===================================

--- Runs one isolated real editor without filesystem side effects.
--- @param test function Behavioral assertions.
local function with_editor(test)
	local loaded, original_hs = {}, _G.hs
	for name, value in pairs(package.loaded) do loaded[name] = value end
	local state = { callbacks = {}, views = {}, options = {}, writes = 0, reloads = 0 }
	local ok, err = xpcall(function()
		package.loaded["infra.logger"] = {
			debug = function() end, error = function() end,
			callback = function(_, _, callback, ...) return pcall(callback, ...) end,
		}
		package.loaded["infra.paths"] = { shared = function(path) return "/virtual/" .. path end }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.notifications"] = { notify = function() end }
		package.loaded["adapters.file_system"] = { read_with_status = function() return "source", "ok" end }
		package.loaded["infra.toml.reader"] = {
			parse = function() return { sections_order = {}, sections = {} }, true end,
		}
		package.loaded["infra.toml.writer"] = { write_if_unchanged = function()
			state.writes = state.writes + 1
			if state.on_write then state.on_write() end
			return true, nil, "source"
		end }
		_G.hs = { json = { encode = function() return "{}" end }, webview = {
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
				function view:evaluateJavaScript()
					self.javascript = self.javascript + 1
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

--- Delivers a well-formed empty document through a captured native callback.
--- @param callback function Captured bridge.
local function save(callback)
	callback({ body = { action = "save", data = { sections_order = {}, sections = {} } } })
end

helpers.describe("hotstring editor native owners", function()
	for _, phase in ipairs({ "before", "after" }) do
		helpers.it("construction exception " .. phase .. " allocation remains retryable (hotstring-editor-owner)", function()
			with_editor(function(editor, state)
				state["throw_" .. phase .. "_create"] = true
				helpers.assert_eq(editor.open(), false)
				if phase == "after" then helpers.assert_eq(state.views[1].deletes, 1) end
				state["throw_" .. phase .. "_create"] = false
				helpers.assert_eq(editor.close(), true)
				helpers.assert_eq(editor.open(), true)
			end)
		end)
	end
	helpers.it("retired bridges cannot save, initialize or close the successor (hotstring-editor-owner)", function()
		with_editor(function(editor, state)
			helpers.assert_eq(editor.open(), true)
			local old = state.callbacks[1]
			helpers.assert_eq(editor.close(), true)
			helpers.assert_eq(editor.open(), true)
			save(old)
			old({ body = { action = "ready" } })
			old({ body = { action = "close" } })
			helpers.assert_eq(state.writes, 0)
			helpers.assert_eq(state.views[2].javascript, 0)
			helpers.assert_eq(state.views[2].deletes, 0)
			save(state.callbacks[2])
			helpers.assert_eq(state.writes, 1)
			helpers.assert_eq(state.reloads, 1)
		end)
	end)

	helpers.it("refused deletion retains only cleanup authority (hotstring-editor-owner)", function()
		with_editor(function(editor, state)
			helpers.assert_eq(editor.open(), true)
			state.refuse_delete = true
			helpers.assert_eq(editor.close(), false)
			save(state.callbacks[1])
			helpers.assert_eq(state.writes, 0)
			helpers.assert_eq(editor.is_open(), false)
			state.refuse_delete = false
			helpers.assert_eq(editor.close(), true)
			helpers.assert_eq(state.views[1].deletes, 2)
		end)
	end)

	helpers.it("native close commits before focus callback opens a successor (hotstring-editor-owner)", function()
		with_editor(function(editor, state)
			helpers.assert_eq(editor.open(), true)
			local once = true
			editor.set_on_focus_change(function()
				if once then once = false editor.close() editor.open() end
			end)
			state.options[1].on_close()
			helpers.assert_eq(editor.is_open(), true)
			helpers.assert_eq(#state.views, 2)
			helpers.assert_eq(state.views[2].deletes, 0)
		end)
	end)

	helpers.it("a candidate closed during construction never becomes live (hotstring-editor-owner)", function()
		with_editor(function(editor, state)
			state.close_during_show = true
			helpers.assert_eq(editor.open(), false)
			helpers.assert_eq(editor.is_open(), false)
			save(state.callbacks[1])
			helpers.assert_eq(state.writes, 0)
		end)
	end)

	helpers.it("write completion cannot reload a successor session (hotstring-editor-owner)", function()
		with_editor(function(editor, state)
			helpers.assert_eq(editor.open(), true)
			state.on_write = function() editor.close() editor.open() end
			save(state.callbacks[1])
			helpers.assert_eq(state.writes, 1)
			helpers.assert_eq(state.reloads, 0)
			helpers.assert_eq(editor.is_open(), true)
		end)
	end)
end)
