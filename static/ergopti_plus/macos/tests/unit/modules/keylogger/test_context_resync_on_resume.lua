--- tests/unit/modules/keylogger/test_context_resync_on_resume.lua

--- Regression: application and secure-field context must be refreshed after a
--- pause without weakening the pause-time writer guards. Synthetic ownership is
--- carried by immutable event tags and remains independent of that context sync.

local helpers = require("tests.helpers")
local provenance_fixture = require("tests.support.keylogger_provenance_fixture")

local VAULT_APP = "1Password"
local ORDINARY_APP = "TextEdit"
local NOT_PAUSED = function() return false end

local function make_overrides(app_name)
	local fake_observer = {
		addWatcher = function() end,
		removeWatcher = function() end,
		callback = function() end,
		start = function() end,
		stop = function() end,
	}
	local plain_field = {
		attributeValue = function(_self, attr)
			if attr == "AXRole" then return "AXTextField" end
			return nil
		end,
	}
	local app_element = {
		attributeValue = function(_self, attr)
			if attr == "AXFocusedUIElement" then return plain_field end
			return nil
		end,
	}
	return {
		application = {
			frontmostApplication = function()
				return {
					name = function() return app_name end,
					-- Deliberately different: the secure-app lookup must use name().
					title = function() return "window title of " .. app_name end,
					bundleID = function() return "com.example." .. app_name end,
					path = function() return "/Applications/" .. app_name .. ".app" end,
					pid = function() return 4242 end,
				}
			end,
			watcher = { activated = 1 },
		},
		axuielement = {
			observer = { new = function() return fake_observer end },
			applicationElement = function() return app_element end,
		},
	}
end

helpers.describe("context is re-synchronised on resume", function()
	helpers.it("picks up a vault while preserving exact event ownership", function()
		local tracker = helpers.load_with_stubs(
			"modules.keylogger.context_tracker", make_overrides(VAULT_APP))
		local synthetic_input = require("adapters.synthetic_input")
		local provenance = require("adapters.event_provenance")
		local tagged = provenance_fixture.tagged_key(
			synthetic_input, "test.resume-context", "replacement", "x")
		local state = {
			active_app_name = ORDINARY_APP,
			is_secure_field = false,
		}
		tracker.init(state, {
			append_log = function() end,
			log_app_switch = function() end,
		}, NOT_PAUSED)

		local ok = tracker.resync_context()

		helpers.assert_true(ok, "a frontmost app must be resynchronised")
		helpers.assert_eq(state.active_app_name, VAULT_APP)
		helpers.assert_true(state.is_secure_field == true,
			"the first post-resume vault keystroke must remain suppressed")
		local metadata = provenance.classify(tagged, "test.resume-context")
		helpers.assert_not_nil(metadata,
			"context synchronization must not erase ownership stored on an event")
		helpers.assert_eq(metadata.owner, "test.resume-context")
		helpers.assert_eq(metadata.effect, "replacement")
		local physical = provenance_fixture.physical_key(_G.hs, "x")
		helpers.assert_nil(provenance.classify(physical, "test.resume-context.physical"),
			"an untagged key must remain physical despite an older tagged event")
	end)

	helpers.it("leaves an ordinary app unsuppressed after resync", function()
		local tracker = helpers.load_with_stubs(
			"modules.keylogger.context_tracker", make_overrides(ORDINARY_APP))
		local state = { active_app_name = VAULT_APP, is_secure_field = true }
		tracker.init(state, {
			append_log = function() end,
			log_app_switch = function() end,
		}, NOT_PAUSED)

		local ok = tracker.resync_context()

		helpers.assert_true(ok)
		helpers.assert_eq(state.active_app_name, ORDINARY_APP)
		helpers.assert_true(state.is_secure_field == false,
			"leaving a vault during pause must restore ordinary logging")
	end)

	helpers.it("the public script-control resume invokes keylogger resync", function()
		local calls = 0
		local idle_callbacks = {}
		local admission_fence = nil
		local saved_synthetic_input = package.loaded["adapters.synthetic_input"]
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
		local script_control = helpers.load_with_stubs("modules.shortcuts.script_control")
		package.loaded["modules.llm.api_mlx"] = {
			stop_warmup = function() return true end,
			resume_warmup = function() return true end,
		}
		package.loaded["modules.llm.api_ollama"] = { stop_warmup = function() return true end }
		package.loaded["modules.llm.api_remote"] = { stop_warmup = function() return true end }
		package.loaded["modules.llm.warmup_controller"] = {
			stop = function() return true end,
			schedule_warmup_with_retry = function() return true end,
		}
		package.loaded["ui.wpm.wpm_menubar"] = {
			is_running = function() return false end,
		}
		package.loaded["ui.wpm.wpm_widget"] = {
			is_running = function() return false end,
		}
		package.loaded["platform.remap.onboarding"] = { stop = function() return true end }
		package.loaded["ui.tooltip"] = { hide_forced = function() return true end }
		package.loaded["modules.keylogger"] = {
			resync_context = function() calls = calls + 1; return true end,
		}

		helpers.assert_true(script_control.pause_all())
		helpers.assert_eq(#idle_callbacks, 1)
		helpers.assert_eq(calls, 0,
			"context resync may not overtake the owned PAUSE drain")
		idle_callbacks[1]()
		helpers.assert_eq(script_control.is_paused(), true,
			"the explicit drain terminal must commit PAUSED before RESUME")
		helpers.assert_eq(calls, 0)
		local exact_fence = admission_fence
		helpers.assert_true(exact_fence ~= nil and exact_fence.active == true)

		helpers.assert_true(script_control.resume_all())
		helpers.assert_eq(script_control.is_paused(), false,
			"resync is part of the committed local RESUME transaction")

		helpers.assert_eq(calls, 1,
			"resume must refresh context exactly once through the public keylogger API")
		helpers.assert_eq(admission_fence, nil)
		helpers.assert_eq(exact_fence.active, false)
		package.loaded["adapters.synthetic_input"] = saved_synthetic_input
		package.loaded["modules.shortcuts.script_control"] = nil
	end)
end)
