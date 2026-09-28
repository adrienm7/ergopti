--- tests/unit/modules/shortcuts/test_text_case_vectors.lua

--- ==============================================================================
--- MODULE: Selection Case Actions Replay the Shared Vectors (macOS)
--- DESCRIPTION:
--- Drives the production case actions of modules/shortcuts/actions/text.lua
--- through their copy stage with a stubbed pasteboard, and compares the text
--- they put back on the clipboard with _shared/tests/corpus/text_case/vectors.json,
--- the corpus the Linux and Windows suites replay too.
---
--- The toggles used string.upper, string.lower and a %l pattern, which work on
--- bytes: é, à and ç were never converted, so "élève à ça" came back as
--- "éLèVE à çA". The explicit selection_uppercase / selection_lowercase /
--- selection_titlecase actions did not exist.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local CORPUS = helpers.shared("tests/corpus/text_case/vectors.json")

--- The action each corpus field is produced by.
local ACTION_BY_FIELD = {
	upper = "selection_uppercase",
	lower = "selection_lowercase",
	title = "selection_titlecase",
	toggle_upper = "toggle_uppercase",
	toggle_title = "toggle_titlecase",
}
-- The toggles first: they are the actions that already existed, so the first
-- assertion to fail on the byte-level code names the conversion defect itself.
local FIELD_ORDER = { "toggle_upper", "toggle_title", "upper", "lower", "title" }

--- @return table The decoded corpus.
local function read_corpus()
	local fh = assert(io.open(CORPUS, "r"), "cannot open " .. CORPUS)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), "the text-case corpus is not valid JSON")
end

--- Whether a vector applies to the macOS driver.
--- @param vector table
--- @return boolean
local function applies_here(vector)
	if vector.drivers == nil then return true end
	for _, driver in ipairs(vector.drivers) do
		if driver == "hs" then return true end
	end
	return false
end

--- Runs one text action on `selected` through the copy stage and returns the
--- text the action wrote to the clipboard for pasting.
--- @param action_name string Public function of the text module.
--- @param selected string What Cmd+C put on the clipboard.
--- @return string|nil written
local function transformed_by(action_name, selected)
	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	local written = nil
	hs_stub.pasteboard = {
		getContents = function() return selected end,
		setContents = function(value) written = value; return true end,
		clearContents = function() return true end,
		readAllData = function() return { ["public.utf8-plain-text"] = "USER_CLIPBOARD" } end,
		writeAllData = function() return true end,
	}
	_G.hs = hs_stub
	package.loaded.hs = hs_stub
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.paths"] = nil
	package.loaded["infra.timings"] = nil
	package.loaded["adapters.synthetic_input"] = {
		emit_key_stroke = function() return true end,
		emit_key_strokes = function() return true end,
		begin = function() return {} end,
		begin_batch = function(tx) return { tx = tx } end,
		keyStroke = function() return true end,
		dispatch = function() return true end,
		seal = function() return true end,
		cancel = function() return true end,
	}
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["modules.shortcuts.actions.text"] = nil
	local Text = require("modules.shortcuts.actions.text")
	helpers.assert_eq(type(Text[action_name]), "function",
		"text actions must expose " .. action_name)
	helpers.assert_true(Text[action_name]() == true, action_name .. " must start its transform")
	-- Timer 1 is the ownership failsafe; timer 2 is the copy stage, which reads
	-- the selection, transforms it and writes the result for the paste.
	local timers = hs_stub.timer.__timers
	helpers.assert_true(#timers >= 2, action_name .. " must arm its copy stage")
	timers[2]:fire()
	return written
end

helpers.describe("selection case actions replay the shared text-case corpus", function()
	local corpus = read_corpus()

	helpers.it("the corpus holds vectors for this driver", function()
		local applicable = 0
		for _, vector in ipairs(corpus.vectors) do
			if applies_here(vector) then applicable = applicable + 1 end
		end
		helpers.assert_true(applicable >= 10,
			"expected at least 10 macOS vectors, found " .. applicable)
	end)

	for _, vector in ipairs(corpus.vectors) do
		if applies_here(vector) then
			helpers.it("case vector '" .. vector.id .. "'", function()
				local checked = 0
				for _, field in ipairs(FIELD_ORDER) do
					if vector[field] ~= nil then
						local action_name = ACTION_BY_FIELD[field]
						helpers.assert_eq(transformed_by(action_name, vector.input), vector[field],
							vector.id .. ": " .. action_name)
						checked = checked + 1
					end
				end
				helpers.assert_eq(checked, #FIELD_ORDER,
					vector.id .. " must state every field")
			end)
		end
	end
end)
