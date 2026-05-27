--- tests/unit/test_adapter_compliance.lua

--- ==============================================================================
--- MODULE: Adapter Structural Compliance Tests
--- DESCRIPTION:
--- Validates that every Hammerspoon adapter in adapters/ exposes the correct
--- method surface required by the corresponding port contract in
--- static/ergopti_plus/shared/ports/. Each adapter is loaded with the hs stub,
--- and each required method is checked for existence and correct arity.
---
--- RATIONALE:
--- Port adapters are the boundary between domain logic and OS APIs. If a
--- refactor removes or renames a method that a domain module depends on, these
--- tests catch the regression before it reaches production — without needing
--- to run OS-level code.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ============================================
--- ============================================
-- ======= 1/ Port Contract Definitions =======
--- ============================================
-- ============================================

--- Port method contracts: { method_name → required_arity }
--- Mirrors the portContract.methods fields in each shared/ports/*.spec.js.
local PORT_CONTRACTS = {
	keyboard_hook = {
		{ name = "start",          arity = 1 },
		{ name = "stop",           arity = 0 },
		{ name = "isRunning",      arity = 0 },
		{ name = "refreshContext", arity = 0 },
		{ name = "getContext",     arity = 0 },
	},
	text_sender = {
		{ name = "send",       arity = 3 },
		{ name = "eraseChars", arity = 1 },
		{ name = "pressKey",   arity = 2 },
	},
	tooltip_renderer = {
		{ name = "show",          arity = 1 },
		{ name = "hide",          arity = 0 },
		{ name = "isVisible",     arity = 0 },
		{ name = "updateElement", arity = 1 },
	},
	http_client = {
		{ name = "post",     arity = 4 },
		{ name = "cancel",   arity = 0 },
		{ name = "isActive", arity = 0 },
	},
	timer_scheduler = {
		{ name = "after",     arity = 2 },
		{ name = "every",     arity = 2 },
		{ name = "cancel",    arity = 1 },
		{ name = "cancelAll", arity = 0 },
	},
	notifier = {
		{ name = "send", arity = 2 },
	},
	tray_menu = {
		{ name = "setIcon",    arity = 1 },
		{ name = "setMenu",    arity = 1 },
		{ name = "setTooltip", arity = 1 },
		{ name = "destroy",    arity = 0 },
	},
	file_system = {
		{ name = "read",   arity = 1 },
		{ name = "write",  arity = 2 },
		{ name = "append", arity = 2 },
		{ name = "exists", arity = 1 },
		{ name = "delete", arity = 1 },
	},
	window_info = {
		{ name = "getFocused", arity = 0 },
		{ name = "getAll",     arity = 0 },
	},
}




-- ==============================================
--- ===============================================
-- ======= 2/ Compliance Test Registration =======
--- ===============================================
-- ==============================================

for adapter_name, methods in pairs(PORT_CONTRACTS) do
	-- Capture loop locals for closure
	local name    = adapter_name
	local methods_snap = methods

	helpers.describe(string.format("Adapter compliance: %s", name), function()
		local module_name = "adapters." .. name
		local adapter = helpers.load_with_stubs(module_name)

		helpers.it("module loads without error", function()
			helpers.assert_true(
				type(adapter) == "table",
				string.format("%s: require('%s') returned %s", name, module_name, type(adapter))
			)
		end)

		if type(adapter) ~= "table" then return end

		for _, spec in ipairs(methods_snap) do
			local method_name  = spec.name
			local req_arity    = spec.arity

			helpers.it(string.format("exposes %s (arity %d)", method_name, req_arity), function()
				helpers.assert_true(
					type(adapter[method_name]) == "function",
					string.format("%s.%s must be a function, got %s",
						name, method_name, type(adapter[method_name]))
				)
				-- debug.getinfo returns nparams for Lua functions; use it
				-- to check arity. C functions and variadic functions report -1.
				local info = debug.getinfo(adapter[method_name], "u")
				if info and info.nparams >= 0 then
					helpers.assert_eq(
						info.nparams, req_arity,
						string.format("%s.%s arity", name, method_name)
					)
				end
				-- Note: if nparams == -1 (variadic or C function) we skip the
				-- arity check but the existence check already passed.
			end)
		end
	end)
end
