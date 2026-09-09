--- tests/meta/test_karabiner_stock_process_isolation.lua

--- ==============================================================================
--- MODULE: Karabiner Stock Process Isolation Guard
--- DESCRIPTION:
--- Prevents Ergopti from controlling any official Karabiner process or treating
--- process identity as proof of ownership.
--- Karabiner's UI, Core Service, grabber, console server, session monitor,
--- watchers, updater, icon switcher and VirtualHID helpers are shared with the user's personal rules;
--- process identity therefore cannot establish Ergopti ownership.
---
--- FEATURES & RATIONALE:
--- 1. Whole-driver scope catches sibling kill, launch and probe paths instead of
---    protecting only the shutdown site where the defect was first observed.
--- 2. Command-shape checks leave explicit user-requested GUI opening and
---    read-only onboarding probes available while rejecting destructive commands.
--- 3. The source-size floor makes an empty production scan fail loudly.
--- 4. Narrow constant folding catches stock-family and destructive executable
---    names assembled inline or through aliases without evaluating dynamics.
--- ==============================================================================

local helpers = require("tests.helpers")
local RuntimeSources = require("tests.support.runtime_source_inventory")





-- ==============================================
-- ==============================================
-- ======= 1/ Stock Process Control Guard =======
-- ==============================================
-- ==============================================

--- Reads each executable/runtime translation unit separately. Keeping file
--- boundaries prevents a harmless Karabiner probe in one module from tainting
--- an unrelated Dock/Ollama kill in the next concatenated module.
--- @return table units Production { path, body } records.
--- @return table unreadable Enumerated runtime paths that could not be opened.
local function read_runtime_units()
	return RuntimeSources.read(helpers.driver_root())
end

local syntax = require("tests.support.karabiner_isolation.syntax")
local detector = require("tests.support.karabiner_isolation.detector")
local without_comments = syntax.without_comments
local find_offenders = detector.find_offenders
local mask_explicit_open_gui_capability = detector.mask_explicit_open_gui_capability

helpers.describe("Karabiner isolation: runtime", function()
	helpers.it("stock-process isolation: contains no kill, launchd mutation, auto-launch or ownership path", function()
		local lua_source = helpers.read_driver_source()
		local units, unreadable = read_runtime_units()
		helpers.assert_true(type(lua_source) == "string" and #lua_source > 100000,
			"the production scan must cover the whole macOS driver")
		helpers.assert_true(#units > 100,
			"the per-translation-unit runtime scan must not be empty or narrowly scoped")
		helpers.assert_eq(#unreadable, 0,
			"every enumerated runtime source must be readable; missing: " .. table.concat(unreadable, ", "))
		local runtime_source = {}
		for _, unit in ipairs(units) do runtime_source[#runtime_source + 1] = unit.body end
		local all_runtime_source = table.concat(runtime_source, "\n")
		helpers.assert_true(all_runtime_source:find("enum KarabinerLeaseWorker", 1, true) ~= nil,
			"the runtime scan must include the native Swift lease worker, not only Lua")
		helpers.assert_true(all_runtime_source:find("karabiner_lease_watchdog.sh", 1, true) == nil,
			"the retired shell watchdog must not remain in production runtime sources")

		local lifecycle_source, lifecycle_err = helpers.read_driver_unit("local KE_GRABBER_CHECK")
		helpers.assert_true(lifecycle_source ~= nil,
			"ke_lifecycle must be uniquely readable without a pinned path: " .. tostring(lifecycle_err))
		local guarded_lifecycle, explicit_capabilities, forbidden_inside =
			mask_explicit_open_gui_capability(lifecycle_source)
		helpers.assert_eq(explicit_capabilities, 1,
			"only ke_lifecycle.M.open_gui may contain stock Karabiner launch APIs")

		local offenders = {}
		local lifecycle_units = 0
		local exact_owned_task_terminations = 0
		for _, unit in ipairs(units) do
			local guarded_body = unit.body
			-- The whole onboarding module is the private native-task owner class.
			-- Mask every exact handle termination in that class without pinning the
			-- implementation's loop/helper spelling; the behavioral lifecycle suite
			-- separately proves membership, retention, and retry of those handles.
			local normalized_path = unit.path:gsub("\\", "/")
			if normalized_path:match("platform/remap/onboarding%.lua$") then
				local masked
				guarded_body, masked = guarded_body:gsub(
					"task:%s*terminate%s*%(%s*%)", "task:cancel_exact_owned_task()")
				exact_owned_task_terminations = exact_owned_task_terminations + masked
			end
			if unit.body == lifecycle_source then
				guarded_body = guarded_lifecycle
				lifecycle_units = lifecycle_units + 1
				for _, label in ipairs(forbidden_inside) do
					offenders[#offenders + 1] = unit.path .. ": explicit open_gui also contains " .. label
				end
			end
			for _, label in ipairs(find_offenders(guarded_body)) do
				offenders[#offenders + 1] = unit.path .. ": " .. label
			end
		end
		helpers.assert_eq(lifecycle_units, 1,
			"the runtime unit scan must include ke_lifecycle exactly once")
		helpers.assert_eq(exact_owned_task_terminations, 1,
			"the onboarding lifecycle must cancel exactly one private active-task class")
		local menu_source, menu_err = helpers.read_driver_unit('i18n.get("menu.karabiner.open_gui")')
		helpers.assert_true(menu_source ~= nil,
			"the explicit Karabiner menu action must be uniquely readable: " .. tostring(menu_err))
		helpers.assert_true(
			without_comments(menu_source):find(
				"action%s*=%s*function%s*%(%s*%)%s*karabiner%.open_gui%s*%(%s*%)") ~= nil,
			"the only stock-GUI capability must remain behind the explicit Karabiner menu action")

		helpers.assert_eq(#offenders, 0,
			"Ergopti may revoke only its exact lease/watchdog; official Karabiner "
				.. "processes are shared with personal rules and must never be killed, "
				.. "auto-launched, launchd-mutated or claimed by process identity. Found: "
				.. table.concat(offenders, ", "))
	end)

end)
