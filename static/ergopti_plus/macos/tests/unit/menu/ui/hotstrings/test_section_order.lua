--- tests/unit/menu/ui/hotstrings/test_section_order.lua

--- ==============================================================================
--- MODULE: Hotstring Section Order Contract Tests
--- DESCRIPTION:
--- Replays the cross-driver section-order corpus and executes the actual menu
--- callbacks, including disabled boundary moves, pause, and refused persistence.
--- ==============================================================================

local helpers = require("tests.helpers")
local Order = require("hotstrings.engine.section_order")
local json = require("core.text.engine.json")

helpers.describe("hotstring-section-order", function()
	local file = assert(io.open(helpers.driver_root() .. "/../_shared/tests/corpus/hotstrings/section_order_vectors.json", "rb"))
	local vectors = json.decode(file:read("*a")).vectors
	file:close()
	for _, vector in ipairs(vectors) do
		helpers.it("hotstring-section-order: " .. vector.name, function()
			local result = Order.resolve(vector.source, vector.override)
			if vector.move then result = Order.move(result, vector.move.name, vector.move.delta) end
			if vector.refused then helpers.assert_nil(result) else helpers.assert_eq(result, vector.expected) end
		end)
	end
	helpers.it("hotstring-section-order: refuses malformed overrides without changing the source", function()
		local source = { "a", "b" }
		helpers.assert_nil(Order.resolve(source, { [2] = "a" }))
		helpers.assert_nil(Order.resolve(source, { "a", false }))
		helpers.assert_nil(Order.resolve(source, { first = "a" }))
		helpers.assert_eq(source, { "a", "b" })
	end)
	helpers.it("hotstring-section-order: menu callbacks preserve refusal and recheck pause before a move", function()
		local paused, pause_error, accepted, calls, chosen = false, false, false, 0, nil
		local moves, reset = {}, nil
		local manifest = { template_rows = function(name, commands, states, providers)
			if name == "hotstring_order_moves" then
				moves[#moves + 1] = { commands = commands, states = states }
				return { { label = "up", action = commands.hotstring_order_up } }
			elseif name == "hotstring_order_footer" then reset = commands.hotstring_order_reset; return {}
			else return { { submenu = providers.hotstring_order_children } } end
		end }
		local rows = Order.menu(manifest.template_rows, { "a", "-", "b" }, { a = "First", b = "Second" }, function(value)
			calls, chosen = calls + 1, value
			return accepted
		end, function()
			if pause_error then error("injected pause reader failure") end
			return not paused
		end)
		helpers.assert_eq(#rows[1].submenu, 2)
		helpers.assert_eq(moves[1].states.hotstring_order_up_ready(), false)
		helpers.assert_eq(moves[2].commands.hotstring_order_up(), false)
		helpers.assert_eq(chosen, { "b", "-", "a" })
		paused = true
		helpers.assert_eq(moves[2].commands.hotstring_order_up(), false)
		helpers.assert_eq(calls, 1)
		paused, pause_error = false, true
		helpers.assert_eq(moves[2].states.hotstring_order_up_ready(), false)
		helpers.assert_eq(moves[2].commands.hotstring_order_up(), false)
		helpers.assert_eq(reset(), false)
		helpers.assert_eq(calls, 1, "a failing pause owner cannot publish an order")
		pause_error, accepted = false, true
		helpers.assert_eq(reset(), true)
		helpers.assert_nil(chosen)
	end)
	helpers.it("hotstring-section-order: unavailable templates refuse only the order widget", function()
		local writes = 0
		local function commit() writes = writes + 1; return true end
		local function ready() return true end
		helpers.assert_eq(Order.menu(nil, { "a", "b" }, { a = "A", b = "B" }, commit, ready), {})
		for _, rejected in ipairs({ "hotstring_order_moves", "hotstring_order_footer", "hotstring_order_parent" }) do
			local function template(name)
				if name == rejected then error("injected template withdrawal") end
				return {}
			end
			helpers.assert_eq(Order.menu(template, { "a", "b" }, { a = "A", b = "B" }, commit, ready), {})
		end
		helpers.assert_eq(writes, 0)
	end)
	helpers.it("hotstring-section-order: every category keeps its own stored order key", function()
		local Languages = require("hotstrings.engine.languages")
		local corpus = assert(io.open(helpers.driver_root() .. "/../_shared/tests/corpus/hotstrings/section_order_category_vectors.json", "rb"))
		local categories = json.decode(corpus:read("*a")).vectors
		corpus:close()
		local seen = {}
		for _, vector in ipairs(categories) do
			-- The menu keys an order by the category id it loaded: a language file is
			-- registered under its group id, a root file under its stem.
			local id = vector.folder ~= "" and Languages.group_id(vector.folder, vector.stem) or vector.stem
			helpers.assert_eq(id, vector.id, vector.name)
			helpers.assert_nil(seen[id], "two categories share the order key " .. id)
			seen[id] = true
		end
	end)

end)
