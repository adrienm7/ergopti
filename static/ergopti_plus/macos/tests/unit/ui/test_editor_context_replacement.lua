--- tests/unit/ui/test_editor_context_replacement.lua

--- ==============================================================================
--- MODULE: Regression — singleton editor context replacement
--- DESCRIPTION:
--- Action and prompt editors are singleton windows, but every open request owns a
--- distinct target and callback. A second request must supersede the first, and
--- queued messages from the old context must never save or close the new one.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_editor(module_name, callback)
	local previous_hs = rawget(_G, "hs")
	local ok, err = xpcall(function()
		helpers.with_fresh_modules({
			module_name,
			"ui.ui_builder",
			"infra.logger",
			"infra.paths",
			"infra.i18n",
			"hs",
			"tests.stubs.hs",
		}, function()
			local state = {
				bridges = {},
				views = {},
				focuses = 0,
				deletes = 0,
				evaluations = {},
			}
			local hs_stub = require("tests.stubs.hs")
			hs_stub.__reset()
			hs_stub.webview.usercontent.new = function(name)
				local bridge = { name = name, callback = nil }
				function bridge:setCallback(fn)
					self.callback = fn
					return true
				end
				state.bridges[#state.bridges + 1] = bridge
				return bridge
			end
			_G.hs = hs_stub
			package.loaded["hs"] = hs_stub
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.paths"] = {
				shared = function(relative) return "/shared/" .. tostring(relative) end,
			}
			package.loaded["infra.i18n"] = {
				get = function(key) return key end,
			}
			package.loaded["ui.ui_builder"] = {
				get_app_geometry = function() return { width = 640, height = 480 } end,
				get_centered_frame = function(width, height)
					return { x = 0, y = 0, w = width, h = height }
				end,
				force_focus = function(view)
					state.focuses = state.focuses + 1
					state.focused_view = view
					return true
				end,
				show_webview = function(options)
					local view = { options = options, deleted = false }
					function view:evaluateJavaScript(script)
						state.evaluations[#state.evaluations + 1] = {
							view = self,
							script = script,
						}
						return true
					end
					function view:delete()
						self.deleted = true
						state.deletes = state.deletes + 1
						return true
					end
					state.views[#state.views + 1] = view
					return view
				end,
			}

			local editor = require(module_name)
			callback(editor, state, hs_stub)
		end)
	end, debug.traceback)
	_G.hs = previous_hs
	if not ok then error(err, 0) end
end

local function latest_init_payload(state, hs_stub)
	local evaluation = state.evaluations[#state.evaluations]
	helpers.assert_not_nil(evaluation, "the active editor must publish an init payload")
	local encoded = evaluation.script:match("^init%((.*)%)$")
	helpers.assert_not_nil(encoded, "the host must call the shared init(payload) API")
	local payload = hs_stub.json.decode(encoded)
	helpers.assert_type(payload, "table", "the init payload must be valid JSON")
	return payload
end

helpers.describe("action picker: a second open supersedes the first context", function()
	helpers.it("drops a late confirmation from A and invokes only callback B", function()
		with_editor("ui.action_picker", function(picker, state)
			local confirmed_a, confirmed_b = {}, {}
			picker.open({ title = "Target A", items = {} }, function(id)
				confirmed_a[#confirmed_a + 1] = id
			end)
			local bridge_a = state.bridges[1]
			helpers.assert_type(bridge_a.callback, "function")

			picker.open({ title = "Target B", items = {} }, function(id)
				confirmed_b[#confirmed_b + 1] = id
			end)
			local bridge_b = state.bridges[2]
			helpers.assert_not_nil(bridge_b,
				"the second target must own a fresh native bridge session")
			helpers.assert_eq(#state.views, 2,
				"the second target must replace the first picker window")
			helpers.assert_true(state.views[1].deleted,
				"the superseded picker must be torn down before B is published")
			state.views[1].options.on_close()

			bridge_a.callback({ body = { action = "confirm", id = "stale-a" } })
			helpers.assert_eq(#confirmed_a, 0,
				"a queued message from the superseded bridge must not invoke callback A")
			helpers.assert_eq(#confirmed_b, 0)
			helpers.assert_true(not state.views[2].deleted,
				"a stale A message must not close B's window")

			bridge_b.callback({ body = { action = "confirm", id = "picked-b" } })
			helpers.assert_eq(#confirmed_a, 0)
			helpers.assert_eq(#confirmed_b, 1)
			helpers.assert_eq(confirmed_b[1], "picked-b")
			helpers.assert_true(state.views[2].deleted,
				"the current confirmation must close its own window")
		end)
	end)
end)

helpers.describe("prompt editor: messages are bound to an immutable context", function()
	helpers.it("settles one create context before a re-entrant save can replay it", function()
		with_editor("ui.prompt_editor", function(editor, state, hs_stub)
			local bridge
			local save_message
			local saved_profiles = {}

			editor.open(nil, function(saved)
				saved_profiles[#saved_profiles + 1] = saved
				if #saved_profiles == 1 then
					bridge.callback({ body = save_message })
				end
			end)
			bridge = state.bridges[1]
			local view = state.views[1]
			view.options.on_navigation("didFinishNavigation")
			local context = latest_init_payload(state, hs_stub)
			save_message = {
				action = "save",
				edit_id = context.edit_id,
				epoch = context.epoch,
				name = "Created once",
				batch = false,
				prompt = "Do this once",
			}

			bridge.callback({ body = save_message })

			helpers.assert_eq(#saved_profiles, 1,
				"one create context must deliver at most one profile")
			helpers.assert_true(type(saved_profiles[1].id) == "string"
				and saved_profiles[1].id:match("^custom_%d+_%d+$") ~= nil,
				"the create context must own one generated profile id")
			helpers.assert_eq(state.deletes, 1,
				"the settled create context must close exactly once")
		end)
	end)

	helpers.it("rejects stale epochs and preserves a context opened by on_save", function()
		with_editor("ui.prompt_editor", function(editor, state, hs_stub)
			local saves_a, saves_b, saves_c = 0, 0, 0
			local profile_a = { id = "profile-a", label = "A", raw_prompt = "Prompt A" }
			local profile_b = { id = "profile-b", label = "B", raw_prompt = "Prompt B" }
			local profile_c = { id = "profile-c", label = "C", raw_prompt = "Prompt C" }

			editor.open(profile_a, function() saves_a = saves_a + 1 end)
			local bridge = state.bridges[1]
			local view = state.views[1]
			view.options.on_navigation("didFinishNavigation")
			local context_a = latest_init_payload(state, hs_stub)
			helpers.assert_eq(context_a.edit_id, "profile-a")
			helpers.assert_true(type(context_a.epoch) == "number" and context_a.epoch > 0,
				"the first display must own a positive epoch")

			editor.open(profile_b, function(saved)
				saves_b = saves_b + 1
				helpers.assert_eq(saved.id, "profile-b")
				editor.open(profile_c, function() saves_c = saves_c + 1 end)
			end)
			helpers.assert_eq(#state.views, 1,
				"prompt contexts should reuse the singleton webview")
			local context_b = latest_init_payload(state, hs_stub)
			helpers.assert_eq(context_b.edit_id, "profile-b")
			helpers.assert_true(context_b.epoch > context_a.epoch,
				"every open request must advance the immutable context epoch")

			bridge.callback({ body = {
				action = "save",
				edit_id = context_a.edit_id,
				epoch = context_a.epoch,
				name = "Stale A",
				batch = false,
				prompt = "stale",
			} })
			helpers.assert_eq(saves_a, 0)
			helpers.assert_eq(saves_b, 0)
			helpers.assert_eq(state.deletes, 0,
				"a stale save must neither persist nor close the current editor")

			bridge.callback({ body = {
				action = "save",
				edit_id = context_b.edit_id,
				epoch = context_b.epoch,
				name = "Saved B",
				batch = true,
				prompt = "saved-b",
			} })
			helpers.assert_eq(saves_a, 0)
			helpers.assert_eq(saves_b, 1)
			helpers.assert_eq(state.deletes, 0,
				"B's completion must not close context C opened re-entrantly by its callback")

			local context_c = latest_init_payload(state, hs_stub)
			helpers.assert_eq(context_c.edit_id, "profile-c")
			helpers.assert_true(context_c.epoch > context_b.epoch)
			bridge.callback({ body = {
				action = "cancel",
				edit_id = context_b.edit_id,
				epoch = context_b.epoch,
			} })
			helpers.assert_eq(state.deletes, 0,
				"a stale cancel must not close the re-entrant context")
			bridge.callback({ body = {
				action = "cancel",
				edit_id = context_c.edit_id,
				epoch = context_c.epoch,
			} })
			helpers.assert_eq(state.deletes, 1)
			helpers.assert_eq(saves_c, 0)

			local profile_d = { id = "profile-d", label = "D", raw_prompt = "Prompt D" }
			editor.open(profile_d, function() error("cancel must not save D") end)
			local bridge_d = state.bridges[2]
			local view_d = state.views[2]
			view_d.options.on_navigation("didFinishNavigation")
			local context_d = latest_init_payload(state, hs_stub)
			view.options.on_close()
			bridge.callback({ body = {
				action = "cancel",
				edit_id = context_c.edit_id,
				epoch = context_c.epoch,
			} })
			helpers.assert_eq(state.deletes, 1,
				"late native and bridge callbacks from the old window must leave D open")
			bridge_d.callback({ body = {
				action = "cancel",
				edit_id = context_d.edit_id,
				epoch = context_d.epoch,
			} })
			helpers.assert_eq(state.deletes, 2,
				"the new window must still accept its own current context")
		end)
	end)
end)
