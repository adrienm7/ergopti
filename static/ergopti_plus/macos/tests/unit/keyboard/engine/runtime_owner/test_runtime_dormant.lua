--- tests/unit/keyboard/engine/runtime_owner/test_runtime_dormant.lua

--- ==============================================================================
--- MODULE: Owned Runtime Selection
--- DESCRIPTION:
--- Proves how the remap bridge selects the owned Karabiner runtime (ADR 011),
--- the default since the release after 1.0.9: the command line tool follows
--- the selection, which is made once, and the bridge's source reaches the owner
--- only behind it, so a hand-kept `runtime = "shared"` never loads the owner.
---
--- ROOT CAUSE ENCODED: the bridge's init.lua cannot be loaded by the unit
--- suite, so a dormant guarantee that lived only in its control flow would be
--- unproven. The runtime-selected paths are behavioural; the opt-in gate is
--- pinned in source, the way the suite pins other boot paths.
--- ==============================================================================

local helpers = require("tests.helpers")
local SourceFile = require("tests.support.source_file")

local SHARED_CLI = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"

--- Loads a fresh path module.
--- @return table KePaths
local function fresh_paths()
	package.loaded["keyboard.adapters.karabiner.ke_paths"] = nil
	return require("keyboard.adapters.karabiner.ke_paths")
end





-- =================================
-- =================================
-- ======= 1/ Selected Paths =======
-- =================================
-- =================================

helpers.describe("runtime-selected Karabiner paths", function()
	helpers.it("names the shared tool until a caller selects the owned runtime", function()
		local paths = fresh_paths()
		helpers.assert_eq(paths.CLI, SHARED_CLI)
		helpers.assert_eq(paths.selected_runtime(), "shared")
		helpers.assert_eq(paths.config_file_for("shared"), "~/.config/karabiner/karabiner.json")
		helpers.assert_eq(paths.cli_for("shared"), SHARED_CLI)
	end)

	helpers.it("keeps the shared tool after selecting shared, as the default boot does", function()
		local paths = fresh_paths()
		helpers.assert_true(paths.select_runtime("shared"))
		helpers.assert_true(paths.select_runtime("shared"))
		helpers.assert_eq(paths.CLI, SHARED_CLI)
	end)

	helpers.it("points every variable writer at the owned tool after an explicit selection", function()
		local paths = fresh_paths()
		helpers.assert_true(paths.select_runtime("owned"))
		helpers.assert_eq(paths.CLI, paths.OWNED.CLI)
		helpers.assert_eq(paths.CLI, "/Library/Application Support/ErgoptiPlus/Runtime/bin/ergoptiplus_remap_cli")
		helpers.assert_eq(paths.config_file_for("owned"),
			"~/Library/Application Support/ErgoptiPlus/karabiner/karabiner.json")
		helpers.assert_eq(paths.cli_for("shared"), SHARED_CLI)
	end)

	helpers.it("refuses to switch runtime inside one Lua VM and refuses unknown names", function()
		local paths = fresh_paths()
		paths.select_runtime("owned")
		helpers.assert_throws(function() paths.select_runtime("shared") end)
		helpers.assert_eq(paths.CLI, paths.OWNED.CLI)
		local other = fresh_paths()
		helpers.assert_throws(function() other.select_runtime("both") end)
		helpers.assert_throws(function() other.cli_for(nil) end)
		helpers.assert_eq(other.CLI, SHARED_CLI)
	end)

	helpers.it("never places the owned runtime under the official application's directory", function()
		local owned = fresh_paths().OWNED
		for name, path in pairs(owned) do
			helpers.assert_true(not path:find("org.pqrs", 1, true), name .. " must not name the official application")
			helpers.assert_true(not path:find("/.config/karabiner", 1, true), name .. " must not touch ~/.config")
		end
	end)
end)





-- ==============================
-- ==============================
-- ======= 2/ Opt-In Gate =======
-- ==============================
-- ==============================

--- Reads the remap bridge source.
--- @return string source
local function init_source()
	return assert(SourceFile.read(helpers.driver_root() .. "keyboard/engine/init.lua"))
end

helpers.describe("the remap bridge reaches the owned runtime only after an opt-in", function()
	helpers.it("never requires the owner or its ports at load time", function()
		local source = init_source()
		local requires = 0
		for line in source:gmatch("[^\n]+") do
			if line:find("runtime_owner", 1, true) and line:find("require", 1, true) then
				requires = requires + 1
				helpers.assert_true(line:match("^%s") ~= nil, "a top-level require would load the owner at boot: " .. line)
			end
		end
		helpers.assert_true(requires > 0, "the scan must find the owner require it guards")
		helpers.assert_true(source:find('require("keyboard.adapters.runtime.owner")', 1, true) ~= nil)
	end)

	helpers.it("binds the owner only inside the opt-in bind function", function()
		local source = init_source()
		local _, inits = source:gsub("Owner%.init%(", "")
		helpers.assert_eq(inits, 1)
		local bind = source:find("function M._owned.bind()", 1, true)
		local bound = source:find("Owner.init(", 1, true)
		helpers.assert_true(bind ~= nil and bound ~= nil and bind < bound)
		local reconcile = source:find("function M._owned.reconcile()", 1, true)
		helpers.assert_true(reconcile ~= nil and source:find("local activation = M._owned.bind()", reconcile, true) ~= nil)
	end)

	helpers.it("reaches the activation rule only behind the opt-in, at boot, on pause and on resume", function()
		local source = init_source()
		helpers.assert_true(source:find("if M._owned.selected() then\n\t\tif M._owned.reconcile() ~= true then", 1, true)
			~= nil, "the boot call sits behind the opt-in")
		local pause = source:find("function M.pause(on_done, onboarding_gate)", 1, true)
		local pause_gate = source:find("if not _state or not _state.enabled then", pause, true)
		local paused = source:find("M._owned.paused = true", pause, true)
		helpers.assert_true(paused ~= nil and paused < pause_gate, "a pause stops ours before any integration check")
		local resume = source:find("function M.resume(on_done)", 1, true)
		local resume_gate = source:find("if not _state or not _state.enabled then", resume, true)
		local resumed = source:find("M._owned.paused = false", resume, true)
		helpers.assert_true(resumed ~= nil and resumed < resume_gate, "a resume starts ours before any integration check")
		helpers.assert_true(source:find("paused = M._owned.paused == true", 1, true) ~= nil,
			"the rule reads the pause, not a menu switch")
	end)

	helpers.it("never ties the owned runtime to the Tap-Hold or integration switches", function()
		local source = init_source()
		local tap_holds = source:find("function M.set_tap_holds_enabled(value)", 1, true)
		local tap_end = source:find("\nend\n", tap_holds, true)
		helpers.assert_eq(source:sub(tap_holds, tap_end):find("_owned", 1, true), nil)
		local enabled = source:find("function M.set_enabled(value, on_done, onboarding_gate)", 1, true)
		local enabled_end = source:find("\nend\n", enabled, true)
		helpers.assert_eq(source:sub(enabled, enabled_end):find("_owned", 1, true), nil)
	end)

	helpers.it("gives a closed Karabiner back on a quit but never on a reload", function()
		local source = init_source()
		helpers.assert_true(source:find(
			'if M._owned.activation and M._owned.teardown_reason ~= "hammerspoon_reload" then', 1, true) ~= nil)
		local revoke = source:find("function M.revoke(reason, on_done)", 1, true)
		helpers.assert_true(source:find("M._owned.teardown_reason = reason", revoke, true) ~= nil)
	end)

	helpers.it("selects Ergopti's own runtime when the preference is absent, from the one default", function()
		local source = init_source()
		helpers.assert_true(source:find("user_cfg.runtime or Config.RUNTIME_DEFAULT", 1, true) ~= nil)
		package.loaded["keyboard.adapters.karabiner.ke_paths"] = nil
		helpers.assert_eq(require("keyboard.engine.runtime.config") ~= nil, true)
		helpers.assert_eq(require("keyboard.engine.runtime.config").RUNTIME_DEFAULT, "owned")
	end)

	helpers.it("generates nothing for an owned boot until the owner admitted the runtime", function()
		local source = init_source()
		local gate = source:find("owned-runtime-not-admitted", 1, true)
		local build = source:find("Generator.build_karabiner_json,", 1, true)
		helpers.assert_true(gate ~= nil and build ~= nil and gate < build)
	end)

	helpers.it("skips the official-application wizard for an owned boot", function()
		local source = init_source()
		helpers.assert_true(source:find("if _state.enabled and not M._owned.selected() and not _wizard_ran_this_session", 1, true) ~= nil)
	end)

	helpers.it("removes an earlier build's rules from the user's own karabiner.json on an owned boot", function()
		-- The README promised this migration while no code did it: shared-mode rules
		-- stayed active inside the user's Karabiner-Elements after the switch.
		local source = init_source()
		local boot = source:find("if M._owned.selected() then\n\t\tif M._owned.reconcile() ~= true then", 1, true)
		local retire = source:find("M._owned.retire_shared_rules()", boot, true)
		local wizard = source:find("if _state.enabled and not M._owned.selected() and not _wizard_ran_this_session", 1, true)
		helpers.assert_true(boot ~= nil and retire ~= nil and retire < wizard, "the owned boot calls the migration")
		local owned = source:find("if runtime == M._owned.paths.RUNTIME_OWNED then", 1, true)
		local kept = source:find("M._owned.shared_config = KARABINER_OUT", owned, true)
		local moved = source:find("KARABINER_OUT = file_system.expand_path(M._owned.paths.config_file_for(runtime))", owned, true)
		helpers.assert_true(kept ~= nil and moved ~= nil and kept < moved,
			"the shared path is kept before the output moves to the owned file")
		local body = source:find("function M._owned.retire_shared_rules()", 1, true)
		local body_end = source:find("\nend\n", body, true)
		local text = source:sub(body, body_end)
		helpers.assert_true(text:find('remove_managed_rules("Owned runtime migration", shared)', 1, true) ~= nil,
			"the marker-exact byte-span removal owner does the cleaning")
		helpers.assert_true(source:find("ManagedRuleRemoval.remove_managed_rules(path or KARABINER_OUT)", 1, true) ~= nil)
	end)

	helpers.it("stops the lease recovery instead of exhausting it while ours is not admitted", function()
		-- Issue #106: three refused regenerations ended in "auto-recovery
		-- exhausted", an error that hid the owner's named reason.
		local source = init_source()
		local attempt = source:find("local function finish_attempt(ok, reason)", 1, true)
		local stop = source:find('if reason == "owned-runtime-not-admitted" then', attempt, true)
		local cancel = source:find('cancel_lease_recovery("owned-runtime-not-admitted")', stop, true)
		local failed = source:find('"Karabiner lease auto-recovery attempt %d failed: %s."', attempt, true)
		helpers.assert_true(attempt ~= nil and stop ~= nil and cancel ~= nil and failed ~= nil
			and stop < cancel and cancel < failed,
			"the refusal before admission cancels the series before it counts as a failed attempt")
	end)

	helpers.it("saves a bulk edit for the admission instead of reverting it while ours is not admitted", function()
		-- Restore recommended on a Mac without the runtime reverted its edit and
		-- opened a blocking dialog (E2E, hardening-a/b, owned default).
		local source = init_source()
		local off = source:find('"persisted-integration-off"', 1, true)
		local owned = source:find('"persisted-owned-runtime-not-admitted"', 1, true)
		local dispatch = source:find('transaction.phase = "candidate-regeneration-pending"', 1, true)
		helpers.assert_true(off ~= nil and owned ~= nil and dispatch ~= nil and off < owned and owned < dispatch,
			"the owned settlement sits with the integration-off one, before the candidate dispatch")
		local gate = source:find("local REGENERATION_REFUSED_BEFORE_DEPLOY = {", 1, true)
		local gate_end = source:find("\n}\n", gate, true)
		helpers.assert_true(source:sub(gate, gate_end):find('["owned-runtime-not-admitted"] = true', 1, true) ~= nil)
	end)

	helpers.it("deploys an owned boot only through the owned writer", function()
		local source = init_source()
		local owned_deploy = source:find("Generator.deploy_owned_config(result, KARABINER_OUT)", 1, true)
		local shared_deploy = source:find("return Generator.merge_and_deploy_config(", 1, true)
		helpers.assert_true(owned_deploy ~= nil and shared_deploy ~= nil and owned_deploy < shared_deploy)
	end)
end)
