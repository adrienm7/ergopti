--- tests/meta/test_healthcheck_api_contract.lua

--- ==============================================================================
--- MODULE: Healthcheck Diagnostic API Contract
--- DESCRIPTION:
--- Pins every external module symbol that the diagnostics collectors, probes
--- and actions call (ui/healthcheck/helpers.lua, probes.lua, report.lua), so a
--- renamed or removed API fails CI here instead of silently degrading the
--- user-facing diagnostic.
---
--- WHY THIS EXISTS (regression for project-healthcheck-stale-api):
--- The diagnostic collectors probed functions that did not exist — log_manager
--- .get_paths(), aggregator.get_stats(), keylogger.privacy (whole module),
--- llm.get_state(), layout.is_ergopti_base(), key_state.get_altgr/get_shift/
--- get_caps(), terminators.count()/get_magic_key(). Each call was guarded, so
--- nothing crashed — but the diagnostic window showed "unknown" for almost
--- every runtime field. The guards made the breakage invisible to a "does it
--- crash?" test. This contract makes it visible: it asserts the REAL functions
--- the collectors depend on exist on the real modules, then runs the real
--- collectors and requires that none of them failed.
---
--- MAINTENANCE: when a collector starts calling a new module function, add it
--- here. Keep this list in lock-step with the collectors.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The exact external surface the diagnostics window relies on.
-- mod = require path; fns = functions that must exist; constants = fields read.
local CONTRACT = {
	{ mod = "infra.logger",                       fns = { "ring_buffer_snapshot", "session_issues",
		"logs_dir", "today_log_path", "today_errors_path", "crash_reports_dir" } },
	{ mod = "infra.config_paths",               fns = { "is_initialized", "get_config_dir" } },
	{ mod = "infra.diagnostic_snapshot",        fns = { "resolve_commit" } },
	{ mod = "modules.diagnostics.crash_reporter", fns = { "reports_dir" } },
	{ mod = "adapters.boot_fatal",              constants = { "LAUNCHER_LOG_ENV" } },
	{ mod = "adapters.system_info",             fns = { "runtime_version", "arch", "os_version", "keyboard_layout",
		"elevated" } },
	{ mod = "modules.updater",                  fns = { "current_version", "installed_channel" } },
	{ mod = "platform.remap.ke_paths",          constants = { "CLI" } },
	{ mod = "adapters.file_system",             fns = { "exists" } },
	{ mod = "modules.shortcuts.script_control", fns = { "is_paused" } },
	{ mod = "adapters.key_state",               fns = { "isDown", "is_right_altgr_held", "capslock_on" } },
	{ mod = "platform.remap.lease_controller",  fns = { "status" } },
	{ mod = "modules.llm",                      fns = { "get_runtime_llm_enabled", "get_backend", "get_current_model",
		"get_active_profile" } },
	{ mod = "modules.llm.api_ollama",           fns = { "get_base_url" } },
	{ mod = "modules.llm.api_mlx",              fns = { "get_base_url" } },
	{ mod = "adapters.accessibility_permission", fns = { "is_trusted" } },
	{ mod = "adapters.screen_capture",          fns = { "permission_state" } },
	{ mod = "adapters.http_client",             fns = { "new" } },
	{ mod = "adapters.shell_runner",            fns = { "spawn" } },
	{ mod = "adapters.json_codec",              fns = { "decode" } },
	{ mod = "adapters.clipboard",               fns = { "write" } },
	{ mod = "adapters.notifier",                fns = { "send" } },
	{ mod = "infra.locale",                     fns = { "all" } },
	{ mod = "infra.manifest_reader",            fns = { "coverage_gaps" } },
	{ mod = "adapters.network_info",            fns = { "getSignalStrength" } },
	{ mod = "ui.ui_builder",                    fns = { "build_injected_html", "get_app_geometry", "window_title",
		"window_chrome_steps", "force_focus", "open_http_url" } },
}

-- The adapters that capture the hs global when they load: reloaded inside
-- the fixture so they read its answers
local HS_READERS = {
	"adapters.key_state", "adapters.accessibility_permission", "adapters.screen_capture", "adapters.system_info",
}

--- Answers the Hammerspoon queries the collectors make, as a Mac would.
--- @param hs_stub table The fixture's hs.
local function answer_as_a_mac(hs_stub)
	hs_stub.hid = { capslock = { get = function() return false end } }
	hs_stub.usb = { attachedDevices = function()
		return { { productName = "Magic Keyboard", vendorID = 1452, productID = 615 } }
	end }
	hs_stub.host.vmStat = function() return { memSize = 17179869184, pageSize = 16384, pagesFree = 65536 } end
	hs_stub.host.locale = { current = function() return "fr_FR" end }
	hs_stub.application.runningApplications = function()
		return { { kind = function() return 1 end, name = function() return "Safari" end } }
	end
	hs_stub.accessibilityState = function() return true end
end





-- ==========================================
-- ==========================================
-- ======= 1/ Per-module API contract =======
-- ==========================================
-- ==========================================

helpers.describe("meta: healthcheck diagnostic API contract", function()
	for _, entry in ipairs(CONTRACT) do
		helpers.it(string.format("%s exposes the symbols healthcheck calls", entry.mod), function()
			-- Build the hs/lib stub environment, then force a REAL require of the
			-- target module. Clear the exact canonical key so no partial subject
			-- stub left by an earlier test can satisfy this API contract.
			helpers.load_with_stubs("infra.logger")
			package.loaded[entry.mod] = nil
			local ok, mod = pcall(require, entry.mod)
			helpers.assert_true(ok and type(mod) == "table",
				string.format("require('%s') failed — healthcheck cannot read it: %s", entry.mod, tostring(mod)))

			for _, fn in ipairs(entry.fns or {}) do
				helpers.assert_true(type(mod[fn]) == "function",
					string.format("%s.%s must be a function — healthcheck calls it (stale diagnostic API)",
						entry.mod, fn))
			end
			for _, c in ipairs(entry.constants or {}) do
				helpers.assert_true(mod[c] ~= nil,
					string.format("%s.%s must be defined — healthcheck reads it (stale diagnostic API)",
						entry.mod, c))
			end
		end)
	end
end)





-- ======================================================
-- ======================================================
-- ======= 2/ End-to-end: run with no stale probe =======
-- ======================================================
-- ======================================================

helpers.describe("meta: healthcheck.run() probes no nonexistent API", function()
	-- Self-syncing companion to the contract above: run the collectors against
	-- the real modules and require that none of them failed. A collector that
	-- cannot read a fact logs a warning and leaves the field unknown, which is
	-- exactly the silent degradation this test exists to catch.
	local failures = {}
	local ok_run, snap
	local scope = {
		"infra.logger", "logger", "modules.llm", "ui.healthcheck", "ui.healthcheck.core", "ui.healthcheck.helpers",
	}
	for _, name in ipairs(HS_READERS) do scope[#scope + 1] = name end
	helpers.with_stub_scope(scope, function()
		local Logger = helpers.load_with_stubs("infra.logger")
		answer_as_a_mac(hs)
		for _, name in ipairs(HS_READERS) do package.loaded[name] = nil end
		-- Force the real llm module (load_with_stubs injects a DEFAULT_STATE-only stub).
		package.loaded["modules.llm"] = nil
		package.loaded["ui.healthcheck"] = nil
		package.loaded["ui.healthcheck.core"] = nil
		package.loaded["ui.healthcheck.helpers"] = nil
		local orig_warn, orig_error = Logger.warn, Logger.error
		local function capture(original)
			return function(tag, fmt, ...)
				-- The phase A budget is a production timing: here the first run also
				-- loads every module it touches
				if tostring(tag):find("^healthcheck") and not tostring(fmt):find("budget", 1, true) then
					failures[#failures + 1] = string.format(tostring(fmt), ...)
				end
				return original(tag, fmt, ...)
			end
		end
		Logger.warn, Logger.error = capture(orig_warn), capture(orig_error)
		ok_run, snap = pcall(function() return require("ui.healthcheck").run({ detailed = true }) end)
		Logger.warn, Logger.error = orig_warn, orig_error
	end)

	helpers.it("healthcheck.run() returns a version 2 snapshot", function()
		helpers.assert_true(ok_run and type(snap) == "table", "healthcheck.run() must succeed: " .. tostring(snap))
		helpers.assert_eq(snap.schema_version, 2)
		helpers.assert_eq(snap.driver, "macos")
	end)

	helpers.it("no collector failed to read its facts", function()
		helpers.assert_true(#failures == 0,
			"healthcheck collectors failed (the page shows 'unknown'): " .. table.concat(failures, " | "))
	end)
end)
