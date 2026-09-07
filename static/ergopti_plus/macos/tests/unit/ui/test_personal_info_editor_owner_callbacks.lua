--- tests/unit/ui/test_personal_info_editor_owner_callbacks.lua

--- ==============================================================================
--- MODULE: Personal Information Editor Callback Ownership
--- DESCRIPTION:
--- Retains real editor callbacks across native replacement and save reentry.
--- A predecessor must never save, populate, close, or orphan its successor.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs an isolated editor scenario with independently retained native callbacks.
--- @param scenario function Receives the real editor and native records.
local function with_editor(scenario)
	local keys = { "ui.personal_info_editor", "infra.logger", "infra.i18n",
		"infra.paths", "infra.deferred_work", "ui.ui_builder" }
	local saved, prior_hs = {}, _G.hs
	for _, key in ipairs(keys) do saved[key] = package.loaded[key] end
	local records = { windows = {}, bridges = {}, deferred = {}, errors = {} }
	local ok, err = xpcall(function()
		_G.hs = {
			json = { encode = function() return "{}" end },
			screen = { mainScreen = function() return { frame = function() return { w = 1440, h = 900 } end } end },
			webview = { windowMasks = { titled = 1, closable = 2 }, usercontent = {
				new = function() return { setCallback = function(_, callback)
					records.bridges[#records.bridges + 1] = callback
				end } end,
			} },
		}
		package.loaded["infra.logger"] = { debug = function() end, info = function() end,
			error = function(_, message, ...)
				records.errors[#records.errors + 1] = string.format(message, ...)
			end }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.paths"] = { shared = function() return "/virtual/shared" end }
		package.loaded["infra.deferred_work"] = { after = function(_, callback)
			records.deferred[#records.deferred + 1] = callback
			return true
		end }
		package.loaded["ui.ui_builder"] = {
			force_focus = function() return true end,
			get_app_geometry = function() return { width = 800, height = 600 } end,
			get_centered_frame = function(w, h) return { w = w, h = h } end,
			show_webview = function(options)
				local native = { options = options, deletes = 0, scripts = 0 }
				function native:delete()
					self.deletes = self.deletes + 1
					if self.delete_throws then error("injected native delete failure") end
					options.on_close()
					return self
				end
				function native:evaluateJavaScript(_, callback)
					self.scripts = self.scripts + 1
					self.js_callback = callback
					if self.eval_mode == "throw" then error("private field echoed by WebKit") end
					if self.eval_mode == "nil" then return nil end
					if self.eval_mode == "false" then return false end
					return self
				end
				records.windows[#records.windows + 1] = native
				if records.close_during_create then options.on_close() end
				if records.on_create then records.on_create(native) end
				return native
			end,
		}
		package.loaded["ui.personal_info_editor"] = nil
		scenario(require("ui.personal_info_editor"), records)
	end, debug.traceback)
	for _, key in ipairs(keys) do package.loaded[key] = saved[key] end
	_G.hs = prior_hs
	if not ok then error(err, 0) end
end

helpers.describe("personal editor exact callback owners", function()
	for _, boundary in ipairs({ "public close", "page cancel" }) do
		helpers.it("honours " .. boundary .. " during creation (personal-editor-construction-close)", function()
			with_editor(function(editor, records)
				records.on_create = function()
					if boundary == "public close" then editor.close()
					else records.bridges[1]({ body = { action = "cancel" } }) end
				end
				helpers.assert_eq(editor.open({}, function() return true end), false,
					"a close requested before factory return must revoke publication")
				helpers.assert_eq(records.windows[1].deletes, 1,
					"the returned candidate must be cleaned up exactly once")
				records.on_create = nil
				helpers.assert_true(editor.open({}, function() return true end))
				helpers.assert_eq(#records.windows, 2)
			end)
		end)
	end

	helpers.it("keeps current readiness and retryable saves functional (personal-editor-owner)", function()
		with_editor(function(editor, records)
			local attempts, commit = 0, false
			editor.open({}, function() attempts = attempts + 1; return commit end)
			local bridge, native = records.bridges[1], records.windows[1]
			bridge({ body = { action = "ready" } })
			helpers.assert_eq(native.scripts, 1)
			bridge({ body = { action = "save", values = {} } })
			helpers.assert_eq(attempts, 1)
			helpers.assert_eq(native.deletes, 0)
			commit = true
			bridge({ body = { action = "save", values = {} } })
			helpers.assert_eq(attempts, 2)
			helpers.assert_eq(native.deletes, 1)
		end)
	end)

	helpers.it("retains deletion retry without replaying committed saves (personal-editor-owner)", function()
		with_editor(function(editor, records)
			local saves = 0
			editor.open({}, function() saves = saves + 1; return true end)
			local native, bridge = records.windows[1], records.bridges[1]
			native.delete_throws = true
			bridge({ body = { action = "save", values = {} } })
			bridge({ body = { action = "save", values = {} } })
			helpers.assert_eq(saves, 1)
			native.delete_throws = false
			helpers.assert_true(editor.close())
			helpers.assert_eq(native.deletes, 2)
		end)
	end)

	helpers.it("does not publish a candidate closed during creation (personal-editor-owner)", function()
		with_editor(function(editor, records)
			records.close_during_create = true
			editor.open({}, function() return true end)
			records.close_during_create = false
			editor.open({}, function() return true end)
			helpers.assert_eq(#records.windows, 2, "a retired candidate must not occupy the singleton")
		end)
	end)

	helpers.it("reopens through exact cleanup after a failed close (personal-editor-owner)", function()
		with_editor(function(editor, records)
			editor.open({}, function() return true end)
			local old = records.windows[1]
			old.delete_throws = true
			helpers.assert_eq(editor.close(), false)
			helpers.assert_eq(editor.open({}, function() return true end), false)
			helpers.assert_eq(#records.windows, 1)
			old.delete_throws = false
			helpers.assert_true(editor.open({}, function() return true end))
			helpers.assert_eq(#records.windows, 2)
			records.bridges[2]({ body = { action = "ready" } })
			helpers.assert_eq(records.windows[2].scripts, 1,
				"reopening must restore a functional editor, not focus an inert owner")
		end)
	end)

	for _, action in ipairs({ "save", "cancel", "ready", "close", "navigation" }) do
		helpers.it("rejects retired " .. action .. " callbacks (personal-editor-owner)", function()
			with_editor(function(editor, records)
				editor.open({}, function() return true end)
				local old, old_bridge = records.windows[1], records.bridges[1]
				old.options.on_navigation("didFinishNavigation")
				helpers.assert_true(editor.close())
				local saves = 0
				editor.open({}, function() saves = saves + 1; return true end)
				local current = records.windows[2]
				if action == "close" then old.options.on_close()
				elseif action == "navigation" then records.deferred[1]()
				else old_bridge({ body = { action = action, values = { first_name = "stale" } } }) end
				helpers.assert_eq(saves, 0, "old page must not reach successor persistence")
				helpers.assert_eq(current.deletes, 0, "old callback must not close the successor")
				helpers.assert_eq(current.scripts, 0, "old readiness must not populate the successor")
				editor.open({}, function() return true end)
				helpers.assert_eq(#records.windows, 2, "old close must not orphan the current singleton")
			end)
		end)
	end

	helpers.it("does not close a successor opened by save (personal-editor-owner)", function()
		with_editor(function(editor, records)
			local saves = 0
			editor.open({}, function()
				saves = saves + 1
				helpers.assert_true(editor.close())
				editor.open({}, function() return true end)
				return true
			end)
			records.bridges[1]({ body = { action = "save", values = {} } })
			helpers.assert_eq(saves, 1)
			helpers.assert_eq(#records.windows, 2)
			helpers.assert_eq(records.windows[2].deletes, 0)
		end)
	end)

	helpers.it("does not close an editor rebound during save (personal-editor-owner)", function()
		with_editor(function(editor, records)
			local saves = 0
			editor.open({}, function()
				saves = saves + 1
				editor.open({}, function() return true end)
				return true
			end)
			records.bridges[1]({ body = { action = "save", values = {} } })
			helpers.assert_eq(saves, 1)
			helpers.assert_eq(#records.windows, 1)
			helpers.assert_eq(records.windows[1].deletes, 0,
				"the old save must not settle a newly rebound callback context")
		end)
	end)
end)

helpers.describe("personal editor JavaScript failure boundary", function()
	for _, mode in ipairs({ "throw", "nil", "false", "async" }) do
		helpers.it("reports " .. mode .. " without personal values (personal-editor-javascript)", function()
			with_editor(function(editor, records)
				editor.open({ first_name = "private field" }, function() return true end)
				local native, bridge = records.windows[1], records.bridges[1]
				native.eval_mode = mode
				bridge({ body = { action = "ready" } })
				if mode == "async" then
					helpers.assert_type(native.js_callback, "function")
					native.js_callback(nil, { message = "private field echoed by WebKit" })
					native.js_callback(nil, { message = "private field echoed by WebKit" })
				else bridge({ body = { action = "ready" } }) end
				helpers.assert_eq(#records.errors, 1, "one bounded diagnostic must expose the native failure")
				helpers.assert_true(records.errors[1]:find("private field", 1, true) == nil)
				helpers.assert_true(records.errors[1]:find("session=1", 1, true) ~= nil)
			end)
		end)
	end

	helpers.it("accepts a successful script completion (personal-editor-javascript)", function()
		with_editor(function(editor, records)
			editor.open({}, function() return true end)
			records.bridges[1]({ body = { action = "ready" } })
			local native = records.windows[1]
			helpers.assert_eq(native.scripts, 1)
			helpers.assert_type(native.js_callback, "function")
			native.js_callback(true, nil)
			helpers.assert_eq(#records.errors, 0)
		end)
	end)
end)
