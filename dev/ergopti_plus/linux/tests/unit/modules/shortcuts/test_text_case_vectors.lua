--- tests/unit/modules/shortcuts/test_text_case_vectors.lua

--- ==============================================================================
--- MODULE: Selection Case Actions Replay the Shared Vectors (Linux)
--- DESCRIPTION:
--- Runs the case actions the shortcuts manager hands to the gesture executor,
--- by their catalogue ids, on every vector of
--- _shared/tests/corpus/text_case/vectors.json, the corpus the macOS and
--- Windows suites replay too, and compares the text each one pastes back.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local CORPUS = helpers.driver_root() .. "/../_shared/tests/corpus/text_case/vectors.json"

--- The catalogue action each corpus field is produced by.
local ACTION_BY_FIELD = {
	upper = "selection_uppercase",
	lower = "selection_lowercase",
	title = "selection_titlecase",
	toggle_upper = "uppercase_selection",
	toggle_title = "titlecase_selection",
}
local FIELD_ORDER = { "upper", "lower", "title", "toggle_upper", "toggle_title" }

--- @return table The decoded corpus.
local function read_corpus()
	local fh = assert(io.open(CORPUS, "r"), "cannot open " .. CORPUS)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), "the text-case corpus is not valid JSON")
end

--- Whether a vector applies to the Linux driver.
--- @param vector table
--- @return boolean
local function applies_here(vector)
	if vector.drivers == nil then return true end
	for _, driver in ipairs(vector.drivers) do
		if driver == "linux" then return true end
	end
	return false
end

--- Loads the shortcuts manager over a clipboard whose selection is `selected`
--- and runs the handler it exposes for `action_name`.
--- @param action_name string Catalogue action id.
--- @param selected string The selected text.
--- @return string|nil The text the handler pasted back.
local function transformed_by(action_name, selected)
	local names = {
		manager = "modules.shortcuts.manager",
		clipboard = "adapters.clipboard",
		event_loop = "adapters.event_loop",
		combo = "modules.gestures.combo_emitter",
		injector = "modules.hotstrings.injector",
		keylogger = "modules.keylogger.keylogger",
	}
	local previous = {}
	for key, name in pairs(names) do previous[key] = package.loaded[name] end
	local replacement = nil
	package.loaded[names.clipboard] = {
		transform_selection = function(transform)
			replacement = transform(selected)
			return true
		end,
		read_checked = function() return true, "clipboard", nil end,
	}
	package.loaded[names.event_loop] = { sleep_ms = function() return true end }
	package.loaded[names.combo] = { press = function() return true end }
	package.loaded[names.injector] = { inject = function() return { ok = true } end }
	package.loaded[names.keylogger] = { record_shortcut = function() return true end }
	package.loaded[names.manager] = nil

	local ok, err = pcall(function()
		local handlers = require(names.manager).action_handlers()
		helpers.assert_eq(type(handlers[action_name]), "function",
			"the shortcuts manager must hand the executor a handler for " .. action_name)
		helpers.assert_true(handlers[action_name]() == true, action_name .. " must succeed")
	end)
	for key, name in pairs(names) do package.loaded[name] = previous[key] end
	helpers.assert_true(ok, tostring(err))
	return replacement
end

helpers.describe("selection case actions replay the shared text-case corpus", function()
	local corpus = read_corpus()

	helpers.it("the corpus holds vectors for this driver", function()
		local applicable = 0
		for _, vector in ipairs(corpus.vectors) do
			if applies_here(vector) then applicable = applicable + 1 end
		end
		helpers.assert_true(applicable >= 10,
			"expected at least 10 Linux vectors, found " .. applicable)
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
				helpers.assert_eq(checked, #FIELD_ORDER, vector.id .. " must state every field")
			end)
		end
	end
end)
