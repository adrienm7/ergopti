--- tests/unit/platform/remap/test_ke_lifecycle.lua

--- ==============================================================================
--- MODULE: Karabiner Lease Status Facade Tests
--- DESCRIPTION:
--- Verifies that ordinary status reads derive exclusively from Ergopti's exact
--- lease while the two permitted stock interactions remain explicit: a read-only
--- onboarding probe and a user-requested GUI open.
---
--- FEATURES & RATIONALE:
--- 1. Status reads assert zero shell calls, preventing menu construction from
---    silently turning a shared Karabiner PID into ownership evidence.
--- 2. The onboarding probe remains read-only and cannot authorize teardown.
--- 3. GUI launch is exercised only by calling open_gui directly.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads a fresh facade over a controllable in-memory lease phase.
--- @param phase string Controller phase returned by status().
--- @param hs_overrides table|nil Host API overrides.
--- @return table facade
--- @return table hs_stub
local function fresh_lifecycle(phase, hs_overrides)
	package.loaded["platform.remap.ke_lifecycle"] = nil
	package.loaded["platform.remap.lease_controller"] = {
		status = function() return phase, { phase = phase, token = "a" } end,
	}
	package.loaded["infra.notifications"] = { notify = function() end }
	package.loaded["infra.i18n"] = { get = function(key) return key end }

	local facade = helpers.load_with_stubs("platform.remap.ke_lifecycle", hs_overrides)
	local hs_stub = _G.hs
	hs_stub.__reset()
	return facade, hs_stub
end





-- =======================================
-- =======================================
-- ======= 1/ Lease-Derived Status =======
-- =======================================
-- =======================================

helpers.describe("KELifecycle status is exact-lease state, not process state", function()
	helpers.it("reports active without spawning any shell probe", function()
		local KE, hs_stub = fresh_lifecycle("active")

		helpers.assert_eq(KE.is_remapping_active(), true)
		helpers.assert_eq(KE.is_bridge_running(), true)
		helpers.assert_eq(KE.is_priming(), false)
		helpers.assert_eq(#hs_stub.__exec_calls, 0,
			"ordinary status reads must not probe shared Karabiner processes")
	end)

	helpers.it("distinguishes starting, paused and idle phases in memory", function()
		local starting = fresh_lifecycle("starting")
		helpers.assert_eq(starting.is_priming(), true)
		helpers.assert_eq(starting.is_remapping_active(), false)

		local paused = fresh_lifecycle("paused")
		helpers.assert_eq(paused.is_bridge_running(), true)
		helpers.assert_eq(paused.is_remapping_active(), false)

		local idle = fresh_lifecycle("idle")
		helpers.assert_eq(idle.is_bridge_running(), false)
	end)
end)





-- ==============================================
-- ==============================================
-- ======= 2/ Explicit Stock Interactions =======
-- ==============================================
-- ==============================================

helpers.describe("KELifecycle permits only explicit read/open stock interactions", function()
	helpers.it("runs the read-only daemon probe only when onboarding asks for it", function()
		local KE, hs_stub = fresh_lifecycle("idle")
		hs_stub.__set_exec("pgrep", "", true)

		helpers.assert_eq(#hs_stub.__exec_calls, 0)
		helpers.assert_eq(KE.is_grabber_running(), true)
		helpers.assert_eq(#hs_stub.__exec_calls, 1,
			"the pgrep must be attributable to the explicit onboarding probe")
		local command = hs_stub.__exec_calls[1]
		helpers.assert_true(command:find("pgrep -q -u root -f -x", 1, true) ~= nil,
			"the probe must distinguish the root daemon and use full argv for its long name")
		local _, root_filter_count = command:gsub("%-u root", "")
		helpers.assert_eq(root_filter_count, 2,
			"both current and legacy probes must reject their same-named user-session agents")
		helpers.assert_true(command:find(
			"Karabiner-Core-Service\\.app/Contents/MacOS/Karabiner-Core-Service", 1, true) ~= nil,
			"the health probe must use the current app-bundle executable path")
		helpers.assert_true(command:find("/bin/karabiner_grabber", 1, true) ~= nil,
			"the health probe must retain the exact pre-v15.7 daemon path")
		helpers.assert_true(command:find("org\\.pqrs", 1, true) ~= nil,
			"literal dots in executable paths must not remain ERE wildcards")
		helpers.assert_true(command:find("; } 2>/dev/null", 1, true) ~= nil,
			"one grouped redirection must silence diagnostics from both read-only probes")
		helpers.assert_true(command:find("pgrep -fq 'org.pqrs/Karabiner-Elements'", 1, true) == nil,
			"a broad install-directory match would accept the UI and auxiliary agents")
	end)

	helpers.it("opens the GUI only when the explicit open_gui action runs", function()
		local launches = 0
		local KE, hs_stub = fresh_lifecycle("idle", {
			application = {
				launchOrFocus = function(name)
					helpers.assert_eq(name, "Karabiner-Elements")
					launches = launches + 1
					return true
				end,
			},
		})

		helpers.assert_eq(launches, 0,
			"requiring or reading status must never open the stock Karabiner GUI")
		helpers.assert_eq(KE.open_gui(), true)
		helpers.assert_eq(launches, 1)
		helpers.assert_eq(#hs_stub.__exec_calls, 0,
			"the successful explicit GUI API path must not need a shell fallback")
	end)
end)
