--- tests/unit/ui/editors/test_vision_parameter_prompt.lua

--- ==============================================================================
--- MODULE: Screen Action Vision Parameter Prompt Tests
--- DESCRIPTION:
--- The tray asked a screen action's vision backend in a free-text entry whose
--- prompt printed every backend on its own line, about forty with the API
--- catalogue. It now picks the backend from a native list, then asks the
--- optional model, as the action picker page does (linux-vision-choice-list).
--- ==============================================================================

local helpers = require("tests.helpers")

--- Three backends shaped like vision_request.backend_choices().
local function choices()
	return {
		{ value = "local", label = "Local server", defaultModel = "llava" },
		{ value = "openai", label = "OpenAI", defaultModel = "gpt-4o-mini" },
		{ value = "custom", label = "Custom", defaultModel = "" },
	}
end

--- A prompt whose two dialogs answer from a script and record what they were asked.
local function scripted(backend, model)
	local asked = {}
	return asked, {
		choices = choices,
		pick = function(title, text, offered, current)
			asked.pick = { title = title, text = text, offered = offered, current = current }
			return backend
		end,
		ask = function(title, text, initial)
			asked.ask = { title = title, text = text, initial = initial }
			return model
		end,
	}
end

helpers.describe("screen action vision parameter (linux-vision-choice-list)", function()
	local Prompt = helpers.load_module("ui.vision_parameter_prompt")

	helpers.it("(linux-vision-choice-list) picks the backend from the list and keeps its default model", function()
		local asked, deps = scripted("openai", "")
		helpers.assert_eq(Prompt.ask("Read the screen", "", deps), "openai")
		helpers.assert_eq(#asked.pick.offered, 3, "every backend is a row of the list")
		helpers.assert_contains(asked.ask.text, "gpt-4o-mini")
	end)

	helpers.it("(linux-vision-choice-list) stores a typed model after the backend", function()
		local _, deps = scripted("local", " llava:13b ")
		helpers.assert_eq(Prompt.ask("Read the screen", nil, deps), "local|llava:13b")
	end)

	helpers.it("(linux-vision-choice-list) offers the stored backend first and its model to edit", function()
		local asked, deps = scripted("openai", "gpt-4o")
		helpers.assert_eq(Prompt.ask("Read the screen", "openai|gpt-4o", deps), "openai|gpt-4o")
		helpers.assert_eq(asked.pick.current, "openai")
		helpers.assert_eq(asked.ask.initial, "gpt-4o")
	end)

	helpers.it("(linux-vision-choice-list) a backend with no default needs a model, else validation refuses", function()
		local _, deps = scripted("custom", "")
		local value = Prompt.ask("Read the screen", "", deps)
		helpers.assert_eq(value, "custom|")
		helpers.assert_eq(require("llm.vision").is_valid(value), false)
	end)

	helpers.it("(linux-vision-choice-list) a cancelled list or model is a cancellation", function()
		local _, cancelled_list = scripted(nil, "unused")
		helpers.assert_eq(Prompt.ask("Read the screen", "", cancelled_list), nil)
		local _, cancelled_model = scripted("openai", nil)
		helpers.assert_eq(Prompt.ask("Read the screen", "", cancelled_model), nil)
	end)

	helpers.it("(linux-vision-choice-list) the native list holds one row per backend, the value hidden", function()
		local Shell = require("adapters.shell_runner")
		local held = Shell.has_command
		Shell.has_command = function(name) return name == "zenity" end
		local ChoicePrompt = helpers.load_module("ui.choice_prompt")
		local ok, command = pcall(ChoicePrompt.command, "Title", "Vision provider", choices())
		Shell.has_command = held
		helpers.assert_true(ok, tostring(command))
		helpers.assert_contains(command, "zenity --list --no-markup")
		helpers.assert_contains(command, "--hide-column=1 --print-column=1")
		helpers.assert_contains(command, "'openai' 'OpenAI'")
		helpers.assert_contains(command, "'custom' 'Custom'")
	end)

	helpers.it("(linux-vision-choice-list) the tray's parameter path lists the backends instead of typing them", function()
		local typed, listed, stored = 0, 0, nil
		local TextPrompt = require("ui.text_prompt")
		local held_ask = TextPrompt.ask
		local held_prompt = package.loaded["ui.vision_parameter_prompt"]
		local held_tx = package.loaded["infra.program_binding_transaction"]
		TextPrompt.ask = function() typed = typed + 1; return "openai" end
		package.loaded["ui.vision_parameter_prompt"] = { ask = function(_, prior)
			listed = listed + 1; helpers.assert_eq(prior, "local"); return "openai|gpt-4o"
		end }
		package.loaded["infra.program_binding_transaction"] = { pending = function() return false end,
			apply = function(_, value) stored = value; return true end }
		local ok, failure = pcall(function()
			-- The tray root defines the i18n_safe global the dialog helpers read.
			require("ui.menu.builder")
			local Dialogs = require("ui.menu.menu_dialogs")
			local gestures = {
				get_action_parameter_spec = function() return "llm_vision" end,
				get_action_parameter = function() return "local" end,
				get_action_label = function() return "Read the screen" end,
				get_action_parameter_prompt = function() error("the backend list is never typed") end,
				validate_action_parameter = function(_, value) return require("llm.vision").is_valid(value) end,
			}
			helpers.assert_eq(Dialogs.assign_parameterized_action({}, gestures, "slot", "screen_read", function() return true end), true)
		end)
		TextPrompt.ask = held_ask
		package.loaded["ui.vision_parameter_prompt"] = held_prompt
		package.loaded["infra.program_binding_transaction"] = held_tx
		if not ok then error(failure, 0) end
		helpers.assert_eq({ typed, listed, stored }, { 0, 1, "openai|gpt-4o" })
	end)
end)
