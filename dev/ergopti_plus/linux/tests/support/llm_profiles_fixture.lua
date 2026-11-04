--- tests/support/llm_profiles_fixture.lua

--- ==============================================================================
--- MODULE: Profiles Without Inventory Acquisition
--- DESCRIPTION:
--- Declares the empty inventory lifecycle of scripted prediction scenarios.
--- Any inventory construction attempt fails and remains observable during cleanup;
--- these ports never claim native inventory construction or settlement evidence.
--- ==============================================================================

local M = {}
local helpers = require("tests.helpers")

--- Builds an explicitly inventory-free Profiles boundary.
--- @param port table Scenario-owned profile settings and persistence callbacks.
--- @return table profiles Original scenario port with an empty inventory lifecycle.
function M.without_inventory(port)
	assert(type(port) == "table" and type(port.init) == "function", "explicit Profiles initialization required")
	assert(port.cancel_model_inventory == nil and port.model_inventory_pending == nil,
		"the scenario must not replace another inventory owner")
	local construction_attempts, debt = 0, 0
	local function refuse_acquisition()
		construction_attempts, debt = construction_attempts + 1, debt + 1
		error("this Profiles fixture owns no inventory acquisition", 2)
	end
	port.get_models, port.refresh_models = refuse_acquisition, refuse_acquisition
	function port.cancel_model_inventory() return debt == 0 end
	function port.model_inventory_pending() return debt ~= 0 end
	function port.assert_no_inventory()
		helpers.assert_eq(construction_attempts, 0, "prediction fixture must construct no model inventory")
		helpers.assert_eq(debt, 0, "prediction fixture must retain no inventory cleanup debt")
	end
	return port
end

return M
