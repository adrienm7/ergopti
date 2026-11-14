--- tests/hardware/run_owned_ollama_container.lua

--- ==============================================================================
--- MODULE: Owned Ollama Start And Pull Container Control
--- DESCRIPTION:
--- Enables the AI through the production prediction engine, enable admission,
--- runtime repair, runtime composition, managed proxy stage and owned process
--- port, as the AI menu does, with an installed managed runtime whose binary is
--- the Ollama stand-in (fake_ollama_server.py). Only the refusal dialog's choice
--- (« Start Ollama ») and the WebKit presentation of the download window are
--- scripted. When ERGOPTI_PROOF_PULL_TAG names a model, the production model
--- download then pulls it through the started daemon.
---
--- The parent (run_owned_ollama_container.py) owns the system Ollama on the
--- stock port, the desktop proxy configuration and every assertion; this control
--- prints one ERGOPTI_OWNED_OLLAMA_RESULT line and every driver log line.
--- ==============================================================================

local uv = require("luv")
local Json = require("core.text.engine.json")

local Logger = require("core.logger.engine.shim")
for _, level in ipairs({ "error", "warn", "info" }) do
	local original = Logger[level]
	Logger[level] = function(tag, format, ...)
		io.stdout:write("PROOF_LOG ", level:upper(), " ", tostring(tag), " ", string.format(format, ...), "\n")
		io.stdout:flush()
		return original(tag, format, ...)
	end
end

-- Observe the owned daemon start without changing its arguments or answers.
local Native = require("adapters.owned_process")
local served = {}
local original_start = Native.start
Native.start = function(executable, arguments, options, callback)
	local operation = original_start(executable, arguments, options, callback)
	if type(arguments) == "table" and arguments[1] == "serve" then
		served[#served + 1] = { executable = executable, env = options.env, operation = operation }
	end
	return operation
end

-- The refusal dialog: pick the row the user would click to start Ergopti's Ollama.
local dialog_rows = {}
package.loaded["ui.llm_enable_refusal"] = { show = function(_, rows)
	local wanted = require("core.i18n.engine.i18n").get("ollama.runtime_start")
	local selected
	for _, row in ipairs(rows) do
		dialog_rows[#dialog_rows + 1] = tostring(row.label)
		if row.label == wanted then selected = row.value end
	end
	return true, false, selected
end }
-- The download window's WebKit page is presentation only.
package.loaded["ui.webview_manager"] = {
	show = function() return true end, hide = function() return true end,
	eval_js = function() return true end, bring_to_front = function() return true end,
	is_visible = function() return true end, set_daemon_state = function() end,
}

local Bridge = require("infra.llm_bridge")
local Profiles = require("modules.llm.profiles")
local Engine = require("modules.llm.prediction_engine")
local Download = require("modules.llm.model_download")
local Window = require("ui.download_window.bridge")
local Http = require("core.network.adapters.http_client")
local EventLoop = require("core.events.loop")

Engine.init({ is_paused = function() return false end })
assert(Profiles.init({ port = Bridge.OLLAMA_OWNED_PORT }), "profiles take the owned port")

local expired = false
local ceiling = assert(uv.new_timer())
ceiling:start(60000, 0, function() expired = true end)
local function wait_until(predicate)
	while not predicate() and not expired and uv.loop_alive() do uv.run("once") end
	return predicate()
end

local result = { base_url = Engine.get_base_url() }
local changed = 0
Engine.enable(function() changed = changed + 1 end)
result.enabled = wait_until(function() return Engine.is_enabled() end)
result.dialog_rows = dialog_rows
result.served = {}
for _, entry in ipairs(served) do
	local hosts, proxies = {}, {}
	for _, row in ipairs(entry.env or {}) do
		local name, value = row:match("^([^=]+)=(.*)$")
		if name == "OLLAMA_HOST" then hosts[#hosts + 1] = value end
		if name == "HTTPS_PROXY" or name == "NO_PROXY" or name == "no_proxy" then proxies[name] = value end
	end
	result.served[#result.served + 1] = { executable = entry.executable, ollama_host = hosts,
		proxy = proxies, running = entry.operation:is_running() == true }
end
result.direct_fallback = require("modules.llm.ollama_install_state").direct_fallback(result.base_url)

local tag = os.getenv("ERGOPTI_PROOF_PULL_TAG")
if result.enabled and tag and tag ~= "" then
	local terminal, succeeded
	local original_complete = Window.complete
	Window.complete = function(session, ok, message, receipt)
		terminal, succeeded, result.pull_message = true, ok == true, message
		return original_complete(session, ok, message, receipt)
	end
	result.pull_dispatched = Download.start(result.base_url, tag, tag, nil, function() return true end) == true
	wait_until(function() return terminal end)
	result.pull_succeeded = succeeded == true
	Window.complete = original_complete
end

-- Switching the AI off ends the daemon the app started for it.
Engine.disable()
wait_until(function()
	for _, entry in ipairs(served) do if not entry.operation:is_settled() then return false end end
	return not Engine.runtime_pending()
end)
result.daemon_retired = true
for _, entry in ipairs(served) do result.daemon_retired = result.daemon_retired and entry.operation:is_settled() end
result.expired = expired

local retired
repeat
	retired = Download.shutdown() == true and Engine.stop_runtime() == true
		and Http.cancel("llm_enable_admission") == true
	if not retired then uv.run("once") end
until retired or expired
ceiling:stop(); ceiling:close()
EventLoop.stop()
Native.start = original_start
io.stdout:write("ERGOPTI_OWNED_OLLAMA_RESULT:", Json.encode(result), "\n")
