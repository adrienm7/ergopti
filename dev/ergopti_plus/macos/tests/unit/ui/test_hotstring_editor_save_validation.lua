--- tests/unit/ui/test_hotstring_editor_save_validation.lua

--- ==============================================================================
--- MODULE: Hotstring Editor Save Validation
--- DESCRIPTION:
--- Malformed native messages cannot erase or partially replace a valid document.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_editor = require("tests.support.hotstring_editor_fixture").with_editor

--- Produces the same document shape emitted by the shared frontend.
--- @return table document Fresh valid save payload.
local function document()
	return { sections_order = { "personal" }, sections = { personal = {
		description = "Private section", entries = { { trigger = "secret", output = "private content" } },
	} } }
end

local invalid = {
	{ "missing payload", function() return nil end },
	{ "false payload", function() return false end },
	{ "text payload", function() return "private content" end },
	{ "empty object", function() return {} end },
	{ "missing order", function(d) d.sections_order = nil return d end },
	{ "missing sections", function(d) d.sections = nil return d end },
	{ "sparse order", function(d) d.sections_order = { [2] = "personal" } return d end },
	{ "invalid name", function(d) d.sections_order[1] = {} return d end },
	{ "duplicate name", function(d) d.sections_order[2] = "personal" return d end },
	{ "missing section", function(d) d.sections.personal = nil return d end },
	{ "unlisted section", function(d) d.sections_order = {} return d end },
	{ "missing entries", function(d) d.sections.personal.entries = nil return d end },
	{ "sparse entries", function(d) d.sections.personal.entries[3] = { trigger = "x", output = "y" } return d end },
	{ "invalid entry", function(d) d.sections.personal.entries[1] = false return d end },
	{ "invalid trigger", function(d) d.sections.personal.entries[1].trigger = false return d end },
	{ "invalid output", function(d) d.sections.personal.entries[1].output = {} return d end },
	{ "invalid flag", function(d) d.sections.personal.entries[1].is_word = "false" return d end },
	{ "invalid priority", function(d) d.sections.personal.entries[1].priority = math.huge return d end },
	{ "invalid description", function(d) d.sections.personal.description = false return d end },
	{ "mapped entry sequence", function(d) d.sections.personal.entries.extra = {} return d end },
}
for _, flag in ipairs({ "auto_expand", "is_case_sensitive", "final_result", "is_case_sensitive_strict" }) do
	invalid[#invalid + 1] = { "invalid " .. flag, function(d) d.sections.personal.entries[1][flag] = "false" return d end }
end

helpers.describe("hotstring editor malformed saves", function()
	for _, case in ipairs(invalid) do
		helpers.it("rejects " .. case[1] .. " before persistence (hotstring-save-validation)", function()
			with_editor(function(editor, state)
				helpers.assert_true(editor.open())
				local message = { body = { action = "save", data = case[2](document()) } }
				state.callbacks[1](message)
				helpers.assert_eq(state.writes, 0, "reject the entire document before any writer can discard invalid fields")
				helpers.assert_eq(state.reloads, 0)
				helpers.assert_eq(#state.errors, 1)
				helpers.assert_eq(state.notifications, 1)
				state.callbacks[1](message)
				helpers.assert_eq(#state.errors, 1, "repeated malformed traffic must remain bounded")
				helpers.assert_eq(table.concat(state.errors):find("private content", 1, true), nil)
				state.callbacks[1]({ body = { action = "save", data = document() } })
				helpers.assert_eq(state.writes, 1, "a valid retry must remain writable")
				helpers.assert_eq(state.reloads, 1)
			end)
		end)
	end

	helpers.it("accepts an explicitly empty document (hotstring-save-validation)", function()
		with_editor(function(editor, state)
			helpers.assert_true(editor.open())
			state.callbacks[1]({ body = { action = "save", data = { sections_order = {}, sections = {} } } })
			helpers.assert_eq(state.writes, 1)
			helpers.assert_eq(state.reloads, 1)
			helpers.assert_eq(#state.errors, 0)
		end)
	end)

	helpers.it("preserves valid fields and separators (hotstring-save-validation)", function()
		with_editor(function(editor, state)
			helpers.assert_true(editor.open())
			local payload = document()
			payload.sections_order = { "-", "personal", "-" }
			local entry = payload.sections.personal.entries[1]
			entry.is_word, entry.auto_expand, entry.is_case_sensitive = false, true, false
			entry.final_result, entry.is_case_sensitive_strict, entry.priority = true, false, 75
			state.callbacks[1]({ body = { action = "save", data = payload } })
			helpers.assert_eq(state.writes, 1)
			helpers.assert_eq(state.last_written.sections.personal.entries[1], entry)
			helpers.assert_eq(state.last_written.sections_order[3], "-")
			helpers.assert_eq(state.last_snapshot.content, "source")
		end)
	end)

	helpers.it("does not notify a successor opened by the diagnostic sink (hotstring-save-validation)", function()
		with_editor(function(editor, state)
			helpers.assert_true(editor.open())
			state.on_error = function() editor.close() editor.open() end
			state.callbacks[1]({ body = { action = "save" } })
			helpers.assert_eq(#state.callbacks, 2)
			helpers.assert_eq(state.notifications, 0)
			helpers.assert_eq(state.writes, 0)
		end)
	end)
end)
