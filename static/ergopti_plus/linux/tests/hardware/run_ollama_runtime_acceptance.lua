--- tests/hardware/run_ollama_runtime_acceptance.lua

--- ==============================================================================
--- MODULE: Actual Engine and Explicit Model Pull Acceptance
--- DESCRIPTION:
--- Installs the pinned official runtime through actual owned HTTPS transport.
--- Exercises independent explicit model consent, production pull/progress
--- owners, native inventory, streamed inference and physical retirement.
--- Consent and WebKit presentation are controlled; HTTP/model effects are real.
--- ==============================================================================

local repository, port = assert(arg[1]), assert(tonumber(arg[2]))
-- Production acceptance loads the actual adopted checkout sources. Frozen
-- packet paths are evidence/fixture locations, never an implementation override.
package.path = repository .. "/static/ergopti_plus/linux/?.lua;"
	.. repository .. "/static/ergopti_plus/linux/?/init.lua;"
	.. repository .. "/static/ergopti_plus/_shared/lua/?.lua;"
	.. repository .. "/static/ergopti_plus/_shared/lua/?/init.lua;" .. package.path
local action = "download"
assert(action == "download" or action == "start", "explicit expected runtime choice")
local uv = require("luv")
assert(type(uv.getuid()) == "number" and uv.getuid() > 0, "actual non-root native user identity")
assert(uv.fs_lstat("/").uid == 0, "actual trusted root inode owner")
print("NATIVE_IDENTITY uid=" .. tostring(uv.getuid()) .. " root_uid=" .. tostring(uv.fs_lstat("/").uid))
local Logger = require("logger.shim")
for _, level in ipairs({ "error", "warn", "info" }) do
	local original = Logger[level]
	Logger[level] = function(tag, format, ...)
		print("NATIVE_LOG " .. level .. " " .. tostring(tag) .. " " .. string.format(format, ...))
		return original(tag, format, ...)
	end
end
local Http = require("adapters.http_client")
local Native = require("adapters.owned_process")
local Timings = require("infra.timings")
local Engine, Profiles
local chronological, native_services = {}, {}
local original_native_start = Native.start
Native.start = function(executable, arguments, options, callback)
	local operation = original_native_start(executable, arguments, options, callback)
	if arguments[1] == "serve" then native_services[#native_services + 1] = { operation = operation, executable = executable, timeout = options.timeout_ms } end
	return operation
end
local original_get_owned = Http.get_owned
local archive_dispatches, scripted_choices, changed = 0, 0, 0
local archive_options, archive_operation, checksum_receipt
local owned_get_operations = {}
local function checkpoint(phase) print("ACCEPTANCE_PHASE " .. phase) end
local configured_origin = "http://127.0.0.1:" .. tostring(port)
local observed_urls = {}
-- Observe production archive transport unchanged; never replace HTTP or package effects.
Http.get_owned = function(url, headers, options, callback)
	if options.output_path then
		archive_dispatches = archive_dispatches + 1
		archive_options = { url = url, https_only = options.https_only, bytes = options.max_download_bytes }
	end
	observed_urls[#observed_urls + 1] = url
	local operation = original_get_owned(url, headers, options, function(result)
		local typed = require("llm.enable_admission").receipt(result)
		if typed then
			chronological[#chronological + 1] = { kind = "typed_version", engine = Engine.is_enabled(),
				profile = Profiles.is_enabled(), version = require("json").decode(result.body).version }
		end
		return callback(result)
	end)
	owned_get_operations[#owned_get_operations + 1] = operation
	if options.output_path then archive_operation = operation end
	return operation
end
local Files = require("modules.llm.ollama_install_files")
local original_files_new = Files.new
Files.new = function(...)
	local owner, reason = original_files_new(...)
	if owner then
		local admit = owner.admit_checksum
		owner.admit_checksum = function(asset, result)
			local accepted, refusal = admit(asset, result)
			checksum_receipt = { accepted = accepted, bytes = type(asset) == "table" and asset.bytes, digest = type(result) == "table" and type(result.stdout) == "string" and result.stdout:match("^([0-9a-f]+)  .+%z$") }
			return accepted, refusal
		end
	end
	return owner, reason
end
-- Explicit scripted UI input is isolated from actual engine/profiles/writer.
-- This fixture does not fabricate a physical keyboard/modal restoration receipt.
package.loaded["ui.llm_enable_refusal"] = { show = function(origin, rows)
	scripted_choices = scripted_choices + 1
	for _, row in ipairs(rows) do print("EXPLICIT_ROW " .. tostring(row.label)) end
	local selected
	for _, row in ipairs(rows) do
		if row.label == require("infra.i18n").get(action == "download" and "ollama.offer_download" or "ollama.runtime_start") then selected = row.value end
	end
	return true, false, selected
end }
Profiles = require("modules.llm.profiles")
local original_profile_enable = Profiles.enable
Profiles.enable = function(...)
	chronological[#chronological + 1] = { kind = "profile_write", engine = Engine and Engine.is_enabled() or false, profile = Profiles.is_enabled() }
	return original_profile_enable(...)
end
local Preferences = require("infra.llm_preferences")
Engine = require("modules.llm.prediction_engine")
Engine.init({ is_paused = function() return false end })
-- Public profile initialization configures this fixture's isolated listener;
-- source provenance and subsequent publication remain the actual owners.
Profiles.init({ port = port })
local Config = require("infra.config_paths").config("config.toml")
local Writer = require("toml_codec.writer")
-- Control only WebKit presentation: actual bridge retains session ownership.
local window_calls = { show = 0, hide = 0, evaluate = 0 }
package.loaded["ui.webview_manager"] = {
	show = function() window_calls.show = window_calls.show + 1; return true end,
	hide = function() window_calls.hide = window_calls.hide + 1; return true end,
	eval_js = function() window_calls.evaluate = window_calls.evaluate + 1; return true end,
	bring_to_front = function() return true end,
	is_visible = function() return true end,
}
local Json = require("json")
local Policy = require("llm.local_model_policy")
local Api = require("modules.llm.api_ollama")
local Download = require("modules.llm.model_download")
local Offer = require("modules.llm.local_model_offer")
local Window = require("ui.download_window.bridge")
local model = "granite4:350m-h"
local model_consents, pull_dispatches, chat_dispatches = 0, 0, 0
local pull_timeout, pull_terminal, pull_result
local original_complete, original_show, original_post = Window.complete, Window.show, Http.postStream
local original_owned_post = Http.post_stream_owned
assert(type(original_owned_post) == "function", "production owned streaming POST capability is required")
local pull_operation
local model_session, session_starts = nil, 0
Window.show = function(options)
	local session = original_show(options)
	model_session, session_starts = session, session_starts + 1
	return session
end
Window.complete = function(session, succeeded, message, failure_receipt)
	if session == model_session then pull_terminal, pull_result = true, succeeded == true end
	return original_complete(session, succeeded, message, failure_receipt)
end
Http.postStream = function(url, headers, body, options, chunk, done)
	if url == configured_origin .. "/api/chat" then chat_dispatches = chat_dispatches + 1 end
	return original_post(url, headers, body, options, chunk, done)
end
Http.post_stream_owned = function(url, headers, body, options, chunk, done)
	local operation = original_owned_post(url, headers, body, options, chunk, done)
	if url == configured_origin .. "/api/pull" then
		pull_dispatches = pull_dispatches + 1
		pull_timeout, pull_operation = options.timeout_ms, operation
	end
	return operation
end
-- Only explicit confirmation is injected; default offer install is production Download.
Offer._reset_for_test({ confirm = function()
	model_consents = model_consents + 1
	return true
end })
local EventLoop = require("adapters.event_loop")
local expired = false
local fixture_timer = assert(uv.new_timer())
assert(fixture_timer:start(900000, 0, function()
	expired = true
	Download.shutdown()
	Api.cancel()
	Http.cancel("model-acceptance-list")
	Engine.stop_runtime()
	EventLoop.stop()
end) == 0, "finite external fixture deadline acquired")
local function wait_until(predicate)
	while not predicate() and not expired and uv.loop_alive() do uv.run("once") end
	assert(not expired, "external 15-minute acceptance ceiling; existing product pull deadline unchanged")
end
local function list_models()
	local response
	local op = original_get_owned(configured_origin .. "/api/tags", {}, {
		owner = "model-acceptance-list", timeout_ms = Timings.ms("llm", "local_server_probe_timeout_ms"),
		follow_redirects = false,
	}, function(result) response = result end)
	wait_until(function() return op:is_settled() end)
	local names, reason = Policy.list_receipt(response)
	assert(names, reason or "actual typed inventory receipt")
	return names
end
local inference_text, initial_missing
local ok, diagnostic = xpcall(function()
	assert(Engine.get_backend() == "ollama" and Engine.get_current_model() == model,
		"actual canonical fixture model and backend selection")
	assert(Engine.get_base_url() == configured_origin, "exact configured loopback origin")
	assert(not Engine.is_enabled() and not Profiles.is_enabled(), "disabled owners before explicit binary-only installation")
	checkpoint("official-https-install")
	Engine.enable(function() changed = changed + 1 end)
	wait_until(function() return Engine.is_enabled() end)
	assert(Engine.is_enabled() and Profiles.is_enabled() and Preferences.get("llm.enabled") == true,
		"actual existing writer acknowledges engine enable")
	assert(scripted_choices == 1 and archive_dispatches == 1 and changed == 1,
		"one explicit binary-only choice, one actual HTTPS archive and one writer refresh")
	assert(archive_options.url == "https://github.com/ollama/ollama/releases/download/v0.24.0/ollama-linux-amd64.tar.zst"
		and archive_options.https_only == true and archive_options.bytes == 1198635318,
		"exact independently frozen official HTTPS archive admission")
	assert(checksum_receipt and checksum_receipt.accepted == true and checksum_receipt.bytes == 1198635318
		and checksum_receipt.digest == "15c5f8d66ba06e0d3b4719df8868612dbd66e14e82760929bb3552e1657cdcdb",
		"full actual archive digest matches independent official receipt before extraction")
	assert(archive_operation and archive_operation:is_settled() == true, "exact archive HTTP physically settled")
	assert(#chronological >= 2 and chronological[1].kind == "typed_version"
		and chronological[1].version == "0.24.0" and chronological[1].engine == false
		and chronological[1].profile == false and chronological[2].kind == "profile_write",
		"actual typed readiness before enable publication")
	assert(#native_services == 1 and native_services[1].timeout == nil
		and native_services[1].operation:is_running() == true, "one actual owned daemon without arbitrary deadline")
	checkpoint("missing-model-preflight")
	assert(not list_models()[Policy.normalize(model)], "independent initial inventory proves model absent")
	local first_finished = false
	local dispatched = Api.chat(configured_origin, model, { { role = "user", content = "Reply with one short greeting." } },
		{ stream = true, max_tokens = 16, temperature = 0, verify_local_model = true }, nil,
		function(_, reason) initial_missing = reason; first_finished = true end)
	assert(dispatched == true, "actual missing-model preflight dispatched")
	wait_until(function() return first_finished end)
	assert(Policy.is_missing(initial_missing) and initial_missing.model == model
		and initial_missing.base_url == configured_origin, "actual preflight publishes originating model absence")
	assert(model_consents == 0 and pull_dispatches == 0 and chat_dispatches == 0,
		"missing preflight sends no inference or unconsented pull")
	checkpoint("explicit-model-pull")
	assert(Offer.handle(initial_missing, { current = function()
		return not expired and Engine.is_enabled() and Engine.get_base_url() == configured_origin
			and native_services[1].operation:is_running() == true
	end }) == true, "existing offer handles independent explicit model consent")
	assert(model_consents == 1 and pull_dispatches == 1 and session_starts == 1
		and model_session ~= nil and window_calls.show == 1, "one explicit model consent, exact progress session and real pull dispatch")
	assert(pull_timeout == 86400000, "existing production 24-hour pull deadline preserved")
	wait_until(function() return pull_terminal end)
	assert(pull_result == true and Download.is_active() == false, "actual NDJSON pull successfully completed")
	assert(pull_operation and pull_operation:is_settled() == true, "exact owned model HTTP physically settled before successful publication")
	assert(list_models()[Policy.normalize(model)] == true, "independent final inventory contains exact model")
	checkpoint("real-model-chat")
	local chat_finished, chat_error = false, nil
	dispatched = Api.chat(configured_origin, model, { { role = "user", content = "Reply with one short greeting." } },
		{ stream = true, max_tokens = 16, temperature = 0, verify_local_model = true }, nil,
		function(text, reason) inference_text = text; chat_error = reason; chat_finished = true end)
	assert(dispatched == true, "actual admitted inference preflight dispatched")
	wait_until(function() return chat_finished end)
	assert(chat_error == nil and type(inference_text) == "string" and #inference_text > 0,
		"real API chat produces nonempty streamed text")
	assert(chat_dispatches == 1 and pull_dispatches == 1 and model_consents == 1,
		"one inference after installed inventory; no repeated consent")
	local answer = assert(io.open(assert(os.getenv("ERGOPTI_MODEL_RECEIPT_DIR")) .. "/inference.private.txt", "wb"))
	local wrote, closed = answer:write(inference_text), answer:close()
	assert(wrote and closed, "private inference receipt captured")
	assert(Engine.disable() == true and not Engine.is_enabled(), "actual master disable after inference")
	assert(native_services[1].operation:is_running() == true, "exact daemon survives disabled enable ticket")
end, debug.traceback)
checkpoint("terminal-physical-shutdown")
-- Exercise the adopted terminal engine owner through the actual coordinator
-- and actual native event-loop idle pump. Only keyboard presence is controlled.
local shutdown_polls, stop_before_ack, coordinator_requested = 0, false, false
local original_loop_stop = EventLoop.stop
EventLoop.stop = function()
	if #native_services == 1 and (not native_services[1].operation:is_settled() or Engine.runtime_pending()) then
		stop_before_ack = true
	end
	return original_loop_stop()
end
local shutdown_ok, shutdown_error = xpcall(function()
	assert(type(Engine.shutdown_runtime) == "function", "actual adopted terminal runtime shutdown owner")
	local coordinator = require("infra.shutdown_coordinator").new({
		pre_wait = { { name = "engine-runtime-acceptance", wait_for_ack = true, stop = Engine.shutdown_runtime } },
		keyboard_hook = { isRunning = function() return false end, stop = function() end, emergency_stop = function() end },
		event_loop = EventLoop,
	})
	assert(type(coordinator.poll) == "function" and type(coordinator.is_pending) == "function",
		"adopted ACK-gated coordinator contract")
	coordinator_requested = coordinator.request("native model acceptance") == true
	assert(coordinator_requested, "one-shot originating shutdown request admitted")
	if coordinator.is_pending() then
		EventLoop.run({ onIdle = function()
			shutdown_polls = shutdown_polls + 1
			coordinator.poll()
		end })
	end
	assert(not expired and not coordinator.is_pending() and not EventLoop.isRunning(),
		"actual coordinator polls physical retirement before stopping actual event loop")
	assert(stop_before_ack == false, "actual event-loop stop never precedes native process and runtime ACK")
	assert(Engine.enable() == false, "closed terminal app refuses new enable intent after shutdown")
end, debug.traceback)
EventLoop.stop = original_loop_stop
-- Physical settlement remains mandatory on every logical failure and timeout.
assert(fixture_timer:stop() == 0, "external fixture timer stopped")
fixture_timer:close()
local retired = false
repeat
	local download_ack = Download.shutdown() == true
	local api_ack = Api.cancel() == true
	local lists_ack = Http.cancel("model-acceptance-list") == true
	local enables_ack = Http.cancel("llm_enable_admission") == true
	local runtime_ack = Engine.stop_runtime() == true
	local owned_ack = true
	for _, operation in ipairs(owned_get_operations) do
		if not operation:is_settled() then operation:cancel() end
		owned_ack = operation:is_settled() == true and owned_ack
	end
	if pull_operation and not pull_operation:is_settled() then pull_operation:cancel() end
	owned_ack = (not pull_operation or pull_operation:is_settled() == true) and owned_ack
	retired = download_ack and api_ack and lists_ack and enables_ack and runtime_ack and owned_ack
	if not retired then uv.run("once") end
until retired
while uv.loop_alive() do uv.run("once") end
assert(not Download.is_active() and not Engine.runtime_pending(), "model HTTP and application cleanup debt retired")
if #native_services == 1 then assert(native_services[1].operation:is_settled() == true, "exact owned serve physically retired") end
Http.get_owned, Http.postStream, Http.post_stream_owned = original_get_owned, original_post, original_owned_post
Files.new = original_files_new
Native.start, Profiles.enable, Window.complete, Window.show = original_native_start, original_profile_enable, original_complete, original_show
Offer._reset_for_test()
if not ok then error(diagnostic) end
if not shutdown_ok then error(shutdown_error) end
print(Json.encode({ passed = true, model = model, explicit_binary_choices = scripted_choices,
	explicit_model_choices = model_consents, pull_dispatches = pull_dispatches, chat_dispatches = chat_dispatches,
	shutdown_idle_polls = shutdown_polls, terminal_shutdown_requested = coordinator_requested,
	event_loop_stop_before_ack = stop_before_ack, inference_bytes = #inference_text, typed_version = chronological[1].version,
	owned_serve_settled = native_services[1].operation:is_settled(), native_loop_retired = not uv.loop_alive(),
	external_fixture_ceiling_ms = 900000, product_pull_timeout_ms = pull_timeout,
	gui = "scripted consent and WebKit presentation; no physical GUI/input claim",
	shutdown_scope = "actual Engine, ShutdownCoordinator and native EventLoop; daemon entrypoint not executed",
	archive_bytes = checksum_receipt.bytes, archive_sha256 = checksum_receipt.digest, archive_http_settled = archive_operation:is_settled(),
	pull_http_settled = pull_operation:is_settled(), binary = "actual per-user pinned official HTTPS installation", model_transport = "actual Ollama pull; upstream success required" }))
