--- tests/unit/ui/test_prompt_editor_native_boundaries.lua

--- ==============================================================================
--- MODULE: Prompt Editor Native Boundary Regressions
--- DESCRIPTION:
--- Drives native script results and exact window cleanup through the public editor.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_editor(callback)
	local previous_hs = rawget(_G, "hs")
	local ok, err = xpcall(function()
		helpers.with_fresh_modules({
			"ui.prompt_editor", "ui.ui_builder", "infra.logger", "infra.paths", "infra.i18n",
			"hs", "tests.stubs.hs",
			"infra.deferred_work",
		}, function()
			local hs_stub = require("tests.stubs.hs")
			hs_stub.__reset()
			_G.hs = hs_stub
			local state = { views = {}, bridges = {}, errors = {}, focuses = 0, deletes = 0 }
			hs_stub.webview.usercontent.new = function()
				local bridge = {}
				function bridge:setCallback(fn)
					if state.bind_throws then error("native bridge bind refused") end
					self.callback = fn
					return self
				end
				state.bridges[#state.bridges + 1] = bridge
				return bridge
			end
			local logger = helpers.make_logger_stub()
			logger.error = function(_, message, ...)
				state.errors[#state.errors + 1] = string.format(message, ...)
			end
			package.loaded["infra.logger"] = logger
			package.loaded["infra.paths"] = { shared = function() return "/shared/prompt_editor" end }
			package.loaded["infra.i18n"] = { get = function(key) return key end }
			package.loaded["ui.ui_builder"] = {
				get_app_geometry = function()
					if state.geometry_throws then error("geometry refused") end
					return { width = 640, height = 480 }
				end,
				get_centered_frame = function()
					if state.frame_throws then error("screen geometry refused") end
					return {}
				end,
				force_focus = function() state.focuses = state.focuses + 1; return true end,
				show_webview = function(options)
					if state.show_throws then error("native construction refused") end
					local view = { options = options, scripts = {} }
					function view:evaluateJavaScript(script, completion)
						self.scripts[#self.scripts + 1] = script
						state.completion = completion
						if state.eval_mode == "raise" then error("private prompt payload") end
						if state.eval_mode == "nil" then return nil end
						if state.eval_mode == "false" then return false end
						return self
					end
					function view:delete()
						state.deletes = state.deletes + 1
						if state.on_delete then state.on_delete(self) end
						if state.delete_throws then error("native delete refused") end
						self.deleted = true
						return nil
					end
					state.views[#state.views + 1] = view
					if options.on_webview_created then options.on_webview_created(view) end
					if state.after_create then state.after_create(view) end
					return view
				end,
			}
			callback(require("ui.prompt_editor"), state, hs_stub)
		end)
	end, debug.traceback)
	_G.hs = previous_hs
	if not ok then error(err, 0) end
end

helpers.describe("prompt editor native boundaries", function()
	helpers.it("(prompt-editor-construction-owner) revokes deferred native focus when cleanup begins", function()
		with_editor(function(editor, state)
			local pending = {}
			package.loaded["infra.deferred_work"] = { after = function(_, callback)
				pending[#pending + 1] = callback
				return true
			end }
			local real_builder = assert(loadfile("ui/ui_builder.lua"))()
			package.loaded["ui.ui_builder"].force_focus = real_builder.force_focus
			helpers.assert_true(editor.open({ id = "A" }, function() end))
			local reads = 0
			state.views[1].hswindow = function() reads = reads + 1; return nil end
			helpers.assert_true(editor.open({ id = "B" }, function() end))
			helpers.assert_eq(#pending, 1)
			state.delete_throws = true
			helpers.assert_eq(editor.close(), false)
			local before = reads
			pending[1]()
			helpers.assert_eq(reads, before, "the real focus retry must not inspect a retired native window")
			helpers.assert_eq(#pending, 1, "retired focus must not reschedule itself")
		end)
	end)

	for _, mode in ipairs({ "bind", "show", "geometry", "frame" }) do
		helpers.it("(prompt-editor-construction-owner) rolls back " .. mode .. " exceptions before retry", function()
			with_editor(function(editor, state)
				state[mode .. "_throws"] = true
				local ok, result = pcall(editor.open, { id = "A" }, function() end)
				helpers.assert_true(ok, "native construction exceptions must become explicit failure")
				helpers.assert_eq(result, false)
				helpers.assert_eq(#state.errors, 1)
				state[mode .. "_throws"] = false
				helpers.assert_true(editor.open({ id = "B" }, function() end))
				helpers.assert_eq(#state.views, 1, "retry must create a real native window, not rebind an empty owner")
			end)
		end)
	end

	helpers.it("(prompt-editor-construction-owner) retains a candidate when setup and deletion both fail", function()
		with_editor(function(editor, state)
			state.after_create = function() error("native setup refused after construction") end
			state.delete_throws = true
			local ok, result = pcall(editor.open, { id = "A" }, function() end)
			helpers.assert_true(ok)
			helpers.assert_eq(result, false)
			helpers.assert_eq(state.deletes, 1)
			state.after_create = nil
			helpers.assert_eq(editor.open({ id = "B" }, function() end), false)
			helpers.assert_eq(#state.views, 1)
			state.delete_throws = false
			helpers.assert_true(editor.open({ id = "C" }, function() end))
			helpers.assert_true(state.views[1].deleted)
			helpers.assert_eq(#state.views, 2)
		end)
	end)

	helpers.it("(prompt-editor-construction-owner) refuses reentrant replacement until candidate publication", function()
		with_editor(function(editor, state)
			local nested
			state.after_create = function()
				nested = editor.open({ id = "B" }, function() end)
			end
			helpers.assert_true(editor.open({ id = "A" }, function() end))
			helpers.assert_eq(nested, false)
			helpers.assert_eq(#state.views, 1)
		end)
	end)

	helpers.it("(prompt-editor-cleanup-owner) retires bridge and presentation before a failed close", function()
		with_editor(function(editor, state, hs_stub)
			local saves = 0
			helpers.assert_true(editor.open({ id = "A" }, function() saves = saves + 1 end))
			local view = state.views[1]
			view.options.on_navigation("didFinishNavigation")
			local context = hs_stub.json.decode(view.scripts[1]:match("^init%((.*)%)$"))
			state.delete_throws = true
			helpers.assert_eq(editor.close(), false)
			view.options.on_navigation("didFinishNavigation")
			state.bridges[1].callback({ body = {
				action = "save", edit_id = context.edit_id, epoch = context.epoch,
				name = "retired", prompt = "retired",
			} })
			helpers.assert_eq(saves, 0, "an ambiguous native window owns cleanup, never persistence")
			helpers.assert_eq(#view.scripts, 1, "late navigation must not initialize a retired native window")
			helpers.assert_eq(editor.open({ id = "B" }, function() end), false)
			helpers.assert_eq(#state.views, 1)
			helpers.assert_eq(state.focuses, 0)
			state.delete_throws = false
			helpers.assert_true(editor.open({ id = "B" }, function() end))
			helpers.assert_true(view.deleted)
			helpers.assert_eq(#state.views, 2)
		end)
	end)

	helpers.it("(prompt-editor-cleanup-owner) refuses reentrant open during ambiguous native deletion", function()
		with_editor(function(editor, state)
			helpers.assert_true(editor.open({ id = "A" }, function() end))
			local reopened
			state.on_delete = function(view)
				view.options.on_close()
				reopened = editor.open({ id = "B" }, function() end)
			end
			state.delete_throws = true
			helpers.assert_eq(editor.close(), false)
			helpers.assert_eq(reopened, false, "native cleanup must not surrender singleton ownership mid-delete")
			helpers.assert_eq(#state.views, 1)
			helpers.assert_eq(state.deletes, 1, "reentry must not recursively delete the same native object")
			state.on_delete = nil
			state.delete_throws = false
			helpers.assert_true(editor.close())
			helpers.assert_true(state.views[1].deleted)
			helpers.assert_true(editor.open({ id = "C" }, function() end))
			helpers.assert_eq(#state.views, 2)
		end)
	end)

	helpers.it("(prompt-editor-cleanup-owner) retains a window with an unavailable delete method for retry", function()
		with_editor(function(editor, state)
			helpers.assert_true(editor.open({ id = "A" }, function() end))
			local view = state.views[1]
			local delete = view.delete
			view.delete = nil
			helpers.assert_eq(editor.close(), false)
			helpers.assert_eq(editor.open({ id = "B" }, function() end), false)
			helpers.assert_eq(#state.views, 1)
			helpers.assert_eq(#view.scripts, 0)
			view.delete = delete
			helpers.assert_true(editor.close())
			helpers.assert_true(view.deleted)
		end)
	end)

	for _, mode in ipairs({ "raise", "nil" }) do
		helpers.it("(prompt-editor-javascript-boundary) reports encoding " .. mode .. " without native submission", function()
			with_editor(function(editor, state, hs_stub)
				helpers.assert_true(editor.open({ id = "A" }, function() end))
				hs_stub.json.encode = function()
					if mode == "raise" then error("private prompt payload") end
					return nil
				end
				state.views[1].options.on_navigation("didFinishNavigation")
				helpers.assert_eq(#state.errors, 1)
				helpers.assert_contains(state.errors[1], "encoding failed")
				helpers.assert_eq(#state.views[1].scripts, 0)
				helpers.assert_eq(state.errors[1]:find("private prompt payload", 1, true), nil)
			end)
		end)
	end

	helpers.it("(prompt-editor-javascript-boundary) does not focus a context retired during submission", function()
		with_editor(function(editor, state)
			helpers.assert_true(editor.open({ id = "A" }, function() end))
			state.views[1].evaluateJavaScript = function(self)
				helpers.assert_true(editor.close())
				return self
			end
			helpers.assert_eq(editor.open({ id = "B" }, function() end), false)
			helpers.assert_eq(state.focuses, 0)
			helpers.assert_eq(state.deletes, 1)
		end)
	end)

	for _, mode in ipairs({ "raise", "nil", "false", "async", "success" }) do
		helpers.it("(prompt-editor-javascript-boundary) observes " .. mode .. " without exposing the prompt", function()
			with_editor(function(editor, state)
				helpers.assert_true(editor.open({ id = "A", raw_prompt = "private prompt payload" }, function() end))
				state.eval_mode = mode
				local view = state.views[1]
				view.options.on_navigation("didFinishNavigation")
				if mode == "async" then
					helpers.assert_type(state.completion, "function", "native execution errors need an observed completion")
					state.completion(nil, { message = "private prompt payload" })
					state.completion(nil, { message = "private prompt payload" })
				else
					view.options.on_navigation("didFinishNavigation")
				end
				helpers.assert_eq(#state.errors, mode == "success" and 0 or 1)
				for _, message in ipairs(state.errors) do
					helpers.assert_eq(message:find("private prompt payload", 1, true), nil)
				end
				if mode == "raise" or mode == "nil" or mode == "false" then
					helpers.assert_eq(editor.open({ id = "B" }, function() end), false,
						"rebind cannot report success when the native view refuses its context")
					helpers.assert_eq(state.focuses, 0)
				end
			end)
		end)
	end
end)
