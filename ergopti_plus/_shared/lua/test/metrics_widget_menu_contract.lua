--- _shared/lua/test/metrics_widget_menu_contract.lua

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
				local start, count = nil, 0
				local anchor = options.translate(fixture.rows[1].i18n)
				for position, row in ipairs(items) do
					if row.title == anchor then start, count = position, count + 1 end
				end
				helpers.assert_eq(count, 1, "the floating widget group is drawn once")
				for index, spec in ipairs(fixture.rows) do
					local label = options.translate(spec.i18n)
					local found = items[start + index - 1]
					helpers.assert_true(type(found) == "table", spec.id .. " occupies its declared position")
					helpers.assert_eq(found.title, label, spec.id .. " has the shared label in the same group order")
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
