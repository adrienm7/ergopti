--- _shared/tests/lua/numeric_entry_contract.lua

--- ==============================================================================
--- MODULE: Numeric Prompt Entry Contract
--- DESCRIPTION:
--- Replays the typed-text vectors of value_check_vectors.json through a
--- driver's own numeric prompt, not only through the value check: the macOS
--- settings dialog and the Linux numeric prompt window must save what the
--- shared entry grammar admits (« 0,7 », « +350 ») and refuse what it refuses
--- (« 1e3 », « 1.5 » for a whole number) with the text naming the accepted
--- range, as the Windows prompt does through its port of the same check.
---
--- NOT REPLAYED:
--- A blank entry (macOS resets the setting to its default, Linux and Windows
--- refuse it: PCK-13 of the pickers-and-prompts campaign) and a declaration
--- typed in another unit than it is stored (`entry_scale`), which no numeric
--- prompt of these drivers asks for.
--- ==============================================================================

local ValueCheck = require("settings.engine.value_check")
local M = {}

local VECTORS = "settings/data/value_schema/value_check_vectors.json"

--- Decodes the vectors through the driver's shared-root resolver.
--- @param shared_path function Driver resolver for a path under _shared/.
--- @return table corpus
local function load_corpus(shared_path)
	local file = assert(io.open(shared_path(VECTORS), "rb"))
	local text = assert(file:read("*a")); assert(file:close())
	return assert(require("core.text.engine.json").decode(text))
end

--- Whether one entry vector is typed text a numeric prompt reads.
--- @param declaration table
--- @param row table
--- @return boolean
local function replayed(declaration, row)
	return (declaration.type == "integer" or declaration.type == "decimal")
		and declaration.entry_scale == nil and not row.text:match("^%s*$")
end

--- Registers the replay.
--- @param helpers table Driver test API.
--- @param shared_path function Driver resolver for a path under _shared/.
--- @param prompt function prompt(declaration, text) -> { saved = boolean, value = number|nil, message = string|nil }:
---   types `text` into the driver's prompt for a setting declared by `declaration`.
--- @param translate function The i18n accessor the driver's prompt renders its refusal with.
function M.register(helpers, shared_path, prompt, translate)
	local corpus = load_corpus(shared_path)
	local count = 0
	helpers.describe("numeric-entry: the shared entry vectors through the prompt", function()
		for _, vector in ipairs(corpus.entry) do
			local row = vector
			local declaration = corpus.declarations[row.declaration]
			if replayed(declaration, row) then
				count = count + 1
				helpers.it("numeric-entry: " .. row.id, function()
					local got = prompt(declaration, row.text)
					helpers.assert_eq(got.saved, row.ok, "saved")
					if row.ok then
						helpers.assert_eq(got.value, row.value, "saved value")
					else
						local expected = ValueCheck.render_message(
							ValueCheck.message_parts(declaration, ValueCheck.parse_entry(declaration, row.text)), translate)
						helpers.assert_eq(got.message, expected, "refusal text")
					end
				end)
			end
		end
	end)
	assert(count >= 15, "numeric entry contract lost its vectors")
end

return M
