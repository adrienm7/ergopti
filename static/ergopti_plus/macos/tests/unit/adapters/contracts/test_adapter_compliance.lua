--- tests/unit/adapters/contracts/test_adapter_compliance.lua

--- ==============================================================================
--- MODULE: Adapter Structural Compliance Tests
--- DESCRIPTION:
--- Validates that every Hammerspoon adapter in adapters/ exposes the correct
--- method surface required by the corresponding port contract. The contract is
--- read at runtime from the generated single source _shared/core/ports/contracts.json
--- (projected from _shared/core/ports/*.spec.js by codegen-contracts-json.cjs), so the
--- method names and arities are no longer mirrored by hand in this file — a
--- spec change flows here automatically.
---
--- RATIONALE:
--- Port adapters are the boundary between domain logic and OS APIs. If a
--- refactor removes or renames a method that a domain module depends on, these
--- tests catch the regression before it reaches production — without needing
--- to run OS-level code. Reading the contract from the shared JSON means the
--- macOS, AHK and Linux drivers all validate against the exact same source.
--- ==============================================================================

local helpers = require("tests.helpers")
local json    = require("core.text.engine.json")




-- ====================================================
-- ====================================================
-- ======= 1/ Load the Single-Source Contract =========
-- ====================================================
-- ====================================================

local CONTRACTS_PATH = helpers.shared("core/ports/contracts.json")

--- Reads and decodes the shared port-contract registry. Fails loudly (rather
--- than silently skipping) when the file is absent or malformed — a missing
--- contract must never let compliance pass by default.
--- @return table The decoded { ports = { … } } registry.
local function load_contracts()
	local fh = io.open(CONTRACTS_PATH, "r")
	assert(fh, "contracts.json not found at " .. CONTRACTS_PATH ..
		" — run `npm run codegen:contracts`")
	local raw = fh:read("*a")
	fh:close()
	local decoded = json.decode(raw)
	assert(type(decoded) == "table" and type(decoded.ports) == "table",
		"contracts.json did not decode into a { ports = {…} } table")
	return decoded
end

local CONTRACTS = load_contracts()


-- The adapters this headless harness can load under the hs stub. (KeyboardHook,
-- TextSender, … — the OS-light surface.) The remaining ports are exercised by
-- the AHK parity test and the contracts freshness gate; expanding this list to
-- all 20 is tracked separately so a newly-stubbable adapter can be added here.
-- Each adapter by its full module name and the port it implements: the name
-- follows the module wherever it lives, and the port stays the contract's.
local ADAPTERS_UNDER_TEST = {
	{ module = "adapters.keyboard_hook", port = "KeyboardHook" },
	{ module = "adapters.text_sender", port = "TextSender" },
	{ module = "adapters.tooltip_renderer", port = "TooltipRenderer" },
	{ module = "adapters.http_client", port = "HttpClient" },
	{ module = "core.events.timer_scheduler", port = "TimerScheduler" },
	{ module = "adapters.notifier", port = "Notifier" },
	{ module = "adapters.hotkey_registrar", port = "HotkeyRegistrar" },
	{ module = "adapters.tray_menu", port = "TrayMenu" },
	{ module = "core.fs.adapters.file_system", port = "FileSystem" },
	{ module = "adapters.window_info", port = "WindowInfo" },
}




-- ====================================================
-- ====================================================
-- ======= 2/ Compliance Test Registration ============
-- ====================================================
-- ====================================================

for _, entry in ipairs(ADAPTERS_UNDER_TEST) do
	local name      = entry.module:match("([^.]+)$")
	local port_name = entry.port

	helpers.describe(string.format("Adapter compliance: %s (%s)", name, port_name), function()
		local port = CONTRACTS.ports[port_name]

		helpers.it("port contract exists in contracts.json", function()
			helpers.assert_true(
				type(port) == "table" and type(port.methods) == "table",
				string.format("no contract for port %s in contracts.json", port_name)
			)
		end)

		if type(port) ~= "table" or type(port.methods) ~= "table" then return end

		local module_name = entry.module
		local adapter = helpers.load_with_stubs(module_name)

		helpers.it("module loads without error", function()
			helpers.assert_true(
				type(adapter) == "table",
				string.format("%s: require('%s') returned %s", name, module_name, type(adapter))
			)
		end)

		if type(adapter) ~= "table" then return end

		for method_name, spec in pairs(port.methods) do
			if spec.required then
				local req_arity = spec.arity
				helpers.it(string.format("exposes %s (arity %d)", method_name, req_arity), function()
					helpers.assert_true(
						type(adapter[method_name]) == "function",
						string.format("%s.%s must be a function, got %s",
							name, method_name, type(adapter[method_name]))
					)
					-- debug.getinfo returns nparams for Lua functions; C functions
					-- and variadic functions report -1, in which case we skip the
					-- arity check (the existence check already passed).
					local info = debug.getinfo(adapter[method_name], "u")
					if info and info.nparams >= 0 then
						helpers.assert_eq(
							info.nparams, req_arity,
							string.format("%s.%s arity", name, method_name)
						)
					end
				end)
			end
		end
	end)
end

require("tests.lua.core_fs.file_system_ports_contract").register(helpers, "macos", 8,
	function() return helpers.load_with_stubs("core.fs.adapters.file_system") end)
