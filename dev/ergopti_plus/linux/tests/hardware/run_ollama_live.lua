--- tests/hardware/run_ollama_live.lua

--- ==============================================================================
--- MODULE: AI Predictions Against A Real Ollama
--- DESCRIPTION:
--- Every other AI test scripts the server. This one asks a running Ollama with
--- a real model, through the production modules and the real curl transport:
---   1. the installed-model list the menu shows (/api/tags);
---   2. a model download through the model browser's path (/api/pull), which
---      had never worked on Linux;
---   3. predictions from the engine, streamed, parsed and offered, as typing
---      would ask for them;
---   4. the remote-API backend and its "Test" probe, pointed at Ollama's own
---      OpenAI-compatible endpoint, which speaks the dialect Cerebras does.
---
--- Usage (from the driver root, with lua-luv installed and Ollama serving):
---   luajit tests/hardware/run_ollama_live.lua <model-tag>
--- Exit 0 = all four verified; 1 = a failure; 2 = no environment.
--- ==============================================================================

local MODEL = arg[1]
if not MODEL or MODEL == "" then
	io.stderr:write("usage: run_ollama_live.lua <model-tag>\n")
	os.exit(2)
end

local ok_luv, luv = pcall(require, "luv")
if not ok_luv then
	io.stderr:write("ENVIRONMENT: lua-luv is missing\n")
	os.exit(2)
end

-- The privacy gate needs a desktop; this test is about the backend, so the
-- focused field is declared an ordinary one.
package.loaded["adapters.secure_field_detector"] = {
	isSecureField = function() return false end,
	isSecureApp = function() return false end,
	isUrlBar = function() return false end,
}

local failures = {}
local function check(condition, message)
	print(string.format("  %s %s", condition and "ok  " or "FAIL", message))
	if not condition then failures[#failures + 1] = message end
end

--- Runs the event loop until done() is true or the deadline passes.
--- @param seconds number
--- @param done function
--- @return boolean
local function run_until(seconds, done)
	local deadline = luv.now() + seconds * 1000
	local timer = luv.new_timer()
	luv.timer_start(timer, 50, 50, function()
		if done() or luv.now() > deadline then luv.stop() end
	end)
	luv.run()
	luv.timer_stop(timer)
	luv.close(timer)
	luv.run("nowait")
	return done() == true
end




-- =========================================
-- =========================================
-- ======= 1/ Installed models =============
-- =========================================
-- =========================================

print("=== 1/ the models Ollama reports ===")
local Profiles = require("modules.llm.profiles")
Profiles.init({})
local models = Profiles.refresh_models() or Profiles.get_models() or {}
local listed = false
for _, name in ipairs(models) do if name == MODEL then listed = true end end
check(listed, string.format("the model list holds %s (%d model(s))", MODEL, #models))
check(Profiles.set_model(MODEL) == true, "the model can be selected")




-- =========================================
-- =========================================
-- ======= 2/ Model download ===============
-- =========================================
-- =========================================

print("=== 2/ a download through the model browser's path ===")
local window = { updates = 0 }
package.loaded["ui.download_window.bridge"] = {
	show = function() return 1 end,
	update = function() window.updates = window.updates + 1; return true end,
	complete = function(_, succeeded) window.completed = succeeded; return true end,
	focus = function() return true end,
	close = function() return true end,
}
local Download = require("modules.llm.model_download")
local pulled = nil
local started = Download.start(Profiles.get_base_url(), MODEL, MODEL, function(succeeded) pulled = succeeded end)
check(started == true, "the pull request is dispatched")
run_until(120, function() return pulled ~= nil end)
check(pulled == true, "Ollama confirms the model through /api/pull")




-- =========================================
-- =========================================
-- ======= 3/ Predictions ==================
-- =========================================
-- =========================================

print("=== 3/ predictions from the engine ===")
local offered, final = {}, nil
local Engine = require("modules.llm.prediction_engine")
Engine.init({
	overlay = {
		show = function(candidates, meta)
			offered = candidates
			if meta and meta.loading == false then final = candidates end
			return true
		end,
		hide = function() return true end,
	},
})
Engine.set_backend("ollama")
local context = "Bonjour à tous, je voulais vous dire que"
Engine.predict(context, { app_id = "live-test", input_chars = 0 })
run_until(180, function() return final ~= nil end)
check(final ~= nil, "the request completes")
check(#offered > 0, string.format("%d prediction(s) offered", #offered))
for index, candidate in ipairs(offered) do
	print(string.format("       %d. %q (deletes %d)", index, candidate.to_type, candidate.deletes or 0))
end




-- =========================================
-- =========================================
-- ======= 4/ The remote backend ===========
-- =========================================
-- =========================================

print("=== 4/ the remote-API backend on Ollama's OpenAI endpoint ===")
local Remote = require("modules.llm.api_remote")
local entry = {
	id = "ollama-openai", provider = "openai_compat", label = "Ollama (OpenAI)",
	token = "ollama", model = MODEL, base_url = "http://127.0.0.1:11434/v1",
}
local tested = nil
Remote.test(entry, function(succeeded, detail, elapsed_ms)
	tested = { ok = succeeded, detail = detail, ms = elapsed_ms }
end)
run_until(120, function() return tested ~= nil end)
check(tested ~= nil and tested.ok, string.format("the connectivity probe is answered (%s)",
	tested and tostring(tested.detail):sub(1, 80) or "no answer"))

local remote_text, remote_err = nil, nil
Remote.chat(entry, nil, {
	{ role = "system", content = "Continue the user's sentence with a few words." },
	{ role = "user", content = context },
}, { temperature = 0.2, max_tokens = 30 }, nil, function(text, err) remote_text, remote_err = text, err end)
run_until(120, function() return remote_text ~= nil end)
check(remote_err == nil and type(remote_text) == "string" and remote_text ~= "",
	string.format("a completion comes back: %q", tostring(remote_text or remote_err)))

if #failures > 0 then
	print(string.format("FAIL %d check(s) failed", #failures))
	os.exit(1)
end
print("ok   Ollama answered every path")
os.exit(0)
