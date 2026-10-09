--- tests/unit/ui/test_hotstring_editor_javascript.lua

--- ==============================================================================
--- MODULE: Hotstring Editor JavaScript Boundaries
--- DESCRIPTION:
--- Observes native submission and completion failures without exposing hotstrings.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_editor = require("tests.support.hotstring_editor_fixture").with_editor

helpers.describe("hotstring editor JavaScript failures", function()
	for _, route in ipairs({ "ready", "update" }) do
		for _, mode in ipairs({ "throw", "nil", "false", "async", "success", "encode_throw", "encode_nil" }) do
			helpers.it("observes " .. route .. " " .. mode .. " (hotstring-editor-javascript)", function()
				with_editor(function(editor, state)
					helpers.assert_true(editor.open())
					state.eval_mode = mode
					state.encode_mode = mode:match("^encode_(.*)$")
					local function dispatch()
						if route == "ready" then state.callbacks[1]({ body = { action = "ready" } })
						else editor.set_trigger_char("private content") end
					end
					dispatch()
					if mode == "async" then
						helpers.assert_type(state.completion, "function")
						state.completion(nil, { message = "private content" })
						state.completion(nil, { message = "private content" })
					elseif mode == "success" then
						helpers.assert_type(state.completion, "function")
						state.completion(true, nil)
						dispatch()
					else dispatch() end
					helpers.assert_eq(#state.errors, mode == "success" and 0 or 1)
					helpers.assert_eq(state.views[1].javascript, state.encode_mode and 0 or (mode == "async" and 1 or 2))
					helpers.assert_eq(table.concat(state.errors):find("private content", 1, true), nil)
				end)
			end)
		end
	end

	helpers.it("fences encoding reentry (hotstring-editor-javascript)", function()
		with_editor(function(editor, state)
			helpers.assert_true(editor.open())
			state.on_encode = function() editor.close() editor.open() end
			editor.set_trigger_char("private content")
			helpers.assert_eq(#state.views, 2)
			helpers.assert_eq(state.views[1].javascript, 0)
			helpers.assert_eq(state.views[2].javascript, 0)
		end)
	end)

	helpers.it("late completion cannot mutate a successor (hotstring-editor-javascript)", function()
		with_editor(function(editor, state)
			helpers.assert_true(editor.open())
			state.callbacks[1]({ body = { action = "ready" } })
			local completion = state.completion
			helpers.assert_type(completion, "function")
			editor.close()
			editor.open()
			completion(nil, { message = "private content" })
			helpers.assert_eq(#state.errors, 1)
			helpers.assert_eq(state.views[2].javascript, 0)
			helpers.assert_eq(state.views[2].deletes, 0)
			helpers.assert_eq(state.writes, 0)
		end)
	end)
end)
