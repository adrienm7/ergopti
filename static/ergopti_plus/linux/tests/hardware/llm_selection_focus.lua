--- tests/hardware/llm_selection_focus.lua

--- ==============================================================================
--- MODULE: Native AI Text Destination Regression
--- DESCRIPTION:
--- Runs production predictions, tone rewrites and translations against real GTK
--- fields. Extracts the daemon's exact focus callback; accessibility queries,
--- privacy verdicts, selected-range snapshots and XTest output are native.
--- Provider replies, preferences and a fixed paste-shortcut cohort are controlled.
--- This does not claim evdev/uinput or physical keyboard input.
--- ==============================================================================

require("compat.utf8").install()
-- A refused AI action reports its reason only in the log. The receipts go to
-- stdout, so the log goes to stderr (worker.log), which the harness prints
-- when an assertion fails.
require("logger").set_sink(function(line) io.stderr:write(line, "\n") end)
local Json = require("json")
local Shell = require("adapters.shell_runner")
local source_path = os.getenv("ERGOPTI_AI_DAEMON_SOURCE") or "ergopti_hotstrings.lua"
local file = assert(io.open(source_path, "r"))
local source = file:read("*a")
file:close()
local seam = assert(source:match("focus_id = (.-),\n%s*%-%-"), "the daemon focus callback must be present")
local compile = loadstring or load
local focus_factory = assert(compile("return function(window_info, secure_focus_guard) return " .. seam .. " end"))()
local Window = require("adapters.window_info")
local Detector = require("adapters.secure_field_detector")
local Atspi = require("adapters.atspi_focus")
local uv = require("luv")
local Clock = require("infra.monotonic")
local Timings = require("infra.timings")
local ffi = require("ffi")
ffi.cdef([[typedef struct _XDisplay Display;
	Display *XOpenDisplay(const char *name); int XCloseDisplay(Display *display);
	int XSync(Display *display, int discard);
	int XTestFakeKeyEvent(Display *display, unsigned int code, int pressed, unsigned long delay);]])
local X11, XTest = ffi.load("libX11.so.6"), ffi.load("libXtst.so.6")
local display = assert(X11.XOpenDisplay(nil), "native X11 output connection required")
local Injector = require("modules.hotstrings.injector")
require("adapters.keyboard_layout")._set_table_for_test({ v = { keycode = 47, mods = {} } })
Injector._set_uinput({ is_open = function() return true end, emit = function(code, value)
	assert(XTest.XTestFakeKeyEvent(display, code + 8, value == 1 and 1 or 0, 0) ~= 0)
	X11.XSync(display, 0)
	return true
end })
local Clipboard = require("adapters.clipboard")
local CLIPBOARD_SEED = "ERGOPTI-NATIVE-SELECTION-CLIPBOARD"
-- A new Xvfb session has no clipboard owner. The strict stage must snapshot a
-- known existing owner, rather than guessing that an unavailable read is empty.
assert(Clipboard.write(CLIPBOARD_SEED), "native clipboard control must be seeded")
local clipboard_read_ok, clipboard_content = Clipboard.read_checked()
assert(clipboard_read_ok and clipboard_content == CLIPBOARD_SEED, "native clipboard control must be readable")
local Watch = require("adapters.atspi_focus_watch").new()
package.loaded["infra.llm_preferences"] = require("tests.support.llm_preferences_fixture").new({ initial = {
	["llm.models.selected"] = "api", ["llm.profiles.auto_profile_for_model"] = false,
	["llm.trigger.secure_filter_enabled"] = true, ["llm.trigger.url_bar_filter_enabled"] = true,
} })
-- Every case re-initializes the engine, which first retires the previous
-- Profiles inventory: without these ports each re-initialization was refused
-- and the next case ran on the first case's scheduler and pacing clock.
package.loaded["modules.llm.profiles"] = require("tests.support.llm_profiles_fixture").without_inventory({
	init = function() end, is_enabled = function() return true end,
})
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
local Keylogger = require("modules.keylogger.keylogger")
local Guard = require("modules.keylogger.focus_guard").new({
	watch = Watch, detector = Detector, keylogger = Keylogger, prediction = Engine,
	now_ms = Clock.now_ms, retry_ms = Timings.ms("privacy", "context_retry_ms"),
	capture_context_async = Window.start_privacy_context,
	publish_context = function(context) return true, Keylogger.is_context_protected(context.app_id, context.title) end,
})
local focus_id = focus_factory(Window, Guard)
assert(type(focus_id) == "function", "the real daemon must inject a text destination reader")
assert(Watch.start() and Watch.wait_ready(), "the actual native focus watcher must become ready")

--- Pumps native context ownership off the input path until ordinary text is ready.
local function await_join()
	local deadline = Clock.now_ms() + 5000
	repeat
		uv.run("nowait")
		Guard.refresh(true)
		if not Guard.blocks_text() and focus_id() then return end
		uv.sleep(1)
	until Clock.now_ms() > deadline
	error("native AI privacy context did not join within five seconds")
end

local Selection = require("adapters.selection_transaction")
local selection_owner

local function initialize()
	assert(not selection_owner or selection_owner.stop(), "the previous range owner must settle")
	selection_owner = Selection.new({ focus_id = focus_id, privacy_guard = Guard.blocks_text, capture_text_owner = Guard.capture_text_owner })
	callback, applied, request, reads = nil, 0, 0, 0
	scheduler = require("tests.fakes").timer_scheduler()
	local function type_text(text)
		local ok = Shell.exec_checked("xdotool type --clearmodifiers --delay 0 " .. Shell.quote(text))
		if ok then applied = applied + 1 end
		return ok == true
	end
	local initialized = Engine.init({
		scheduler = scheduler, clock_ms = function() return scheduler.now * 1000 end,
		focus_id = focus_id,
		privacy_guard = Guard.blocks_text, privacy_context = Guard.current_context,
		read_selection = function(focus, authorized, callback)
			reads = reads + 1
			return selection_owner.read(focus, authorized, callback)
		end,
		cancel_selection = function() return selection_owner.cancel() end,
		replace_selection = function(text, receipt, authorized, callback)
			return selection_owner.replace_staged(receipt, text, authorized, Injector.prepare_selected, function(committed)
				if committed then applied = applied + 1 end
				callback(committed)
			end)
		end,
		apply_prediction = function(candidate) return type_text(candidate.to_type) end,
	})
	-- A refusal returns false and keeps the previous case's state.
	assert(initialized ~= false, "the prediction engine must accept every case's re-initialization")
	Guard.prime()
	await_join()
end
local function snapshot(fields)
	local native, conclusive = Atspi.get_snapshot()
	fields.role = native and native.role
	fields.path = native and native.native_object_path
	fields.bus = native and native.native_bus_name
	fields.active_scope = native and native.active_scope
	fields.conclusive = conclusive
	fields.target = focus_id()
	fields.cached_verdict = Detector.getVerdict()
	fields.url_filter = require("modules.llm.trigger_settings").get("url_bar_filter_enabled")
	fields.foreground_type = type(require("adapters.process_lifecycle").getForegroundApp())
	fields.window = Window.focused_identity()
	fields.applied, fields.requests, fields.reads = applied, request, reads
	fields.offered = Engine.has_suggestions()
	io.write("RECEIPT:" .. Json.encode(fields) .. "\n")
end
for command in io.lines() do
	local result = { barrier_budget_ms = Timings.ms("privacy", "focus_barrier_timeout_ms") }
	uv.run("nowait")
	Guard.refresh(true)
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
	elseif command == "selection-range" then
		local field = assert(Atspi.cached_snapshot(), "native field receipt required")
		local started = Clock.now_ms()
		local operation = assert(Atspi.start_selection_capture({
			bus = field.native_bus_name, path = field.native_object_path, role = field.role,
		}, { owner = "native-range-probe", authorized = function() return true end }, function(selection)
			if selection then result.selection_first, result.selection_last = selection.first, selection.last end
		end))
		local cleanup_deadline = started + 5000
		while not operation:is_settled() and Clock.now_ms() < cleanup_deadline do uv.run("nowait"); uv.sleep(1) end
		assert(operation:is_settled(), "the bounded native range helper must physically settle")
		result.selection_ms = Clock.now_ms() - started
	elseif command == "offer" or command == "finish" then
		assert(callback, "the controlled provider must have an actual pending request")
		-- A real provider answers long after a focus change; replying within
		-- milliseconds raced the resident watcher, so the same field read as
		-- "unknown" and its output was refused (dev CI of October 20). The
		-- refocus events can land after a first conclusive reading (the old
		-- field's verdict), so the verdict must stay conclusive for a quiet
		-- window. A password settles to "secure" and stays refused.
		local settle_deadline = Clock.now_ms() + 3000
		local quiet_since = nil
		while Clock.now_ms() < settle_deadline do
			uv.run("nowait"); Guard.refresh(true)
			if Detector.getVerdict() == "unknown" then quiet_since = nil
			elseif not quiet_since then quiet_since = Clock.now_ms()
			elseif Clock.now_ms() - quiet_since >= 300 then break end
			uv.sleep(1)
		end
		result.verdict_before_reply = Detector.getVerdict()
		local text = mode == "tone" and "REWRITE: Merci pour votre aide."
			or mode == "translation" and "TRANSLATION: Thank you for your help."
			or " que tout le monde aille bien"
		local delivered = false
		local timer = uv.new_timer()
		timer:start(0, 0, function() timer:close(); callback(text, nil); delivered = true end)
		while not delivered do uv.run("nowait"); uv.sleep(1) end
		if command == "finish" and mode ~= "tone" then result.workflow_accepted = Engine.accept(1, function(committed) result.accepted = committed end) end
	elseif command == "accept" then
		result.workflow_accepted = Engine.accept(1, function(committed) result.accepted = committed end)
	elseif command == "first-character" then
		result.first_char_target_before = assert(focus_id(), "native text destination must be admitted before measuring the first character")
		result.helper_calls = 0
		local originals = {}
		for _, entry in ipairs({ { Atspi, "get_snapshot" }, { Shell, "exec" }, { Shell, "exec_line" }, { Shell, "exec_checked" } }) do
			local object, name = entry[1], entry[2]
			local original = object[name]
			originals[#originals + 1] = { object, name, original }
			object[name] = function(...)
				result.helper_calls = result.helper_calls + 1
				return original(...)
			end
		end
		local started = uv.hrtime()
		local heartbeat = uv.new_timer()
		heartbeat:start(0, 0, function()
			result.heartbeat_delay_ms = (uv.hrtime() - started) / 1000000
			heartbeat:close()
		end)
		local called, detail = pcall(Engine.on_char, "x", "x", {})
		result.first_char_ms = (uv.hrtime() - started) / 1000000
		for _, entry in ipairs(originals) do entry[1][entry[2]] = entry[3] end
		uv.run("nowait")
		assert(called, detail)
	elseif command == "benchmark" or command == "deadline" then
		if command == "benchmark" then await_join() end
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
	local selection_deadline = Clock.now_ms() + 5000
	while selection_owner and not selection_owner.is_settled() and Clock.now_ms() < selection_deadline do uv.run("nowait"); uv.sleep(1) end
	assert(not selection_owner or selection_owner.is_settled(), "the actual native range owner must settle")
	snapshot(result)
	io.flush()
end
assert(not selection_owner or selection_owner.stop(), "the native selected-range owner must settle")
Guard.stop()
Watch.stop()
local deadline = Clock.now_ms() + 5000
while (not Guard.stop() or not Watch.is_settled()) and Clock.now_ms() <= deadline do
	uv.run("nowait"); uv.sleep(1)
end
assert(Guard.stop() and Watch.is_settled(), "native AI focus resources must physically retire")
clipboard_read_ok, clipboard_content = Clipboard.read_checked()
assert(clipboard_read_ok and clipboard_content == CLIPBOARD_SEED, "native selected output must restore the original clipboard")
Injector._set_uinput(nil)
X11.XCloseDisplay(display)
