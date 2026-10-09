--- tests/unit/ui/menu/menu_llm/test_llm_activation_fixture_scope.lua

--- ==============================================================================
--- MODULE: LLM Activation Fixture Isolation
--- DESCRIPTION:
--- Verifies exact module restoration after construction, assertion and success.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_activation = require("tests.support.llm_activation_fixture")

local OWNED_MODULES = {
	"infra.logger",
	"infra.notifications",
	"infra.i18n",
	"ui.menu.shortcut_utils",
	"modules.llm",
	"ui.menu.menu_llm.models_manager",
	"ui.menu.menu_llm.profiles_manager",
	"ui.menu.menu_llm.settings_manager",
	"ui.menu.menu_llm.temperature_panel",
	"ui.menu.menu_llm.streaming_panel",
	"ui.menu.menu_llm.warmup_controller",
	"ui.menu.menu_llm.backend_panel",
	"ui.menu.menu_llm.trigger_panel",
	"ui.menu.menu_llm.api_panel",
	"ui.menu.menu_llm.models_selector",
	"ui.menu.menu_llm.model_switcher",
	"modules.llm.api_mlx",
	"ui.menu.menu_llm.startup_controller",
	"ui.menu.menu_llm.trigger_orchestrator",
	"ui.menu.menu_llm.menu_layout",
	"infra.manifest_menu",
	"modules.llm.mlx_deps_checker",
	"modules.llm.ollama_deps_checker",
	"adapters.timer_scheduler",
	"ui.menu.menu_llm.activation_pause_owner",
	"adapters.event_provenance",
	"adapters.synthetic_input",
	"infra.keycodes",
	"modules.gestures.engine",
	"modules.gestures.actions",
	"adapters.key_state",
	"modules.llm.warmup_controller",
	"modules.llm.api_ollama",
	"modules.llm.api_remote",
	"ui.wpm.wpm_menubar",
	"ui.wpm.wpm_widget",
	"platform.remap.onboarding",
	"ui.tooltip",
	"modules.shortcuts.script_control",
	"ui.menu.menu_llm",
	"ui.menu.menu_llm.prediction_lock_registry",
	"ui.menu.menu_llm.profile_label",
	"infra.dialog_util",
	"adapters.shell_runner",
	"infra.deferred_work",
}
local REGISTRY = "ui.menu.menu_llm.prediction_lock_registry"

helpers.describe("LLM activation fixture scope", function()
	for _, outcome in ipairs({ "callback failure", "construction failure", "success" }) do
		helpers.it("(activation-fixture-scope) restores exact modules after " .. outcome, function()
			helpers.with_fresh_modules(OWNED_MODULES, function()
				local saved = {}
				for index, name in ipairs(OWNED_MODULES) do
					local original = { name = name }
					if name == REGISTRY then original = nil end
					if name == "infra.notifications" then original = false end
					saved[index] = original
					package.loaded[name] = original
				end
				local marker = "activation fixture injected " .. outcome
				local callback_calls = 0
				local options = { real_switcher = true }
				if outcome == "construction failure" then
					options = setmetatable({}, { __index = function(_, key)
						if key == "real_switcher" then error(marker, 0) end
					end })
				end
				local ok, result = pcall(with_activation, "ollama", { true }, options,
					function(action, _, calls)
						callback_calls = callback_calls + 1
						helpers.assert_type(package.loaded[REGISTRY].new, "function")
						if outcome == "callback failure" then error(marker, 0) end
						helpers.assert_eq(action(), true)
						helpers.assert_eq(calls.saves, 1)
						return marker
					end)
				helpers.assert_eq(ok, outcome == "success")
				helpers.assert_true(tostring(result):find(marker, 1, true) ~= nil,
					"the intended boundary must execute")
				helpers.assert_eq(callback_calls, outcome == "construction failure" and 0 or 1)
				for index, name in ipairs(OWNED_MODULES) do
					helpers.assert_true(rawequal(package.loaded[name], saved[index]),
					"restore the exact predecessor for " .. name)
				end
			end)
		end)
	end

	helpers.it("(activation-fixture-scope) never reuses a previous prediction registry", function()
		helpers.with_fresh_modules(OWNED_MODULES, function()
			local previous_registry
			local previous_logger
			for attempt = 1, 2 do
				with_activation("ollama", {}, nil, function()
					local registry = package.loaded[REGISTRY]
					local logger = package.loaded["infra.logger"]
					helpers.assert_type(registry.new, "function")
					if attempt == 2 then
						helpers.assert_true(registry ~= previous_registry)
						helpers.assert_true(logger ~= previous_logger)
					end
					previous_registry, previous_logger = registry, logger
				end)
				helpers.assert_nil(package.loaded[REGISTRY])
				helpers.assert_nil(package.loaded["infra.logger"])
			end
		end)
	end)
end)
