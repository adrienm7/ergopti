--- tests/unit/ui/menu/test_shortcut_declared_native_title.lua

--- ==============================================================================
--- MODULE: Shortcut Prompt Native Title Receiving
--- DESCRIPTION:
--- Exercises actual shortcut/dialog/locale/policy Sources through the textPrompt
--- effect boundary. This owning test needs genuine generated title policy; it
--- does not supply declaration authority or prove physical Cocoa installation.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local corpus_stream = assert(io.open(helpers.shared("tests/corpus/native_presentations/original_captions.json"), "rb"))
local read_ok, corpus_bytes = pcall(function() return corpus_stream:read("*a") end)
local close_ok, close_result = pcall(function() return corpus_stream:close() end)
if not read_ok then error(corpus_bytes, 0) end
assert(close_ok and close_result ~= nil and close_result ~= false)
local original_captions = assert(Json.decode(corpus_bytes))

--- Uses actual receiving helpers and a faithful blocking native result.
--- Cleanup preserves a raw primary and independently records secondary debt.
--- @param body function Owning test callback.
--- @param secondary table|nil Caller-visible cleanup failures.
local function fixture(body, secondary)
	secondary = secondary or {}
	local primary_failed, primary = false, nil
	local restored, scope_failure = pcall(function()
		helpers.with_stub_scope({
			"infra.native_presentation", "native_presentation", "window_titles", "infra.i18n",
			"infra.locale", "locale.core", "infra.paths", "infra.logger", "adapters.json_codec",
			"adapters.storage", "adapters.timer_scheduler", "adapters.shell_runner", "infra.dialog_util",
			"ui.menu.shortcut_utils", "infra.text_utils", "send_input", "hs", "tests.stubs.hs",
		}, function()
			local policy, lookup, dialog, prompt, scheduler
			local state = { calls = {}, applies = {}, button = "OK", raw = "ctrl+k", focus_calls = 0 }
			local completed, failure = xpcall(function()
				scheduler = helpers.load_with_stubs("adapters.timer_scheduler", {
					focus = function() state.focus_calls = state.focus_calls + 1; return true end,
					dialog = { textPrompt = function(...)
						state.calls[#state.calls + 1] = { ... }
						return state.button, state.raw
					end },
				})
				package.loaded["infra.i18n"] = nil
				local i18n = require("infra.i18n")
				local locale = require("infra.locale")
				policy = require("window_titles")
				lookup = policy.native_presentation
				local factory = require("infra.native_presentation")
				dialog = require("infra.dialog_util")
				prompt = dialog.text_prompt
				local shortcuts = require("ui.menu.shortcut_utils")
				function state.options(declared, apply)
					local options = {
						message = "Original shortcut body",
						current_shortcut = { mods = { "shift", "ctrl" }, key = "a" },
						on_apply = apply or function(mods, key)
							state.applies[#state.applies + 1] = { mods, key }; return true
						end,
					}
					if declared then options.native_presentation_id = "profile_shortcut_dialog"
					else options.title = "Original legacy caption" end
					return options
				end
				body(state, shortcuts, dialog, locale, i18n, policy, factory)
			end, function(value) return value end)
			if not completed then primary_failed, primary = true, failure end
			local function clean(owner, action)
				local ok, outcome = xpcall(action, function(value) return value end)
				if not ok or outcome ~= true then
					secondary[#secondary + 1] = { owner = owner, failure = ok and "cleanup did not acknowledge" or outcome }
				end
			end
			if policy ~= nil then clean("exact generated lookup", function()
				policy.native_presentation = lookup; return policy.native_presentation == lookup
			end) end
			if dialog ~= nil then clean("exact dialog method", function()
				dialog.text_prompt = prompt; return dialog.text_prompt == prompt
			end) end
			if scheduler ~= nil then clean("blocking prompt async inventory", function()
				return scheduler.activeCount() == 0
			end) end
		end)
	end)
	if primary_failed then error(primary, 0) end
	if not restored then error(scope_failure, 0) end
	if #secondary > 0 then error(secondary[1].failure, 0) end
end

helpers.describe("actual shortcut prompt declared-title and legacy dispatch receiving", function()
	helpers.it("retains the legacy actual native method before the genuine cancel translator reentry", function()
		fixture(function(state, shortcuts, dialog, locale, i18n)
			local held, foreign, reads = dialog.text_prompt, 0, 0
			local cancel = i18n.get("common.cancel")
			locale.set_trigger_provider(function()
				reads = reads + 1
				dialog.text_prompt = function() foreign = foreign + 1; return "Cancel", "foreign input" end
				return "★"
			end)
			local options = state.options(false)
			helpers.assert_eq(shortcuts.prompt_shortcut(options), true)
			helpers.assert_eq(reads, 1, "Only the original cancel label translation runs")
			helpers.assert_eq(foreign, 0, "A replacement installed by cancel translation cannot intercept the held method")
			helpers.assert_eq(state.calls, {{ "Original legacy caption", "Original shortcut body", "shift+ctrl+a", "OK", cancel }})
			helpers.assert_eq(state.applies, {{ { "ctrl" }, "k" }})
			helpers.assert_eq(options.current_shortcut, { mods = { "shift", "ctrl" }, key = "a" })
			helpers.assert_eq(options.title, "Original legacy caption")
			helpers.assert_true(state.focus_calls > 0, "Actual dialog_util reaches its real focus and native entry")
			dialog.text_prompt = held
			locale.set_trigger_provider(function() return "★" end)
			helpers.assert_eq(shortcuts.prompt_shortcut(options), true)
			helpers.assert_eq(#state.calls, 2); helpers.assert_eq(foreign, 0)
		end)
	end)
	for code, expected in pairs(original_captions.locales) do
		helpers.it("receives the independently original bare declared caption and existing props in " .. code, function()
			fixture(function(state, shortcuts, _, locale, i18n)
				locale.set_locale(code)
				local options = state.options(true)
				helpers.assert_eq(shortcuts.prompt_shortcut(options), true)
				helpers.assert_eq(state.calls, {{ expected.captions.profile_shortcut_dialog.original_bare_caption,
					"Original shortcut body", "shift+ctrl+a", "OK", i18n.get("common.cancel") }})
				helpers.assert_eq(state.applies, {{ { "ctrl" }, "k" }})
				helpers.assert_eq(options.current_shortcut, { mods = { "shift", "ctrl" }, key = "a" })
				helpers.assert_nil(options.title)
			end)
		end)
	end
	helpers.it("withdraws the actual declared receipt during cancel translation before native entry and repairs exactly", function()
		fixture(function(state, shortcuts, _, locale, _, policy)
			local held, foreign, reads = policy.native_presentation, 0, 0
			locale.set_trigger_provider(function()
				reads = reads + 1
				if reads == 2 then policy.native_presentation = function() foreign = foreign + 1; return {} end end
				return "★"
			end)
			local options = state.options(true)
			helpers.assert_eq(shortcuts.prompt_shortcut(options), false)
			helpers.assert_eq(reads, 2, "Declared title and original cancel label each translate once")
			helpers.assert_eq(state.calls, {}); helpers.assert_eq(state.applies, {}); helpers.assert_eq(foreign, 0)
			policy.native_presentation = held
			locale.set_trigger_provider(function() return "★" end)
			helpers.assert_eq(shortcuts.prompt_shortcut(options), true)
			helpers.assert_eq(#state.calls, 1); helpers.assert_eq(state.applies, {{ { "ctrl" }, "k" }})
		end)
	end)
	helpers.it("holds the original native method through declared cancel translator method replacement", function()
		fixture(function(state, shortcuts, dialog, locale)
			local foreign, reads = 0, 0
			locale.set_trigger_provider(function()
				reads = reads + 1
				if reads == 2 then dialog.text_prompt = function() foreign = foreign + 1; return "Cancel", "foreign" end end
				return "★"
			end)
			helpers.assert_eq(shortcuts.prompt_shortcut(state.options(true)), true)
			helpers.assert_eq(reads, 2); helpers.assert_eq(foreign, 0)
			helpers.assert_eq(#state.calls, 1); helpers.assert_eq(state.applies, {{ { "ctrl" }, "k" }})
		end)
	end)
	for _, outcome in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains the existing exact on_apply acknowledgment contract through declared title: " .. outcome, function()
			fixture(function(state, shortcuts)
				local options = state.options(true, function(mods, key)
					state.applies[#state.applies + 1] = { mods, key }
					if outcome == "throw" then error("controlled apply refusal", 0) end
					if outcome == "false" then return false end
					return nil
				end)
				helpers.assert_eq(shortcuts.prompt_shortcut(options), false)
				helpers.assert_eq(#state.calls, 1); helpers.assert_eq(state.applies, {{ { "ctrl" }, "k" }})
			end)
		end)
	end
end)

return true
