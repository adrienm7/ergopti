--- tests/unit/modules/gestures/test_wrap_pair_parameter_vectors.lua

--- ==============================================================================
--- MODULE: wrap_selection parameter replays the shared vectors (macOS)
--- DESCRIPTION:
--- The wrap_selection action takes a wrap_pair parameter: a symbol of the
--- built-in catalogue (_shared/modules/wrap_symbols/wrap_symbols.json) or a
--- custom left|right pair. This replays
--- _shared/tests/corpus/action_parameters/wrap_pair_vectors.json, which the Linux
--- and Windows suites replay too, through the real gesture validator and the
--- real catalogue the text module loads.
---
--- ROOT CAUSE ENCODED:
--- The only wrap action (surround_parens) wrapped the line in parentheses; no
--- action could wrap the selection with a chosen pair, and parameter validation
--- only knew URLs, so any other kind of value was refused.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local CORPUS = helpers.shared("tests/corpus/action_parameters/wrap_pair_vectors.json")

--- @return table The decoded corpus.
local function read_corpus()
	local fh = assert(io.open(CORPUS, "r"), "cannot open " .. CORPUS)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), "the wrap-pair corpus is not valid JSON")
end

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")
package.loaded["modules.shortcuts.actions.text"] = nil
package.loaded["modules.gestures.engine"] = nil
package.loaded["modules.gestures.actions"] = nil
package.loaded["modules.gestures.conflicts"] = nil
local _gestures = helpers.load_with_stubs("modules.gestures")
local Actions = require("modules.gestures.actions")
local Text = require("modules.shortcuts.actions.text")

helpers.describe("wrap_selection parameter replays the shared wrap-pair corpus", function()
	local corpus = read_corpus()

	helpers.it("the parameter is declared and the real catalogue is loaded", function()
		helpers.assert_eq(Actions.get_action_parameter_spec("wrap_selection"), "wrap_pair")
		helpers.assert_true(#Text.wrap_pair_list() >= 30,
			"the text module must expose the shared catalogue, found "
				.. #Text.wrap_pair_list() .. " pair(s)")
		helpers.assert_true(#corpus.vectors >= 15, "the corpus must hold its vectors")
	end)

	for _, vector in ipairs(corpus.vectors) do
		helpers.it("wrap-pair vector '" .. vector.id .. "'", function()
			local valid = vector.valid ~= false
			helpers.assert_eq(Actions.validate_action_parameter("wrap_selection", vector.value), valid,
				vector.id .. ": validation")
			local left, right = Actions.wrap_pair_for(vector.value)
			if valid then
				helpers.assert_eq(left, vector.left, vector.id .. ": left")
				helpers.assert_eq(right, vector.right, vector.id .. ": right")
			else
				helpers.assert_eq(left, nil, vector.id .. ": an invalid value names no pair")
			end
		end)
	end
end)
