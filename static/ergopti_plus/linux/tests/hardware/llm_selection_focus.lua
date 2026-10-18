--- tests/hardware/llm_selection_focus.lua

--- ==============================================================================
--- MODULE: Native AI Text Destination Regression
--- DESCRIPTION:
--- Runs production predictions, tone rewrites and translations against real GTK
--- fields. Extracts the daemon's exact focus callback; accessibility queries,
--- privacy verdicts and XTest output are native. Provider and selection replies
--- are controlled. This does not claim evdev/uinput or physical keyboard input.
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
assert(type(focus_id) == "function", "the real daemon must inject a text destination reader")
local Detector = require("adapters.secure_field_detector")
local Atspi = require("adapters.atspi_focus")
package.loaded["infra.llm_preferences"] = require("tests.support.llm_preferences_fixture").new({ initial = {
	["llm.models.selected"] = "api", ["llm.profiles.auto_profile_for_model"] = false,
	["llm.trigger.secure_filter_enabled"] = true, ["llm.trigger.url_bar_filter_enabled"] = true,
} })
package.loaded["modules.llm.profiles"] = { init = function() end, is_enabled = function() return true end }
package.loaded["modules.llm.api_entries"] = { active = function()
	return { id = "owned", provider = "openai_compat", model = "fixture-model" }
end }
local callback, applied, request, reads, mode, scheduler
package.loaded["modules.llm.api_remote"] = {
	provider = function() return { default_model = "fixture-model" } end,
	serves = function() return true end,
	chat = function(_, _, _, _, _, done) callback = done; request = request + 1; return true end,
	cancel = function() return true end,
}
local Engine = require("modules.llm.prediction_engine")
local Tone = require("llm.tone")
local function initialize()
	callback, applied, request, reads = nil, 0, 0, 0
	scheduler = require("tests.fakes").timer_scheduler()
	local function type_text(text)
		local ok = Shell.exec_checked("xdotool type --clearmodifiers --delay 0 " .. Shell.quote(text))
		if ok then applied = applied + 1 end
		return ok == true
	end
	Engine.init({
		scheduler = scheduler, clock_ms = function() return scheduler.now * 1000 end,
		focus_id = focus_id,
		read_selection = function() reads = reads + 1; return true, "Merci pour ton aide", nil end,
		replace_selection = type_text,
		apply_prediction = function(candidate) return type_text(candidate.to_type) end,
	})
	assert(Detector.refresh(Detector.invalidateFocus()), "the positive initial field must be checked natively")
end
local function snapshot(fields)
	local native, conclusive = Atspi.get_snapshot()
	fields.role = native and native.role
	fields.path = native and native.native_object_path
	fields.bus = native and native.native_bus_name
	fields.active_scope = native and native.active_scope
	fields.conclusive = conclusive
	fields.cached_verdict = Detector.getVerdict()
	fields.url_filter = require("modules.llm.trigger_settings").get("url_bar_filter_enabled")
	fields.foreground_type = type(require("adapters.process_lifecycle").getForegroundApp())
	fields.window = Window.focused_identity()
	fields.target = focus_id()
	fields.applied, fields.requests, fields.reads = applied, request, reads
	fields.offered = Engine.has_suggestions()
	io.write("RECEIPT:" .. Json.encode(fields) .. "\n")
end
for command in io.lines() do
	local result = {}
	if command == "reset" then
		initialize()
	elseif command:match("^start%-") then
		mode = command:sub(7)
		if mode == "tone" then result.started = Engine.shift_tone(Tone.MORE_FORMAL, false)
		elseif mode == "translation" then result.started = Engine.translate_selection("en")
		elseif mode == "prediction" then
			Engine.predict("Bonjour à tous", nil, { num_predictions = 1, profile = { id = "raw", system_single = "{context}" } })
			result.started = request > 0
		else error("unknown request mode") end
	elseif command == "offer" or command == "finish" then
		assert(callback, "the controlled provider must have an actual pending request")
		local text = mode == "tone" and "REWRITE: Merci pour votre aide."
			or mode == "translation" and "TRANSLATION: Thank you for your help."
			or " que tout le monde aille bien"
		callback(text, nil)
		if command == "finish" and mode ~= "tone" then result.accepted = Engine.accept(1) end
	elseif command == "accept" then
		result.accepted = Engine.accept(1)
	elseif command == "benchmark" or command == "deadline" then
		local clock = require("infra.monotonic")
		result.probe_ms = {}
		for _ = 1, command == "benchmark" and 20 or 1 do
			local started = clock.now_ms()
			local destination = focus_id()
			local elapsed = clock.now_ms() - started
			if command == "deadline" then result.deadline_target, result.deadline_ms = destination, elapsed
			else
				assert(destination, "the live positive text destination must remain readable")
				result.probe_ms[#result.probe_ms + 1] = elapsed
			end
		end
	elseif command == "advance" then
		scheduler.test.advance(10)
	elseif command ~= "probe" then error("unknown native fixture command") end
	snapshot(result)
	io.flush()
end
