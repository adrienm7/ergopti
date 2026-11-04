--- tests/unit/ui/menu/gestures_and_apps/test_vision_parameter_choice.lua

--- The native fallback asked a screen action's vision backend in a text prompt
--- that printed every backend on its own line, about forty with the API
--- catalogue. It now picks the backend from a list, then asks the optional
--- model, as the action picker page does (macos-vision-choice-list).
local helpers = require("tests.helpers")

--- Runs one case with the dialogs scripted; restores every loaded module.
--- @param picked integer|nil The list index the user picks (nil cancels).
--- @param typed string|nil The model typed (nil cancels).
--- @param body function body(utils, asked)
local function fixture(picked, typed, body)
	local saved = {}
	for key, value in pairs(package.loaded) do saved[key] = value end
	local asked = { typed_prompts = 0 }
	local ok, failure = xpcall(function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.dialog_util"] = {
			choose = function(title, message, labels)
				asked.choose = { title = title, message = message, labels = labels }
				return picked
			end,
			text_prompt = function(_, prompt, initial, save)
				asked.typed_prompts = asked.typed_prompts + 1
				asked.model = { prompt = prompt, initial = initial }
				if typed == nil then return "button.cancel" end
				return save, typed
			end,
		}
		package.loaded["ui.menu.shortcut_utils"] = nil
		body(require("ui.menu.shortcut_utils"), asked)
	end, debug.traceback)
	for key in pairs(package.loaded) do if saved[key] == nil then package.loaded[key] = nil end end
	for key, value in pairs(saved) do package.loaded[key] = value end
	if not ok then error(failure, 0) end
end

--- A gestures facade with three backends; parameter_prompt must never be read.
local gestures = {
	llm_vision_choices = function()
		return {
			{ value = "local", label = "Local server", defaultModel = "llava" },
			{ value = "openai", label = "OpenAI", defaultModel = "gpt-4o-mini" },
			{ value = "custom", label = "Custom", defaultModel = "" },
		}
	end,
	parameter_prompt = function() error("the backend list is never typed") end,
}

helpers.describe("macOS screen action vision parameter (macos-vision-choice-list)", function()
	helpers.it("(macos-vision-choice-list) picks the backend from the list and keeps its default model", function()
		fixture(2, "", function(utils, asked)
			helpers.assert_eq(utils.ask_parameter_value(gestures, "screen_read", "llm_vision", "T", ""), "openai")
			helpers.assert_eq(asked.choose.labels, { "Local server", "OpenAI", "Custom" })
			helpers.assert_eq(asked.typed_prompts, 1, "only the model is typed")
		end)
	end)

	helpers.it("(macos-vision-choice-list) offers the stored backend first and its model to edit", function()
		fixture(1, "gpt-4o", function(utils, asked)
			helpers.assert_eq(utils.ask_parameter_value(gestures, "screen_read", "llm_vision", "T", "openai|gpt-4o"),
				"openai|gpt-4o")
			helpers.assert_eq(asked.choose.labels[1], "OpenAI")
			helpers.assert_eq(asked.model.initial, "gpt-4o")
		end)
	end)

	helpers.it("(macos-vision-choice-list) a backend with no default needs a model, else validation refuses", function()
		fixture(3, "", function(utils)
			local value = utils.ask_parameter_value(gestures, "screen_read", "llm_vision", "T", "")
			helpers.assert_eq(value, "custom|")
			helpers.assert_eq(require("llm.vision").is_valid(value), false)
		end)
	end)

	helpers.it("(macos-vision-choice-list) a cancelled list or model is a cancellation", function()
		fixture(nil, "unused", function(utils, asked)
			helpers.assert_eq(utils.ask_parameter_value(gestures, "screen_read", "llm_vision", "T", ""), nil)
			helpers.assert_eq(asked.typed_prompts, 0)
		end)
		fixture(2, nil, function(utils)
			helpers.assert_eq(utils.ask_parameter_value(gestures, "screen_read", "llm_vision", "T", ""), nil)
		end)
	end)
end)
