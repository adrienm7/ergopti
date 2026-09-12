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

local with_editor = require("tests.support.hotstring_editor_fixture").with_editor

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
