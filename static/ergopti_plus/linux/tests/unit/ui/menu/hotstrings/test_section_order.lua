--- tests/unit/ui/menu/hotstrings/test_section_order.lua

--- ==============================================================================
--- MODULE: Hotstring Section Order Contract Tests
--- DESCRIPTION:
--- Replays the cross-driver section-order corpus and executes the actual menu
--- callbacks, including disabled boundary moves, pause, and refused persistence.
--- ==============================================================================

local helpers = require("tests.helpers")
local Order = require("hotstrings.section_order")
local json = require("json")

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
		local paused, accepted, calls, chosen = false, false, 0, nil
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
		end, function() return not paused end)
		helpers.assert_eq(#rows[1].submenu, 2)
		helpers.assert_eq(moves[1].states.hotstring_order_up_ready(), false)
		helpers.assert_eq(moves[2].commands.hotstring_order_up(), false)
		helpers.assert_eq(chosen, { "b", "-", "a" })
		paused = true
		helpers.assert_eq(moves[2].commands.hotstring_order_up(), false)
		helpers.assert_eq(calls, 1)
		paused, accepted = false, true
		helpers.assert_eq(reset(), true)
		helpers.assert_nil(chosen)
	end)
end)
