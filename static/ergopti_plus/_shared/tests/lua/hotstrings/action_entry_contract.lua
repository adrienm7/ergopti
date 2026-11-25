--- _shared/tests/lua/hotstrings/action_entry_contract.lua

--- ==============================================================================
--- MODULE: Hotstring Action Entry Contract
--- DESCRIPTION:
--- Replays _shared/tests/corpus/hotstrings/action_entry_vectors.json on the
--- macOS and Linux runtimes: the action fields an entry carries or the refusal
--- that skips it, the edit before the action with the trigger erased or kept
--- as typed (end character included), and TOML lines through the shared reader
--- and matcher.
---
--- ROOT CAUSE ENCODED:
--- A hotstring could only type text: no entry could run an action or a
--- workflow, and nothing kept the typed text when the user wanted it kept.
--- ==============================================================================

local Json = require("core.text.engine.json")
local ActionEntry = require("hotstrings.engine.matcher.action_entry")
local Reader = require("core.text.engine.toml_codec.reader")
local Matcher = require("hotstrings.engine.matcher")

local M = {}

--- Replaces JSON null tokens by nil, deeply.
--- @param value any
--- @return any
local function plain(value)
	if Json.is_null(value) then return nil end
	if type(value) ~= "table" then return value end
	local out = {}
	for key, item in pairs(value) do out[key] = plain(item) end
	return out
end

--- @param s string
--- @return table codepoints
local function codepoints(s)
	local cps = {}
	for ch in s:gmatch("[\1-\127\194-\244][\128-\191]*") do cps[#cps + 1] = ch end
	return cps
end

--- Registers the replay.
--- @param helpers table Driver test API.
--- @param shared_path function Driver resolver for a path under _shared/.
function M.register(helpers, shared_path)
	local file = assert(io.open(shared_path("tests/corpus/hotstrings/action_entry_vectors.json"), "rb"))
	local corpus = assert(Json.decode_lossless(assert(file:read("*a")))); assert(file:close())
	assert(#corpus.fields >= 10 and #corpus.plans >= 8 and #corpus.matches >= 5 and #corpus.saves >= 4,
		"the action entry corpus lost vectors")

	helpers.describe("hotstring actions: shared vectors (hotstring-actions)", function()
		for _, vector in ipairs(corpus.fields) do
			local row = vector
			helpers.it("hotstring actions: fields " .. row.id, function()
				local fields, refusal = ActionEntry.fields(plain(row.entry))
				helpers.assert_eq(refusal, plain(row.refusal), row.id)
				local wanted = plain(row.fields)
				if wanted == nil then helpers.assert_eq(fields, nil, row.id)
				else
					for key, value in pairs(wanted) do helpers.assert_eq(fields[key], value, row.id .. " " .. key) end
					helpers.assert_eq(fields.workflow, wanted.workflow, row.id .. " workflow")
				end
			end)
		end
		for _, vector in ipairs(corpus.plans) do
			local row = vector
			helpers.it("hotstring actions: plan " .. row.id, function()
				local plan = ActionEntry.plan(plain(row.spec))
				local wanted = plain(row.plan)
				helpers.assert_eq(plan.erase, wanted.erase, row.id .. " erase")
				helpers.assert_eq(plan.text, wanted.text, row.id .. " text")
				helpers.assert_eq(plan.tail, wanted.tail, row.id .. " tail")
			end)
		end
		for _, vector in ipairs(corpus.matches) do
			local row = vector
			helpers.it("hotstring actions: match " .. row.id, function()
				local parsed = Reader.parse_text("[[section]]\n" .. row.line .. "\n")
				local entry = parsed.sections.section.entries[1]
				local fields = ActionEntry.fields(entry)
				local engine = Matcher.new()
				engine:load_mappings({ {
					trigger = entry.trigger, replacement = entry.output, is_word = entry.is_word,
					auto_expand = entry.auto_expand, final_result = entry.final_result,
					action = fields and fields.action, workflow = fields and fields.workflow,
					erase_trigger = fields and fields.erase_trigger,
				} })
				local cps, result = codepoints(row.typed), nil
				for index, cp in ipairs(cps) do result = engine:on_char(cp) or (index == #cps and result or nil) end
				if row.terminator ~= nil and not Json.is_null(row.terminator) then
					result = engine:on_char(row.terminator, { is_terminator = true })
				end
				helpers.assert_true(result ~= nil, row.id .. " matched")
				for key, value in pairs(row.expected) do
					helpers.assert_eq(result[key], plain(value), row.id .. " " .. key)
				end
			end)
		end
		local PersonalModel = require("hotstrings.engine.catalogue.personal_model")
		for _, vector in ipairs(corpus.saves) do
			local row = plain(vector)
			helpers.it("hotstring actions: save " .. row.name, function()
				local candidate, refusal = PersonalModel.prepare({ status = "ok", content = row.source }, row.model)
				if row.refusal then
					helpers.assert_eq(candidate, nil, row.name)
					helpers.assert_eq(refusal, row.refusal, row.name)
					return
				end
				helpers.assert_true(type(candidate) == "string", row.name .. ": " .. tostring(refusal))
				for _, text in ipairs(row.contains or {}) do helpers.assert_true(candidate:find(text, 1, true) ~= nil, text) end
				for _, text in ipairs(row.absent or {}) do helpers.assert_eq(candidate:find(text, 1, true), nil, text) end
				local entry = Reader.parse_text(candidate).sections.words.entries[1]
				helpers.assert_eq(select(2, ActionEntry.fields(entry)), nil, row.name .. ": the saved entry reads back")
			end)
		end
		helpers.it("hotstring actions: dispatch runs a workflow, a plain action, and refuses a parameter", function()
			local calls = {}
			local ports = {
				run_workflow = function(p) calls[#calls + 1] = "wf:" .. p.id; return true end,
				execute = function(a) calls[#calls + 1] = a; return true end,
				parameter_spec = function(a) return a == "run_command" and "command" or nil end,
			}
			helpers.assert_eq(ActionEntry.dispatch({ action = "run_workflow", workflow = "w" }, ports), true)
			helpers.assert_eq(ActionEntry.dispatch({ action = "select_all" }, ports), true)
			local ran, refusal = ActionEntry.dispatch({ action = "run_command" }, ports)
			helpers.assert_eq(ran, false)
			helpers.assert_eq(refusal, "parameterised_action")
			helpers.assert_eq(table.concat(calls, ","), "wf:w,select_all")
		end)
	end)
end

return M
