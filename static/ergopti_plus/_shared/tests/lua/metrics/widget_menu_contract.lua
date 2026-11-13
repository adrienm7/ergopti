--- _shared/tests/lua/metrics/widget_menu_contract.lua

--- ==============================================================================
--- MODULE: Native Metrics Widget Menu Parity Contract
--- DESCRIPTION:
--- Both Lua drivers render their actual menus against the same exhaustive
--- stored-state vectors that the Windows native-menu suite reads. Checks retain
--- the user's choices while disabled, and the declaration owns every row.
--- ==============================================================================

local M = {}

--- Registers native-menu checks against the shared golden state vectors.
--- @param helpers table Driver test harness.
--- @param options table fixture, declared rows, build(state), translate(key).
function M.register(helpers, options)
	local fixture = options.fixture
	helpers.describe("Metrics widget menu parity", function()
		helpers.it("metrics-widget-parity declared checks", function()
			for _, spec in ipairs(fixture.rows) do
				local declared
				for _, row in ipairs(options.declared) do
					if row.id == spec.id then declared = row end
				end
				helpers.assert_true(declared ~= nil, spec.id .. " belongs to the shared declaration")
				helpers.assert_eq(declared.type, "check", spec.id .. " is rendered by the shared renderer")
			end
		end)
		for _, vector in ipairs(fixture.cases) do
			helpers.it("metrics-widget-parity " .. vector.id, function()
				local state = {}
				for index, key in ipairs(fixture.fields) do state[key] = vector.state[index] end
				local items = options.build(state)
				-- With metrics off the category-off rule appends its reason to each caption.
				local reason = options.translate("menu.category_off_reason")
				local cut = reason:find(":", 1, true) or reason:find("\239\188\154", 1, true)
				local suffix = " — " .. (cut and reason:sub(1, cut - 1) or reason):match("^%s*(.-)%s*$")
				local function caption(row)
					local title = row.title
					if type(title) == "string" and title:sub(-#suffix) == suffix then
						return title:sub(1, -#suffix - 1)
					end
					return title
				end
				local start, count = nil, 0
				local anchor = options.translate(fixture.rows[1].i18n)
				for position, row in ipairs(items) do
					if caption(row) == anchor then start, count = position, count + 1 end
				end
				helpers.assert_eq(count, 1, "the floating widget group is drawn once")
				for index, spec in ipairs(fixture.rows) do
					local label = options.translate(spec.i18n)
					local found = items[start + index - 1]
					helpers.assert_true(type(found) == "table", spec.id .. " occupies its declared position")
					helpers.assert_eq(caption(found), label,spec.id .. " has the shared label in the same group order")
					helpers.assert_eq(found.checked == true, vector.checked[index], spec.id .. " preserves its stored check")
					helpers.assert_eq(found.disabled == true, vector.disabled[index], spec.id .. " follows the shared gate")
					if not vector.disabled[index] then
						helpers.assert_eq(type(found.fn), "function", spec.id .. " remains actionable")
					end
				end
			end)
		end
	end)
end

return M
