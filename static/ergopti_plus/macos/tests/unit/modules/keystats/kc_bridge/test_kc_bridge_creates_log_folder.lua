--- tests/unit/modules/keystats/kc_bridge/test_kc_bridge_creates_log_folder.lua

--- ==============================================================================
--- MODULE: Regression — the KE bridge creates its own hand-off folder
--- DESCRIPTION:
--- The 2026-11-23 field log read, at a cold start, « KC log EOF is untrusted at
--- cold start — persistence stays denied until retry: open failed: …: No such
--- file or directory » then « Cannot create '…/metrics/karabiner_kc.log' ».
---
--- ROOT CAUSE ENCODED:
--- KcBridge.init() runs at keystats module load, before LogManager.init() creates
--- <config_dir>/metrics/, and drains the log whether Metrics is on or not. It
--- only touched the file, which cannot create a missing folder, and it proved
--- the EOF before even that touch. Karabiner's `echo >>` cannot create the folder
--- either, so a fresh configuration lost every physical press until something
--- else made the folder. The bridge is the folder's owner: it creates it, then
--- the file, before the EOF proof.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.kc_bridge_fixture")




-- ==============================================
-- ==============================================
-- ======= 1/ A Fresh Configuration =============
-- ==============================================
-- ==============================================

helpers.describe("kc_bridge creates its hand-off folder on a fresh configuration (kc-bridge-log-folder)", function()
	helpers.it("creates metrics/ and the log before the cold-start EOF proof", function()
		fixture.with_context(function(ctx)
			local fs = require("tests.stubs.hs").fs
			helpers.assert_true(fs.rmdir(ctx.root .. "/metrics"), "the scenario starts without a metrics folder")

			local kc = ctx.load()
			local logger = package.loaded["core.logger.engine.logger"]
			local warnings = {}
			logger.warn = function(_, message, ...) warnings[#warnings + 1] = string.format(message, ...) end
			logger.error = function(_, message, ...) warnings[#warnings + 1] = string.format(message, ...) end

			helpers.assert_eq(kc.init({ ok = true }, nil, {}, {}, function() return true end), true)
			helpers.assert_eq(#warnings, 0, "a fresh configuration must start silently: " .. table.concat(warnings, " | "))
			local folder = fs.attributes(ctx.root .. "/metrics")
			helpers.assert_true(folder ~= nil and folder.mode == "directory", "the bridge must create metrics/")
			helpers.assert_true(fs.attributes(ctx.root .. "/metrics/karabiner_kc.log") ~= nil,
				"the bridge must create the hand-off log Karabiner appends to")

			-- The proven EOF is the empty file: the first Karabiner line is drained.
			ctx.append("a")
			ctx.watcher_callback()
			helpers.assert_true(kc.get_stats().offset > 0, "the first line after a fresh start must be drained")
		end)
	end)
end)
