--- tests/unit/keyboard/engine/runtime_install/test_runtime_service_repair.lua

--- ==============================================================================
--- MODULE: Owned Runtime Service Repair
--- DESCRIPTION:
--- Pins « Réparer le service » (MRT-004) with fake ports: the facade admits it
--- only for a published runtime whose job is not loaded, the installer runs
--- the signed launcher's repair role once and reads its own answer line, and
--- the dialog asks before anything runs and reports with the repair's texts.
---
--- ROOT CAUSE ENCODED: the Tap-Holds menu mapped `runtime_job_not_loaded` to
--- the first install, whose helper refuses an existing runtime by design, so
--- the advertised retry could never repair an already published runtime.
--- ==============================================================================

local helpers = require("tests.helpers")

local LAUNCHER = "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus"

--- Builds an installer whose launcher role answers with `answer`.
--- @param answer function fn() -> code, stdout.
--- @param hold boolean|nil Keep the role's callback pending.
--- @return table installer, table world, table Install
local function fake(answer, hold)
	package.loaded["keyboard.adapters.runtime.install"] = nil
	local Install = require("keyboard.adapters.runtime.install")
	local world = { commands = {}, pending = {} }
	local installer = Install.new({
		launcher = function() return LAUNCHER, nil, { ERGOPTI_LAUNCHER_EXECUTABLE = LAUNCHER } end,
		exists = function() return true end,
		fetch_driver = function() error("a repair never fetches the driver package") end,
		exec = function(executable, args, timeout, callback)
			world.commands[#world.commands + 1] = { executable = executable, args = args, timeout = timeout }
			if hold then world.pending[#world.pending + 1] = callback; return end
			callback(answer())
		end,
	})
	return installer, world, Install
end

--- Runs one repair and returns its settlement.
local function repair(installer)
	local result
	installer.repair(function(ok, reason, detail) result = { ok = ok, reason = reason, detail = detail } end)
	return result
end

helpers.describe("owned runtime service repair (MRT-004)", function()
	helpers.it("runs the repair role alone and settles on the helper's full success", function()
		local installer, world, Install = fake(function()
			return 0, "OWNED_RUNTIME_REPAIR|1|service-repaired-observed\n"
		end)
		local result = assert(repair(installer), "the repair must settle")
		helpers.assert_eq(result.ok, true)
		helpers.assert_eq(#world.commands, 1, "no driver activation and no other command")
		helpers.assert_eq(world.commands[1].executable, LAUNCHER)
		helpers.assert_eq(world.commands[1].args, { Install.REPAIR_FLAG })
		helpers.assert_eq(Install.REPAIR_FLAG, "--request-owned-runtime-repair")
		helpers.assert_eq(world.commands[1].timeout, Install.INSTALL_TIMEOUT_SEC)
	end)

	helpers.it("names each refusal of the repair role", function()
		local cases = {
			{ 0, "OWNED_RUNTIME_REPAIR|1|service-repair-pending\n", "repair_pending" },
			{ 1, "OWNED_RUNTIME_REPAIR_REQUEST|1|cancelled\n", "install_cancelled" },
			{ 77, "OWNED_RUNTIME_REPAIR_REQUEST|1|refused|driver_absent\n", "install_refused" },
			{ 75, "OWNED_RUNTIME_REPAIR_REQUEST|1|failed|77|helper\n", "install_refused" },
			{ 75, "OWNED_RUNTIME_REPAIR_REQUEST|1|failed|75\n", "install_cleanup_pending" },
			-- The first install's line never settles a repair, nor the reverse.
			{ 0, "OWNED_RUNTIME_INSTALL|1|files-published-services-observed-staging-retired\n", "install_unanswered" },
			{ 0, "OWNED_RUNTIME_REPAIR|1|files-published-services-observed-staging-retired\n", "install_unanswered" },
			{ 0, "", "install_unanswered" },
		}
		for _, case in ipairs(cases) do
			local installer = fake(function() return case[1], case[2] end)
			local result = assert(repair(installer), case[2])
			helpers.assert_eq(result.ok, false, case[2])
			helpers.assert_eq(result.reason, case[3], case[2])
		end
		local Install = require("keyboard.adapters.runtime.install")
		local ok, reason = Install.parse(0, "OWNED_RUNTIME_REPAIR|1|service-repaired-observed\n")
		helpers.assert_eq(ok, false, "the install parser refuses a repair line")
		helpers.assert_eq(reason, "install_unanswered")
		helpers.assert_eq(Install.parse_repair(77, "OWNED_RUNTIME_REPAIR_REQUEST|1|failed|77|helper\n"), false)
	end)

	helpers.it("joins a running repair and refuses an install while it runs", function()
		local installer, world = fake(nil, true)
		local first, second, install
		installer.repair(function(ok) first = ok end)
		installer.repair(function(ok) second = ok end)
		installer.install(function(ok, reason) install = { ok = ok, reason = reason } end)
		helpers.assert_eq(#world.commands, 1, "one role for the joined repairs, none for the install")
		helpers.assert_eq(install.ok, false)
		helpers.assert_eq(install.reason, "install_refused")
		world.pending[1](0, "OWNED_RUNTIME_REPAIR|1|service-repaired-observed\n")
		helpers.assert_eq(first, true)
		helpers.assert_eq(second, true)
	end)

	helpers.it("the facade admits the repair only for a stopped service of a published runtime", function()
		package.loaded["keyboard.engine"] = nil
		local Remap = helpers.load_with_stubs("keyboard.engine")
		helpers.assert_eq(Remap.OWNED_REPAIR_REASONS, { runtime_job_not_loaded = true })
		helpers.assert_nil(Remap.OWNED_INSTALL_REASONS.runtime_job_not_loaded,
			"the first install refuses an existing runtime by design")
		helpers.assert_true(Remap.OWNED_INSTALL_REASONS.runtime_not_installed == true)
	end)

	helpers.it("the dialog asks first, repairs on confirmation and reports with the repair's texts", function()
		package.loaded["ai.ui.owned_runtime_install"] = nil
		local alerts, scheduled = {}, {}
		local dialog_util = { block_alert = function(title, body, first)
			alerts[#alerts + 1] = { title = title, body = body }
			return first
		end }
		local Dialog = helpers.load_with_stubs("ai.ui.owned_runtime_install", {
			["core.ui.engine.dialog_util"] = dialog_util,
			["core.timing.engine.deferred_work"] = { after = function(_, fn) scheduled[#scheduled + 1] = fn; return true end },
		})
		package.loaded["core.ui.engine.dialog_util"] = dialog_util
		package.loaded["core.timing.engine.deferred_work"] = { after = function(_, fn) scheduled[#scheduled + 1] = fn; return true end }
		local repaired, reloaded = 0, 0
		local started = Dialog.open_repair({
			repair_owned_runtime = function(on_done) repaired = repaired + 1; on_done(true); return true end,
		}, function() reloaded = reloaded + 1 end)
		helpers.assert_eq(started, true)
		helpers.assert_eq(repaired, 1)
		helpers.assert_eq(alerts[1].title, "karabiner.owned_repair.title")
		helpers.assert_eq(alerts[1].body, "karabiner.owned_repair.body")
		helpers.assert_eq(#scheduled, 1)
		scheduled[1]()
		helpers.assert_eq(alerts[2].body, "karabiner.owned_repair.done")
		helpers.assert_eq(reloaded, 1, "a repaired service reloads so the next owner admits it")
		local ok = pcall(Dialog.open_repair, { install_owned_runtime = function() return true end })
		helpers.assert_eq(ok, false, "a facade without the repair is refused before any dialog")
		package.loaded["core.ui.engine.dialog_util"] = nil
		package.loaded["core.timing.engine.deferred_work"] = nil
		package.loaded["ai.ui.owned_runtime_install"] = nil
	end)
end)
