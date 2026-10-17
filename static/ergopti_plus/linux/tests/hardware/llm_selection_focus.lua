--- tests/hardware/llm_selection_focus.lua

--- ==============================================================================
--- MODULE: Native AI Selection Focus Regression
--- DESCRIPTION:
--- Runs the production tone engine and the daemon's exact injected focus callback
--- against owned X11 windows. Provider and clipboard replies are controlled; the
--- focused-window reads and XTest output are real. No evdev/uinput claim is made.
--- ==============================================================================

require("compat.utf8").install()
local Json = require("json")
local Shell = require("adapters.shell_runner")
local source_path = os.getenv("ERGOPTI_AI_DAEMON_SOURCE") or "ergopti_hotstrings.lua"
local file = assert(io.open(source_path, "r"))
local source = file:read("*a")
file:close()
local seam = assert(source:match("focus_id = (.-),\n%s*%-%-"), "the daemon focus callback must be present")
local compile = loadstring or load
local focus_factory = assert(compile("return function(window_info) return " .. seam .. " end"))()
local Window = require("adapters.window_info")
local focus_id = focus_factory(Window)
assert(type(focus_id) == "function", "the real daemon must inject a focus reader")
package.loaded["adapters.secure_field_detector"] = {
	isSecureField = function() return false end, isUrlBar = function() return false end,
}
package.loaded["infra.llm_preferences"] = require("tests.support.llm_preferences_fixture").new({initial = {
	["llm.models.selected"] = "api", ["llm.profiles.auto_profile_for_model"] = false,
}})
package.loaded["modules.llm.profiles"] = {init = function() end, is_enabled = function() return true end}
package.loaded["modules.llm.api_entries"] = {active = function()
	return {id = "owned", provider = "openai_compat", model = "fixture-model"}
end}
local callback, applied, request = nil, 0, 0
package.loaded["modules.llm.api_remote"] = {
	provider = function() return {default_model = "fixture-model"} end,
	serves = function() return true end,
	chat = function(_, _, _, _, _, done) callback = done; request = request + 1; return true end,
	cancel = function() return true end,
}
local Engine = require("modules.llm.prediction_engine")
local Tone = require("llm.tone")
local function initialize()
	callback, applied, request = nil, 0, 0
	local function type_text(text)
		local ok = Shell.exec_checked("xdotool type --clearmodifiers --delay 0 " .. Shell.quote(text))
		if ok then applied = applied + 1 end
		return ok == true
	end
	Engine.init({
		focus_id = focus_id,
		read_selection = function() return true, "Merci pour ton aide", nil end,
		replace_selection = type_text,
		apply_prediction = function(candidate) return type_text(candidate.to_type) end,
	})
end
for command in io.lines() do
	if command == "start" or command == "start-prediction" then
		initialize()
		local started
		if command == "start" then started = Engine.shift_tone(Tone.MORE_FORMAL, false)
		else
			Engine.predict("Bonjour à tous", nil, {num_predictions = 1, profile = {id = "raw", system_single = "{context}"}})
			started = request == 1
		end
		local info = Window.getFocused()
		io.write(Json.encode({started = started, request = request, app = info.appId, title = info.windowTitle}) .. "\n")
	elseif command == "probe" then
		local info = Window.getFocused()
		io.write(Json.encode({app = info.appId, title = info.windowTitle}) .. "\n")
	elseif command == "finish" or command == "finish-prediction" then
		assert(callback, "the controlled provider must have an actual pending request")
		if command == "finish" then callback("REWRITE: Merci pour votre aide.", nil)
		else
			callback(" que tout le monde aille bien", nil)
			Engine.accept(1)
		end
		io.write(Json.encode({applied = applied}) .. "\n")
	else error("unknown native fixture command") end
	io.flush()
end
