--- tests/unit/modules/shortcuts/test_wrap_pair_parameter_vectors.lua

--- ==============================================================================
--- MODULE: wrap_selection parameter replays the shared vectors (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/action_parameters/wrap_pair_vectors.json, which
--- the macOS and Windows suites replay too, through the gesture validator and
--- the shortcuts manager's resolver over the real shared catalogue
--- (_shared/modules/wrap_symbols/wrap_symbols.json).
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local CORPUS = helpers.driver_root() .. "/../_shared/tests/corpus/action_parameters/wrap_pair_vectors.json"

--- @return table The decoded corpus.
local function read_corpus()
	local fh = assert(io.open(CORPUS, "r"), "cannot open " .. CORPUS)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), "the wrap-pair corpus is not valid JSON")
end

local Shortcuts = helpers.load_module("modules.shortcuts.manager")
local Gestures = helpers.load_module("modules.gestures.manager")

helpers.describe("wrap_selection parameter replays the shared wrap-pair corpus", function()
	local corpus = read_corpus()

	helpers.it("the parameter is declared and the real catalogue is loaded", function()
		helpers.assert_eq(Gestures.get_action_parameter_spec("wrap_selection"), "wrap_pair")
		helpers.assert_true(#Shortcuts.get_wrap_pair_list() >= 30,
			"the shortcuts manager must expose the shared catalogue in order")
		helpers.assert_true(#corpus.vectors >= 15, "the corpus must hold its vectors")
	end)

	for _, vector in ipairs(corpus.vectors) do
		helpers.it("wrap-pair vector '" .. vector.id .. "'", function()
			local valid = vector.valid ~= false
			helpers.assert_eq(Gestures.validate_action_parameter("wrap_selection", vector.value), valid,
				vector.id .. ": validation")
			local left, right = Shortcuts.resolve_wrap_pair(vector.value)
			if valid then
				helpers.assert_eq(left, vector.left, vector.id .. ": left")
				helpers.assert_eq(right, vector.right, vector.id .. ": right")
			else
				helpers.assert_eq(left, nil, vector.id .. ": an invalid value names no pair")
			end
		end)
	end
end)
