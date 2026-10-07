--- _shared/lua/test/menu_row_dialect_contract.lua

--- ==============================================================================
--- MODULE: External Menu Dialect Contract
--- DESCRIPTION:
--- Independent hand inputs preserve external payload and callback identities,
--- while malformed semantic trees refuse without invoking user-controlled hooks.
--- ==============================================================================

local M = {}

--- Registers the shared pure dialect contract in the actual driver suites.
--- @param helpers table The registered driver assertion owner.
function M.register(helpers)
	local Dialect = require("menu.row_dialect")
	helpers.describe("external menu rows preserve their genuine payload", function()
		helpers.it("detaches mixed native and provider children without calling their actions", function()
			local calls = 0
			local action = function() calls = calls + 1; return false end
			local payload = { observed = "retained" }
			local rows = { { title = "Native parent", menu = {
				{ label = "Canonical child", action = action, checked = false, disabled = true,
					image = "native-image.svg", proof = "1:2", payload = payload },
				{ title = "-" },
				{ title = "Native child", fn = action, checked = true },
			} } }
			local converted = Dialect.rows(rows)
			helpers.assert_not_nil(converted)
			helpers.assert_eq(converted[1].label, "Native parent")
			helpers.assert_eq(converted[1].items[1].label, "Canonical child")
			helpers.assert_eq(converted[1].items[1].proof, "1:2")
			helpers.assert_true(rawequal(converted[1].items[1].payload, payload), "non-presentation payload is not interpreted")
			helpers.assert_true(rawequal(converted[1].items[1].action, action))
			helpers.assert_eq(converted[1].items[1].image, "native-image.svg")
			helpers.assert_eq(converted[1].items[1].checked, false)
			helpers.assert_eq(converted[1].items[1].disabled, true)
			helpers.assert_eq(converted[1].items[2].separator, true)
			helpers.assert_eq(converted[1].items[3].checked, true)
			helpers.assert_eq(rawequal(converted, rows), false)
			helpers.assert_eq(rawequal(converted[1], rows[1]), false)
			helpers.assert_eq(rawequal(converted[1].items, rows[1].menu), false)
			helpers.assert_eq(calls, 0)
			rows[1].menu[1].label = "later mutation"
			helpers.assert_eq(converted[1].items[1].label, "Canonical child")
		end)
		helpers.it("retains an actual valid empty child and exact matching aliases", function()
			local action = function() return true end
			local children = {}
			local row = Dialect.row({ title = "Parent", label = "Parent", menu = children, items = children })
			helpers.assert_eq(row.label, "Parent")
			helpers.assert_eq(#row.items, 0)
			helpers.assert_true(rawequal(Dialect.row({ title = "Action", fn = action, action = action }).action, action))
			helpers.assert_eq(#Dialect.rows({}), 0)
		end)
		helpers.it("normalizes the finished native submenu field by the same bounded tree grammar", function()
			local action = function() return false end
			local row = Dialect.row({ label = "Finished", submenu = { { title = "Child", fn = action } } })
			helpers.assert_eq(row.items[1].label, "Child")
			helpers.assert_true(rawequal(row.items[1].action, action))
			helpers.assert_eq(row.submenu, nil)
		end)
		helpers.it("refuses a whole malformed tree instead of publishing its surviving siblings", function()
			local action = function() return true end
			local malformed = {
				false, {}, { title = false }, { label = "" }, { title = "N", label = "Other" },
				{ title = "N", fn = action, action = function() end },
				{ title = "N", menu = {}, items = {} }, { title = "N", menu = false },
				{ title = "N", fn = action, menu = {} }, { title = "N", checked = 1 },
				{ title = "N", disabled = "yes" }, { title = "N", image = {} },
				{ title = "-", fn = action }, { separator = true, label = "not a separator" },
				{ title = "N", disabled_reason_key = {} },
			}
			for _, row in ipairs(malformed) do
				helpers.assert_eq(Dialect.rows({ { title = "Actual first" }, row }), nil)
			end
			helpers.assert_eq(Dialect.rows({ [1] = { title = "First" }, [3] = { title = "Hole" } }), nil)
			helpers.assert_eq(Dialect.rows({ named = { title = "Named" } }), nil)
		end)
		helpers.it("refuses cycles and excessive depth without executing callbacks", function()
			local cyclic = {}; cyclic[1] = { title = "Cycle", menu = cyclic }
			helpers.assert_eq(Dialect.rows(cyclic), nil)
			local deep = {}
			for _ = 1, 9 do deep = { { title = "Level", menu = deep } } end
			helpers.assert_eq(Dialect.rows(deep), nil)
		end)
		helpers.it("uses no user-controlled field, length, equality or iteration hooks", function()
			local calls = 0
			local function effect() calls = calls + 1; error("user hook must not run") end
			local meta = { __index = effect, __len = effect, __pairs = effect, __eq = effect, __tostring = effect }
			helpers.assert_eq(Dialect.rows(setmetatable({}, meta)), nil)
			helpers.assert_eq(Dialect.rows({ setmetatable({ title = "Current" }, meta) }), nil)
			helpers.assert_eq(Dialect.rows({ { title = setmetatable({}, meta), label = setmetatable({}, meta) } }), nil)
			helpers.assert_eq(calls, 0)
		end)
	end)
end

return M
