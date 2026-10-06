--- _shared/lua/test/menu_native_child_rows.lua

--- ==============================================================================
--- MODULE: Completed Native Child Tree Admission Contract
--- DESCRIPTION:
--- Proves pure, detached provider adaptation without invoking native callbacks.
--- ==============================================================================

local M = {}

--- Records all visible physical fields without calling native actions.
--- @param rows table Real completed native hierarchy.
--- @return table shape Exact labels, flags, callbacks and child arrays.
function M.hierarchy(rows)
	local result = {}
	for _, row in ipairs(rows) do
		result[#result + 1] = { title = row.title, checked = row.checked, disabled = row.disabled,
			callback = type(row.fn) == "function", children = row.menu and M.hierarchy(row.menu) or nil }
	end
	return result
end

--- Runs the same completed-child contract through each real Lua binding.
--- @param helpers table Registered native assertion owner.
--- @param Menu table Actual bound shared renderer.
function M.run(helpers, Menu)
	helpers.describe("shared native child tree admission", function()
		helpers.it("retains complete hierarchy, flags, image and exact callback identity", function()
			local calls = 0
			local action = function() calls = calls + 1; return "native-receipt" end
			local native = { { title = "Root", checked = false, disabled = true, menu = {
				{ title = "One", checked = true, fn = action, image = "native-image" },
				{ title = "-" }, { title = "Two", disabled = false, fn = action },
			} } }
			local rows = assert(Menu.native_child_rows(native))
			helpers.assert_eq(calls, 0, "admission does not run callbacks")
			helpers.assert_true(not rawequal(rows, native) and not rawequal(rows[1].items, native[1].menu))
			helpers.assert_eq(rows[1].label, "Root")
			helpers.assert_eq(rows[1].checked, false)
			helpers.assert_eq(rows[1].disabled, true)
			helpers.assert_eq(rows[1].items[1].checked, true)
			helpers.assert_eq(rows[1].items[1].image, "native-image")
			helpers.assert_eq(rows[1].items[2], { separator = true })
			helpers.assert_eq(rows[1].items[3].disabled, false)
			helpers.assert_true(rawequal(rows[1].items[1].action, action))
			local built = Menu.render_rows(rows, "authentic-children")
			helpers.assert_eq(built, { { title = "Root", checked = false, disabled = true, menu = {
				{ title = "One", checked = true, fn = action, image = "native-image" },
				{ title = "-" }, { title = "Two", fn = action },
			} } }, "the existing renderer retains physical flags and callbacks")
			rows[1].items[1].label = "Detached"
			helpers.assert_eq(native[1].menu[1].title, "One")
			helpers.assert_eq(built[1].menu[1].fn(), "native-receipt")
			helpers.assert_eq(calls, 1, "only an explicit native leaf invocation runs the owner")
		end)

		helpers.it("admits genuine empty child arrays and independent shared subtrees", function()
			helpers.assert_eq(Menu.native_child_rows({}), {})
			local shared = { { title = "Leaf" } }
			local rows = assert(Menu.native_child_rows({ { title = "A", menu = shared }, { title = "B", menu = shared } }))
			helpers.assert_true(not rawequal(rows[1].items, rows[2].items))
			helpers.assert_eq(rows[1].items, rows[2].items)
		end)

		for _, case in ipairs({
			{ name = "nil input" }, { name = "non-table input", value = false },
			{ name = "sparse array", value = { [2] = { title = "Leaf" } } },
			{ name = "named array", value = { { title = "Leaf" }, future = true } },
			{ name = "provider dialect", value = { { label = "Leaf", action = function() end } } },
			{ name = "unknown native field", value = { { title = "Leaf", future = true } } },
			{ name = "blank title", value = { { title = "" } } },
			{ name = "bad tick", value = { { title = "Leaf", checked = 1 } } },
			{ name = "bad disabled flag", value = { { title = "Leaf", disabled = "false" } } },
			{ name = "bad callback", value = { { title = "Leaf", fn = {} } } },
			{ name = "bad subtree", value = { { title = "Leaf", menu = false } } },
			{ name = "unclickable parent callback", value = { { title = "Leaf", menu = {}, fn = function() end } } },
			{ name = "active separator", value = { { title = "-", fn = function() end } } },
			{ name = "invalid image", value = { { title = "Leaf", image = {} } } },
		}) do
			helpers.it("refuses " .. case.name .. " as a complete tree", function()
				helpers.assert_nil(Menu.native_child_rows(case.value))
			end)
		end

		helpers.it("uses only raw plain arrays and rows without invoking metamethods", function()
			local calls = 0
			local meta = { __index = function() calls = calls + 1; return "Fabricated" end,
				__pairs = function() calls = calls + 1; error("must not enumerate") end,
				__eq = function() calls = calls + 1; return true end }
			helpers.assert_nil(Menu.native_child_rows(setmetatable({ { title = "Leaf" } }, meta)))
			helpers.assert_nil(Menu.native_child_rows({ setmetatable({ title = "Leaf" }, meta) }))
			helpers.assert_eq(calls, 0)
		end)

		helpers.it("refuses cycles and depth nine before returning any partial rows", function()
			local cycle = { { title = "Cycle" } }; cycle[1].menu = cycle
			helpers.assert_nil(Menu.native_child_rows(cycle))
			local nested = { { title = "Leaf" } }
			for _ = 2, 8 do nested = { { title = "Parent", menu = nested } } end
			helpers.assert_true(type(Menu.native_child_rows(nested)) == "table", "the real renderer cap admits eight levels")
			helpers.assert_nil(Menu.native_child_rows({ { title = "Too deep", menu = nested } }))
		end)

		helpers.it("admits or refuses without invoking IO, logger, translation or child functions", function()
			local effects = 0
			local function forbidden()
				effects = effects + 1
				error("pure child admission must not invoke an external owner")
			end
			local Pure = assert(require("menu.renderer").new({
				platform = "hs", manifest_path = forbidden, json_decode = forbidden,
				i18n = { get = forbidden, section = forbidden },
				logger = { warn = forbidden, error = forbidden },
			}))
			local rows = Pure.native_child_rows({ { title = "Genuine callback", fn = forbidden } })
			helpers.assert_true(type(rows) == "table")
			helpers.assert_true(rawequal(rows[1].action, forbidden), "native callback identity is retained without invocation")
			local admitted, refused = pcall(Pure.native_child_rows, { { title = "Malformed", disabled = "false" } })
			helpers.assert_true(admitted, "pure rejection does not dispatch a logger hook")
			helpers.assert_nil(refused)
			helpers.assert_eq(effects, 0, "neither accepted nor refused input can activate external functions")
		end)
	end)
end

return M
