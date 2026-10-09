--- tests/unit/modules/shortcuts/test_resume_rearms_warmup.lua

--- ==============================================================================
--- MODULE: Regression — resume re-arms the LLM warmup it killed on pause
--- DESCRIPTION:
--- Audit finding F-M6. pause_all() correctly calls warmup_controller.stop() (which
--- bumps the warmup generation so the in-flight try_warmup self-discards) so the
--- backend is not POSTed during pause. But resume_all() was asymmetric: it never
--- re-armed warmup. If pause landed during the LLM cold-start window, the warmup
--- chain was killed mid-flight, the backend finished loading with no probe in
--- flight, and api.is_ready() stayed false — predictions were then silently dead
--- for the rest of the session (the readiness flag is only ever set true by a
--- successful warmup, and perform_check never triggers warmup itself).
---
--- Fix: resume_all() re-arms via schedule_warmup_with_retry (self-guarding: no-ops
--- when the LLM is off / model unresolved / backend already ready).
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("script_control pause/resume warmup symmetry", function()
	helpers.it("pause stops the warmup chain AND resume re-arms it", function()
		local calls = { stop = 0, rearm = 0 }
		local owner_names = {
			"adapters.synthetic_input",
			"modules.llm.warmup_controller",
			"modules.llm.api_mlx",
			"modules.llm.api_ollama",
			"modules.llm.api_remote",
			"ui.wpm.wpm_menubar",
			"ui.wpm.wpm_widget",
			"platform.remap.onboarding",
			"ui.tooltip",
		}
		local saved = {}
		for _, name in ipairs(owner_names) do saved[name] = package.loaded[name] end
		local idle_callbacks = {}
		local admission_fence = nil
		package.loaded["adapters.synthetic_input"] = {
			when_idle = function(callback)
				idle_callbacks[#idle_callbacks + 1] = callback
				return true
			end,
			acquire_admission_fence = function(owner)
				if admission_fence ~= nil then return nil end
				admission_fence = { owner = owner, active = true }
				return admission_fence
			end,
			release_admission_fence = function(token)
				if token ~= admission_fence or token.active ~= true then return false end
				token.active = false
				admission_fence = nil
				return true
			end,
			admission_open = function() return admission_fence == nil end,
		}
		package.loaded["modules.llm.warmup_controller"] = {
			stop = function() calls.stop = calls.stop + 1; return true end,
			schedule_warmup_with_retry = function(_reason)
				calls.rearm = calls.rearm + 1
				return true
			end,
		}
		package.loaded["modules.llm.api_mlx"] = {
			stop_warmup = function() return true end,
			resume_warmup = function() return true end,
		}
		package.loaded["modules.llm.api_ollama"] = { stop_warmup = function() return true end }
		package.loaded["modules.llm.api_remote"] = { stop_warmup = function() return true end }
		package.loaded["ui.wpm.wpm_menubar"] = {
			is_running = function() return false end,
		}
		package.loaded["ui.wpm.wpm_widget"] = {
			is_running = function() return false end,
		}
		package.loaded["platform.remap.onboarding"] = { stop = function() return true end }
		package.loaded["ui.tooltip"] = { hide_forced = function() return true end }

		local SC = helpers.load_with_stubs("modules.shortcuts.script_control")

		helpers.assert_true(SC.pause_all(),
			"public PAUSE must accept ownership of the explicit input drain")
		helpers.assert_eq(#idle_callbacks, 1)
		helpers.assert_eq(calls.stop, 0,
			"warmup teardown may not overtake the owned input drain")
		idle_callbacks[1]()
		helpers.assert_true(SC.is_paused(),
			"drain delivery is the local PAUSE commit boundary without Karabiner")
		helpers.assert_true(calls.stop >= 1, "committed pause must stop the warmup chain")
		local exact_fence = admission_fence
		helpers.assert_true(exact_fence ~= nil and exact_fence.active == true,
			"the committed pause must retain its exact admission token")

		helpers.assert_true(SC.resume_all())
		-- The regression: this was 0 because resume_all never re-armed warmup, so a
		-- cold backend killed at pause stayed un-probed for the rest of the session.
		helpers.assert_true(calls.rearm >= 1, "resume_all must re-arm the warmup chain")
		helpers.assert_eq(admission_fence, nil,
			"RESUME must release the exact admission fence before publishing")
		helpers.assert_eq(exact_fence.active, false)

		for _, name in ipairs(owner_names) do package.loaded[name] = saved[name] end
		package.loaded["modules.shortcuts.script_control"] = nil
	end)
end)
