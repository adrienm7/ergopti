--- tests/unit/modules/gestures/test_send_input_parameter_vectors.lua

--- ==============================================================================
--- MODULE: send_text / send_key / send_shortcut parameters replay the shared vectors (macOS)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/action_parameters/send_input_vectors.json, which
--- the Linux and Windows suites replay too, through the real gesture validator
--- and _shared/lua/send_input over the real vocabulary
--- (_shared/modules/actions/send_keys.json).
---
--- ROOT CAUSE ENCODED:
--- No action could type a chosen text or press a chosen key or shortcut, and
--- parameter validation knew only URLs and wrap pairs.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

require("test.action_parameter_label_contract")(helpers, json, helpers.shared(""))

local CORPUS = helpers.shared("tests/corpus/action_parameters/send_input_vectors.json")

--- @return table The decoded corpus.
local function read_corpus()
	local fh = assert(io.open(CORPUS, "r"), "cannot open " .. CORPUS)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), "the send-input corpus is not valid JSON")
end

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")
package.loaded["modules.shortcuts.actions.text"] = nil
package.loaded["modules.gestures.engine"] = nil
package.loaded["modules.gestures.actions"] = nil
package.loaded["modules.gestures.conflicts"] = nil
local _gestures = helpers.load_with_stubs("modules.gestures")
local Actions = require("modules.gestures.actions")
local SendInput = require("send_input")

local ACTIONS = { text = "send_text", key = "send_key", shortcut = "send_shortcut" }

helpers.describe("send input parameters replay the shared send-input corpus", function()
	local corpus = read_corpus()

	helpers.it("the parameters are declared and the corpus is loaded", function()
		for kind, action in pairs(ACTIONS) do
			helpers.assert_eq(Actions.get_action_parameter_spec(action), kind, action .. " parameter kind")
		end
		helpers.assert_true(#corpus.vectors >= 40, "the corpus must hold its vectors")
	end)

	for _, vector in ipairs(corpus.vectors) do
		helpers.it("send-input vector '" .. vector.id .. "'", function()
			local value = string.rep(vector.value, vector["repeat"] or 1)
			local valid = vector.valid ~= false
			helpers.assert_eq(Actions.validate_action_parameter(ACTIONS[vector.kind], value), valid,
				vector.id .. ": validation")
			local parsed = SendInput.parse(vector.kind, value, Actions.send_vocabulary())
			if not valid then
				helpers.assert_eq(parsed, nil, vector.id .. ": an invalid value parses to nothing")
				return
			end
			helpers.assert_true(parsed ~= nil, vector.id .. ": a valid value parses")
			helpers.assert_eq(parsed.canonical,
				string.rep(vector.canonical, vector.canonical_repeat or 1), vector.id .. ": canonical form")
			helpers.assert_eq(parsed.named, vector.named, vector.id .. ": named key")
			helpers.assert_eq(parsed.char, vector.char, vector.id .. ": character key")
			if vector.kind == "shortcut" then
				helpers.assert_eq(table.concat(parsed.mods, ","), table.concat(vector.mods, ","),
					vector.id .. ": modifiers")
			end
		end)
	end
end)
