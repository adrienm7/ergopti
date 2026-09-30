--- tests/unit/ui/menu/menu_llm/test_scope_native_ports.lua

--- Verifies the actual shortcut registrar, prediction engine and menu provider.
local helpers = require("tests.helpers")
local Fixture = require("tests.support.profile_delete_fixture")
local with_activation = require("tests.support.llm_activation_fixture")

helpers.describe("LLM scope native ports", function()
	helpers.it("captures and restores actual dormant chords after preferences drift", function()
		Fixture.with_trigger_fixture({}, function(fixture)
			local owner = fixture.orchestrator
			helpers.assert_true(owner.apply_llm_profile_shortcut("user_p", { "alt" }, "p", { persist = false, activate = false }))
			fixture.state.llm_profile_shortcuts = { user_p = { mods = { "cmd" }, key = "x" } }
			local snapshot = owner.configuration_snapshot()
			helpers.assert_eq(snapshot.llm_profile_shortcuts.user_p.key, "p")
			helpers.assert_eq(snapshot.llm_profile_shortcuts.user_p.enabled, false)
			helpers.assert_eq(snapshot.llm_trigger_shortcut, nil,
				"the retired primary trigger shortcut has no native owner to capture")
			helpers.assert_true(owner.apply_configuration({ llm_profile_shortcuts = {} }))
			helpers.assert_nil(owner.configuration_snapshot().llm_profile_shortcuts.user_p)
			helpers.assert_true(owner.apply_configuration(snapshot))
			local restored = owner.configuration_snapshot()
			helpers.assert_eq(restored.llm_profile_shortcuts.user_p.key, "p")
			helpers.assert_eq(restored.llm_profile_shortcuts.user_p.enabled, false)
			helpers.assert_eq(fixture.get_save_count(), 0)
		end)
	end)

	helpers.it("refuses shortcut capture while an exact release remains unsettled", function()
		Fixture.with_trigger_fixture({}, function(fixture)
			local owner = fixture.orchestrator
			fixture.backend.plan("disable", { "throw", "throw" })
			fixture.backend.plan("delete", { "false" })
			helpers.assert_eq(owner.apply_llm_profile_shortcut("user_p", { "ctrl" }, "b", { persist = false }), false)
			helpers.assert_nil(owner.configuration_snapshot())
		end)
	end)

	helpers.it("routes the real LLM restore command through the complete scope port", function()
		with_activation("ollama", { true }, nil, function(_, _, calls)
			local selected, mode
			calls.root_deps.apply_preference_scope = function(scope, value) selected, mode = scope, value; return true end
			calls.handler.build_item()
			local commands = calls.render_ctx.commands
			helpers.assert_eq(commands.scope_restore(), true)
			helpers.assert_eq(selected, "llm")
			helpers.assert_eq(mode, "recommended")
			-- ai-menu-no-clear: the AI menu's clear row was retired with its command
			helpers.assert_nil(commands.scope_clear, "the AI menu registers no clear command")
			calls.set_paused(true)
			calls.handler.build_item()
			helpers.assert_eq(calls.render_ctx.commands.scope_restore(), false)
		end)
	end)

	helpers.it("configures the real dormant prediction identity without calling backend model setters", function()
		local engine = helpers.load_with_stubs("modules.llm.prediction_engine")
		helpers.assert_eq(engine.get_llm_enabled(), false)
		local reset = engine.reset
		engine.reset = function() return true end
		local core = package.loaded["modules.llm"]
		local old_ollama, old_mlx = core.set_llm_model_ollama, core.set_llm_model_mlx
		core.set_llm_model_ollama = function() error("core identity already belongs to its configuration owner") end
		core.set_llm_model_mlx = core.set_llm_model_ollama
		helpers.assert_eq(engine.set_llm_configuration_model("remote-model"), true)
		local found, model = engine.get_llm_runtime_setting("llm_model")
		helpers.assert_eq(found, true)
		helpers.assert_eq(model, "remote-model")
		engine.reset = function() return "accepted" end
		helpers.assert_eq(engine.set_llm_configuration_model("wrong"), false)
		local _, unchanged = engine.get_llm_runtime_setting("llm_model")
		helpers.assert_eq(unchanged, "remote-model")
		engine.reset = reset
		core.set_llm_model_ollama, core.set_llm_model_mlx = old_ollama, old_mlx
	end)
end)
