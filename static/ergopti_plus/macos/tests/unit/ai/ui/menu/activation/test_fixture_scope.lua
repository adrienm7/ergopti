--- tests/unit/ai/ui/menu/activation/test_fixture_scope.lua

--- ==============================================================================
--- MODULE: LLM Activation Fixture Isolation
--- DESCRIPTION:
--- Verifies exact module restoration after construction, assertion and success.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_activation = require("tests.support.ai.activation_fixture")

local OWNED_MODULES = {
	"core.logger.engine.logger",
	"core.ui.engine.notifications",
	"core.i18n.engine.i18n",
	"shortcuts.ui.menu.utils",
	"ai.engine",
	"ai.ui.menu.models.manager",
	"ai.ui.menu.profiles_manager",
	"ai.ui.menu.settings_manager",
	"ai.ui.menu.panels.temperature_panel",
	"ai.ui.menu.panels.streaming_panel",
	"ai.ui.menu.warmup_controller",
	"ai.ui.menu.panels.backend_panel",
	"ai.ui.menu.panels.trigger_panel",
	"ai.ui.menu.panels.api_panel",
	"ai.ui.menu.models.selector_page",
	"ai.ui.menu.models.switcher",
	"ai.engine.api.mlx",
	"ai.ui.menu.startup_controller",
	"ai.ui.menu.trigger_orchestrator",
	"ai.ui.menu.layout",
	"menu.engine.manifest_menu",
	"ai.engine.local_servers.mlx_deps_checker",
	"ai.engine.ollama.deps_checker",
	"core.events.timer_scheduler",
	"ai.ui.menu.activation_pause_owner",
	"diagnostics.adapters.event_provenance",
	"platform.input.synthetic_input",
	"platform.input.keycodes",
	"gestures.engine.engine",
	"gestures.engine.actions",
	"platform.input.key_state",
	"ai.engine.local_servers.warmup_controller",
	"ai.engine.api.ollama",
	"ai.engine.api.remote",
	"metrics.ui.wpm.menubar",
	"metrics.ui.wpm.widget",
	"keyboard.engine.runtime.onboarding",
	"core.ui.ui.tooltip",
	"shortcuts.engine.script_control",
	"ai.ui.menu",
	"ai.ui.menu.prediction_lock_registry",
	"ai.ui.menu.profile_label",
	"core.ui.engine.dialog_util",
	"core.process.adapters.shell_runner",
	"core.timing.engine.deferred_work",
}
local REGISTRY = "ai.ui.menu.prediction_lock_registry"

helpers.describe("LLM activation fixture scope", function()
	for _, outcome in ipairs({ "callback failure", "construction failure", "success" }) do
		helpers.it("(activation-fixture-scope) restores exact modules after " .. outcome, function()
			helpers.with_fresh_modules(OWNED_MODULES, function()
				local saved = {}
				for index, name in ipairs(OWNED_MODULES) do
					local original = { name = name }
					if name == REGISTRY then original = nil end
					if name == "core.ui.engine.notifications" then original = false end
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
					local logger = package.loaded["core.logger.engine.logger"]
					helpers.assert_type(registry.new, "function")
					if attempt == 2 then
						helpers.assert_true(registry ~= previous_registry)
						helpers.assert_true(logger ~= previous_logger)
					end
					previous_registry, previous_logger = registry, logger
				end)
				helpers.assert_nil(package.loaded[REGISTRY])
				helpers.assert_nil(package.loaded["core.logger.engine.logger"])
			end
		end)
	end)
end)
