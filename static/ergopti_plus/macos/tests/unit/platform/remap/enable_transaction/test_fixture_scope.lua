--- tests/unit/platform/remap/enable_transaction/test_fixture_scope.lua

--- ==============================================================================
--- MODULE: Remap Fixture Isolation
--- DESCRIPTION:
--- Restores native and cached dependencies after failures in each fixture path.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.remap_transaction_fixture")

local OWNED_MODULES = {
	"platform.remap.defaults",
	"platform.remap.config",
	"platform.remap.generator",
	"platform.remap.ke_lifecycle",
	"platform.remap.lease_controller",
	"platform.remap.watchers",
	"adapters.hotkey_registrar",
	"infra.timings",
	"adapters.timer_scheduler",
	"infra.config_paths",
	"modules.keylogger.kc_bridge",
	"modules.gestures.engine",
	"modules.shortcuts",
	"platform.remap.onboarding",
	"platform.remap",
	"infra.logger",
	"infra.i18n",
	"infra.notifications",
	"infra.text_utils",
	"platform.remap.ke_paths",
	"adapters.task_lifecycle",
	"infra.keycodes",
	"modules.gestures.actions",
	"adapters.key_state",
	"modules.llm.warmup_controller",
	"modules.llm.api_mlx",
	"modules.llm.api_ollama",
	"modules.llm.api_remote",
	"ui.wpm.wpm_menubar",
	"ui.wpm.wpm_widget",
	"ui.tooltip",
	"modules.keylogger",
	"adapters.synthetic_input",
	"modules.shortcuts.script_control",
	"platform.remap.ke_variables",
	"adapters.json_codec",
	"adapters.shell_runner",
	"infra.deferred_work",
	"platform.remap.lease_contract",
	"modules.keymap.layout",
	"adapters.file_system",
	"infra.fs_dir",
	"adapters.event_provenance",
	"adapters.storage",
}

helpers.describe("remap transaction fixture scope", function()
	for _, mode in ipairs({ "callback", "construction", "onboarding", "script control" }) do
		helpers.it("(remap-fixture-scope) restores dependencies after " .. mode .. " failure", function()
			helpers.with_stub_scope(OWNED_MODULES, function()
				local before_hs = rawget(_G, "hs")
				local before = {}
				for index, name in ipairs(OWNED_MODULES) do
					local value = { name = name }
					if name == "platform.remap.ke_variables" then value = nil end
					if name == "infra.notifications" then value = false end
					before[index] = value
					package.loaded[name] = value
				end
				local marker = "remap fixture injected " .. mode
				local entered = false
				local ok, reason = pcall(with_fixture, function(fixture)
					entered = true
					if mode == "construction" then
						fixture.load_enabled_remap(setmetatable({}, { __index = function(_, key)
							if key == "skip_init" then error(marker, 0) end
						end }))
					elseif mode == "onboarding" then
						local _, _, installer = fixture.load_remap_with_real_onboarding()
						helpers.assert_eq(#installer.tasks, 1)
					elseif mode == "script control" then
						local remap = fixture.load_enabled_remap()
						local control = fixture.load_resume_script_control(remap)
						helpers.assert_type(control.pause_all, "function")
					else
						fixture.load_enabled_remap({ skip_init = true })
					end
					error(marker, 0)
				end)
				helpers.assert_eq(ok, false)
				helpers.assert_true(entered)
				helpers.assert_true(tostring(reason):find(marker, 1, true) ~= nil,
					"the intended fixture boundary must execute: " .. tostring(reason))
				helpers.assert_true(rawequal(_G.hs, before_hs), "restore the native environment")
				for index, name in ipairs(OWNED_MODULES) do
					helpers.assert_true(rawequal(package.loaded[name], before[index]),
					"restore the exact predecessor for " .. name)
				end
			end)
		end)
	end
end)
