--- _shared/lua/test/menu_row_order_contract.lua

--- ==============================================================================
--- MODULE: Menu Row Order Contract
--- DESCRIPTION:
--- Replays _shared/tests/corpus/menu/row_order_vectors.json through menu.row_order
--- on both Lua drivers, and checks that the accessors hand out detached copies.
--- ==============================================================================

local M = {}

--- Registers the row order checks in a driver's existing owner.
--- @param helpers table The driver's describe/it/assertion functions.
--- @param count number How many vectors the corpus must hold (sorts + lists + refusals).
function M.register(helpers, count)
	local Json = require("json")
	local RowOrder = require("menu.row_order")
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/menu/row_order_vectors.json"), "rb"))
	local corpus = assert(Json.decode(file:read("*a")))
	file:close()
	assert(#corpus.sorts + #corpus.lists + #corpus.refusals == count, "row_order_vectors.json holds another number of vectors")
	helpers.describe("menu row order (menu-row-order)", function()
		for _, vector in ipairs(corpus.sorts) do
			local case = vector
			helpers.it("sorts " .. case.id .. " (menu-row-order)", function()
				local input = {}
				for index, item in ipairs(case.input) do input[index] = item end
				table.sort(input, RowOrder.comparator(case.rule))
				helpers.assert_eq(input, case.sorted)
			end)
		end
		for _, vector in ipairs(corpus.lists) do
			local case = vector
			helpers.it("lists " .. case.id .. " (menu-row-order)", function()
				helpers.assert_eq(RowOrder.list(case.rule), case.order)
			end)
		end
		for _, vector in ipairs(corpus.refusals) do
			local case = vector
			helpers.it("refuses " .. case.id .. " (menu-row-order)", function()
				local ok, err = pcall(RowOrder.list, case.rule)
				helpers.assert_eq(ok, false)
				helpers.assert_true(tostring(err):find("unknown menu row order rule", 1, true) ~= nil, tostring(err))
				helpers.assert_eq(pcall(RowOrder.comparator, case.rule), false)
			end)
		end
		helpers.it("hands out a detached list on every call (menu-row-order)", function()
			local first = RowOrder.list("menu_chord_modifiers")
			first[1] = "tampered"
			helpers.assert_eq(RowOrder.list("menu_chord_modifiers")[1], "shift")
			local rank = RowOrder.rank("menu_chord_modifiers")
			helpers.assert_eq(rank.shift, 1)
			helpers.assert_eq(rank.ctrl, 4)
		end)
	end)
end

return M
