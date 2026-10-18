--- tests/hardware/run_local_api_auth.lua

--- ==============================================================================
--- MODULE: Native Local API Authentication Receipts
--- DESCRIPTION:
--- Exercises actual curl/libuv models and chat at a configurable loopback URL.
--- Credentials, HTTP refusal and cancelled or changed sources retain their owners.
--- ==============================================================================

package.path = "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;" .. package.path
local native_cpath = os.getenv("ERGOPTI_NATIVE_LUA_CPATH")
if native_cpath and native_cpath ~= "" then package.cpath = native_cpath end
local available, uv = pcall(require, "luv")
if not available then io.stderr:write("ENVIRONMENT: native lua-luv is required\n"); os.exit(2) end
require("compat.utf8").install()
local Http = require("adapters.http_client")
local EventLoop = require("adapters.event_loop")
local Remote = require("modules.llm.api_remote")
local Json = require("json")
local failures, checks, sockets, requests = {}, 0, {}, {}
local response = { status = 200, body = '{"data":[{"id":"fixture-model"}]}' }

local function check(value, message)
	checks = checks + 1
	print((value and "ok   " or "FAIL ") .. message)
	if not value then failures[#failures + 1] = message end
end
local function close(handle)
	if handle and not uv.is_closing(handle) then uv.close(handle) end
end
local function run_until(predicate)
	local deadline = uv.now() + 5000
	local timer = uv.new_timer()
	uv.timer_start(timer, 10, 10, function()
		-- The real daemon pumps deferred discovery after its keyboard idle callback.
		EventLoop._run_idle_tick()
		if predicate() or uv.now() > deadline then uv.stop() end
	end)
	uv.run()
	uv.timer_stop(timer); close(timer); uv.run("nowait")
	return predicate() == true
end
local server = uv.new_tcp()
local bound = server:bind("127.0.0.1", 0)
if not bound then close(server); io.stderr:write("ENVIRONMENT: owned loopback bind failed\n"); os.exit(2) end
local base_url = "http://127.0.0.1:" .. server:getsockname().port .. "/v1"
server:listen(16, function(error)
	if error then failures[#failures + 1] = "owned server accept failed"; return end
	local socket = uv.new_tcp(); sockets[#sockets + 1] = socket; server:accept(socket)
	local input, handled = "", false
	socket:read_start(function(read_error, chunk)
		if read_error or not chunk then close(socket); return end
		if handled then return end
		input = input .. chunk
		local boundary = input:find("\r\n\r\n", 1, true)
		if not boundary then return end
		local length = tonumber(input:sub(1, boundary):lower():match("content%-length:%s*(%d+)")) or 0
		if #input < boundary + 3 + length then return end
		handled = true
		local method, route = input:match("^(%u+) ([^ ]+) ")
		requests[#requests + 1] = { method = method, route = route,
			authorization = input:sub(1, boundary):match("[Aa]uthorization: ([^\r\n]+)"),
			body = input:sub(boundary + 4) }
		if response.pending then return end
		local body = route:match("/chat/completions$") and '{"choices":[{"message":{"content":"native reply"}}]}' or response.body
		local header = "HTTP/1.1 " .. response.status .. " Fixture\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: " .. #body .. "\r\n\r\n"
		socket:write(header .. body, function() socket:shutdown(function() close(socket) end) end)
	end)
end)
local entry = { id = "local", provider = "lmstudio", token = "", model = "fixture-model", base_url = base_url }
local function models()
	local observed = { done = false, calls = 0 }
	local started = Remote.models(entry, function(ids, reason)
		observed.ids, observed.reason, observed.done = ids, reason, true
		observed.calls = observed.calls + 1
	end)
	check(started == true, "actual local models request is dispatched")
	check(run_until(function() return observed.done end), "actual native models receipt settles")
	check(observed.calls == 1 and not Remote.is_active() and not Http.isActive(), "native and API models owners settle exactly once")
	return observed
end
local first = models()
check(first.ids and first.ids[1] == "fixture-model" and first.reason == nil, "native models JSON supplies a selectable model")
check(requests[1].method == "GET" and requests[1].route == "/v1/models" and requests[1].authorization == nil, "keyless models uses the exact configured endpoint without Authorization")
local completed, text, reason = false, nil, nil
check(Remote.chat(entry, nil, { { role = "user", content = "inert fixture" } }, {}, nil,
	function(value, failure) text, reason, completed = value, failure, true end) == true, "models selection dispatches the actual chat consumer")
check(run_until(function() return completed end), "native local chat completes")
check(text == "native reply" and reason == nil and not Http.isActive() and not Remote.is_active(), "actual chat receipt releases both owners")
check(requests[2].method == "POST" and requests[2].route == "/v1/chat/completions" and requests[2].authorization == nil
	and Json.decode(requests[2].body).model == "fixture-model", "keyless chat retains selected model and omits blank Bearer")
-- Generic API identities at a nondefault loopback port retain their configured
-- URL and may prove keyless availability without inheriting a catalogue identity.
for _, provider in ipairs({ "openai", "openai_compat" }) do
	entry.provider, entry.model = provider, "mlx-community/Qwen3-8B-4bit"
	response = { status = 200, body = '{"object":"list","data":[{"id":"mlx-community/Qwen3-8B-4bit","object":"model","owned_by":"omlx"},{"id":"gemma-3-4b-it-4bit","object":"model","owned_by":"omlx"}]}' }
	local observed = models()
	check(observed.ids and observed.ids[1] == "mlx-community/Qwen3-8B-4bit" and observed.ids[2] == "gemma-3-4b-it-4bit",
		provider .. " actual nondefault loopback models preserve opaque oMLX IDs")
	check(requests[#requests].route == "/v1/models" and requests[#requests].authorization == nil,
		provider .. " actual keyless request omits Authorization")
	local generic_done, generic_text, generic_reason = false, nil, nil
	check(Remote.chat(entry, nil, { { role = "user", content = "inert generic fixture" } }, {}, nil,
		function(value, failure) generic_text, generic_reason, generic_done = value, failure, true end) == true,
		provider .. " selected model dispatches actual configured chat")
	check(run_until(function() return generic_done end) and generic_text == "native reply" and generic_reason == nil,
		provider .. " native selected-model chat completes")
	check(Json.decode(requests[#requests].body).model == entry.model and requests[#requests].authorization == nil,
		provider .. " actual chat retains the selected model and omitted key")
	response = { status = 401, body = '{"error":{"message":"API key required","type":"authentication_error"}}' }
	local protected = models()
	check(protected.ids == nil and protected.reason == "http_failure",
		provider .. " protected loopback is not promoted by optional credential admission")
end
entry.provider, entry.model = "lmstudio", "fixture-model"
response = { status = 200, body = '{"data":[{"id":"fixture-model"}]}' }
entry.token = "inert-provided-token"
local supplied = models()
check(supplied.ids ~= nil and requests[#requests].authorization == "Bearer inert-provided-token", "provided local credentials reach the actual header unchanged")
entry.token = ""
response = { status = 401, body = '{"error":"authentication required"}' }
local rejected = models()
check(rejected.ids == nil and rejected.reason == "http_failure", "actual 401 cannot become a models list")
response = { status = 200, body = '{"data":{}}' }
local malformed = models()
check(malformed.ids == nil and malformed.reason == "invalid_models", "actual object in place of models array is refused")
response = { status = 200, body = '{"data":[]}' }
local stale = { done = false }
check(Remote.models(entry, function(ids, failure) stale.ids, stale.reason, stale.done = ids, failure, true end), "source-switch control begins an actual request")
entry.base_url = base_url .. "/changed"
check(run_until(function() return stale.done end) and stale.ids == nil and stale.reason == "identity_changed", "changed configured source cannot admit its old native answer")
entry.base_url = base_url
response = { pending = true }
local calls, before = 0, #requests
check(Remote.models(entry, function() calls = calls + 1 end), "cancel control owns a real pending curl process")
check(run_until(function() return #requests > before end), "pending request actually reached its configured server")
local cancelled = Remote.cancel()
check(cancelled == true, "cancellation requires the actual native transport acknowledgement")
check(run_until(function() return not Http.isActive() end) and not Remote.is_active() and calls == 0, "cancelled owner settles without a late models publication")
-- The actual discovery/menu consumer uses independent native GET owners, then
-- the acknowledged private entry and existing chat owner, at this configured URL.
local Entries = require("modules.llm.api_entries")
local private_path = os.tmpname(); os.remove(private_path)
Entries._set_path_for_test(private_path)
for _, id in ipairs({ "omlx", "lmstudio", "llamacpp", "jan" }) do
	check(Entries.add({ provider = id, label = id, token = "", model = "before", base_url = base_url }) ~= nil,
		"native discovery stores the configured " .. id .. " source through its private owner")
end
local Servers = require("modules.llm.local_servers")
response = { status = 200, body = '{"data":[{"id":"discovered-model"}]}' }
local discovery_done, discovery_calls = false, 0
check(Servers.rescan(function() return true end, function()
	discovery_done, discovery_calls = true, discovery_calls + 1
end), "native discovery acquires the four actual curl owners")
check(run_until(function() return discovery_done end), "native discovery jointly settles after actual handle closes")
check(discovery_calls == 1 and #Servers.detected() == 4 and Servers.result("omlx").models[1] == "discovered-model",
	"actual strict models receipts populate the catalogue menu")
local backend, writes = "ollama", 0
local rows = require("ui.menu.local_server_rows").rows({
	get_backend = function() return backend end,
	can_configure_local_servers = function() return true end,
	set_backend = function(value) backend, writes = value, writes + 1; return true end,
}, { prompt = function() return nil end, error = function() end }, function() end,
	{ is_paused = function() return false end })
local function model_row(items)
	for _, row in ipairs(items) do
		if row.label == "discovered-model" then return row end
		if row.items then local found = model_row(row.items); if found then return found end end
	end
end
local choice = model_row(rows)
check(choice ~= nil and type(choice.action) == "function", "actual shared/native menu exposes the discovered model")
local selected = choice and choice.action()
check(selected and selected.saved == true and selected.selected == true and backend == "api" and writes == 1,
	"actual model action acknowledges private entry then independent backend owner")
local selected_entry = Entries.active()
check(selected_entry and selected_entry.provider == "omlx" and selected_entry.model == "discovered-model",
	"the actual selected entry supplies the discovered chat target")
local chat_done, chat_text = false, nil
check(Remote.chat(selected_entry, nil, {{ role = "user", content = "inert discovery fixture" }}, {}, nil,
	function(value) chat_text, chat_done = value, true end), "the selected discovery entry acquires the actual chat consumer")
check(run_until(function() return chat_done end) and chat_text == "native reply",
	"discovery to model choice to actual curl chat succeeds")
local reloaded = require("tests.helpers").load_module("modules.llm.api_entries")
reloaded._set_path_for_test(private_path)
check(reloaded.active() and reloaded.active().model == "discovered-model",
	"the acknowledged discovered model survives actual private-file restart")
-- Drain any post-selection rescan before changing the controlled server response.
check(run_until(function() return not Servers.is_sweeping() end), "the post-selection discovery owner settles")
response = { status = 401, body = '{"error":"key required"}' }
discovery_done = false
Servers.rescan(function() return true end, function() discovery_done = true end)
check(run_until(function() return discovery_done end) and Servers.result("omlx").status == "needs_key",
	"actual native authentication refusal is a key-needed row, never a model")
response = { status = 200, body = '{"data":{}}' }
discovery_done = false
Servers.rescan(function() return true end, function() discovery_done = true end)
check(run_until(function() return discovery_done end) and #Servers.detected() == 0,
	"actual malformed models receipt cannot populate native discovery")
-- Explicit generic entries at this nondefault loopback port are discovery
-- views of their private rows, never inferred catalogue server identities.
local configured_entries = {}
for _, provider in ipairs({ "openai", "openai_compat" }) do
	local configured = Entries.add({ provider = provider, label = "Personal " .. provider, token = provider == "openai" and "inert-configured-key" or "",
		model = "before", base_url = base_url .. "/" .. provider })
	check(configured ~= nil, provider .. " configured discovery stores its actual private source")
	configured_entries[#configured_entries + 1] = configured
end
response = { status = 200, body = '{"object":"list","data":[{"id":"mlx-community/Qwen3-8B-4bit","object":"model","owned_by":"omlx"},{"id":"gemma-3-4b-it-4bit","object":"model","owned_by":"omlx"}]}' }
discovery_done = false
local configured_before = #requests
Servers.rescan(function() return true end, function() discovery_done = true end)
check(run_until(function() return discovery_done end), "actual configured discovery jointly settles all six curl owners")
check(#Servers.order() == 6 and #requests == configured_before + 6, "actual configured endpoints append exactly two owned probes without port scanning")
for index, configured in ipairs(configured_entries) do
	local id = "configured:" .. configured.id
	local verdict = Servers.result(id)
	check(verdict and verdict.status == "up" and verdict.models[1] == "mlx-community/Qwen3-8B-4bit",
		configured.provider .. " actual configured models publish in their own view")
	local expected = configured.token ~= "" and "Bearer " .. configured.token or nil
	local observed_auth, observed_route, observed_matches = nil, "/v1/" .. configured.provider .. "/models", 0
	for request_index = configured_before + 1, configured_before + 6 do
		local request = requests[request_index]
		if request.route == observed_route then observed_auth = request.authorization; observed_matches = observed_matches + 1 end
	end
	check(observed_matches == 1 and observed_auth == expected,
		configured.provider .. " actual configured discovery retains its exact optional authentication")
	local configured_rows = require("ui.menu.local_server_rows").rows({
		get_backend = function() return backend end,
		can_configure_local_servers = function() return true end,
		set_backend = function(value) backend, writes = value, writes + 1; return true end,
	}, { prompt = function() return nil end, error = function() end }, function() end,
		{ is_paused = function() return false end })
	local configured_choice
	for _, row in ipairs(configured_rows) do
		if row.items and row.label:find(Remote.provider(configured.provider).label .. " 🖥️", 1, true) == 1 then
			for _, child in ipairs(row.items) do
				if child.label == "mlx-community/Qwen3-8B-4bit" then configured_choice = child; break end
			end
		end
	end
	check(configured_choice and type(configured_choice.action) == "function",
		configured.provider .. " actual native menu exposes the originating configured model row")
	local saved = configured_choice and configured_choice.action()
	check(saved and saved.selected and backend == "api" and writes == 1 + index,
		configured.provider .. " actual model action acknowledges its independent backend selection")
	check(run_until(function() return not Servers.is_sweeping() end), configured.provider .. " post-selection configured sweep retires")
	check(saved and saved.saved and saved.entry.id == configured.id and saved.entry.provider == configured.provider
		and saved.entry.label == configured.label and #Entries.list() == 6,
		configured.provider .. " configured selection acknowledges the originating row without duplicate or rebranding")
	local native_done, native_text = false, nil
	check(saved and Remote.chat(saved.entry, nil, {{ role = "user", content = "configured discovery fixture" }}, {}, nil,
		function(value) native_text, native_done = value, true end), configured.provider .. " configured selection dispatches actual curl chat")
	check(run_until(function() return native_done end) and native_text == "native reply"
		and Json.decode(requests[#requests].body).model == "mlx-community/Qwen3-8B-4bit"
		and requests[#requests].authorization == expected, configured.provider .. " actual configured chat preserves model and authentication")
	local restarted = require("tests.helpers").load_module("modules.llm.api_entries")
	restarted._set_path_for_test(private_path)
	check(restarted.active() and restarted.active().id == configured.id and restarted.active().provider == configured.provider
		and restarted.active().model == "mlx-community/Qwen3-8B-4bit", configured.provider .. " selected row survives actual private-file restart")
end
response = { status = 401, body = '{"error":{"message":"API key required","type":"authentication_error"}}' }
discovery_done = false
Servers.rescan(function() return true end, function() discovery_done = true end)
check(run_until(function() return discovery_done end), "actual protected configured probes settle")
for _, configured in ipairs(configured_entries) do
	check(Servers.result("configured:" .. configured.id).status == "needs_key", configured.provider .. " configured 401 never becomes a model or an identity proof")
end
-- An answering OpenAI endpoint with no loaded models is reachable, not absent.
-- Literal independent HTTP controls distinguish empty arrays from malformed lists.
response = { status = 200, body = '{"object":"list","data":[]}' }
discovery_done = false
Servers.rescan(function() return true end, function() discovery_done = true end)
check(run_until(function() return discovery_done end), "actual empty OpenAI lists jointly settle all six native probes")
for _, id in ipairs(Servers.order()) do
	local verdict = Servers.result(id)
	check(verdict and verdict.status == "up" and #verdict.models == 0,
		id .. " valid empty models list is reachable without selectable model IDs")
end
check(#Servers.detected() == 6, "empty model lists retain all actual reachable server views")
local empty_rows = require("ui.menu.local_server_rows").rows({
	get_backend = function() return backend end,
	can_configure_local_servers = function() return true end,
	set_backend = function() error("empty model rows cannot acquire the backend setter") end,
}, { prompt = function() return nil end, error = function() end }, function() end,
	{ is_paused = function() return false end })
local no_models_label = require("infra.i18n").get("menu.llm.local_servers.no_models")
local empty_count, empty_disabled = 0, true
for _, row in ipairs(empty_rows) do
	for _, child in ipairs(row.items or {}) do
		if child.label == no_models_label then
			empty_count = empty_count + 1
			empty_disabled = empty_disabled and child.disabled == true and child.action == nil
		end
	end
end
check(empty_count == 6 and empty_disabled, "actual empty-model menu exposes six disabled no-models rows without selection actions")
for _, control in ipairs({
	{ label = "object instead of model array", status = 200, body = '{"object":"list","data":{}}' },
	{ label = "non-object models root", status = 200, body = '[{"object":"list","data":[]}]' },
	{ label = "HTTP 404 with a valid empty list", status = 404, body = '{"object":"list","data":[]}' },
}) do
	response = { status = control.status, body = control.body }
	discovery_done = false
	Servers.rescan(function() return true end, function() discovery_done = true end)
	check(run_until(function() return discovery_done end), control.label .. " native negative control settles")
	for _, id in ipairs(Servers.order()) do
		check(Servers.result(id).status == "down", id .. " " .. control.label .. " is down, never unavailable")
	end
	check(#Servers.detected() == 0, control.label .. " cannot publish reachable or selectable model rows")
end
-- Real file drift after all six native acquisitions fences their old receipts;
-- restore exact fixture-owned bytes only after the joint negative publication.
local source_reader = assert(io.open(private_path, "rb"))
local exact_source = source_reader:read("*a"); source_reader:close()
local source_receipt = Servers.capture("configured:" .. configured_entries[1].id)
response = { status = 200, body = '{"data":[{"id":"obsolete-after-source-drift"}]}' }
discovery_done = false
local drift_before = #requests
Servers.rescan(function() return true end, function() discovery_done = true end)
-- Preserve this control's acquisition-before-drift premise under idle dispatch.
EventLoop._run_idle_tick()
local source_writer = assert(io.open(private_path, "wb")); source_writer:write(exact_source .. "\n"); source_writer:close()
check(run_until(function() return discovery_done end) and #requests == drift_before + 6,
	"all six acquired native probes settle across actual private-file drift")
check(#Servers.detected() == 0, "changed physical source refuses every old native positive model response")
check(Servers.apply(source_receipt, { model = "obsolete-after-source-drift" }, function() return true end) == nil,
	"changed physical source refuses the captured configured selection")
local source_restore = assert(io.open(private_path, "wb")); source_restore:write(exact_source); source_restore:close()
check(Entries.active().model == "mlx-community/Qwen3-8B-4bit",
	"refused stale discovery never overwrites the acknowledged personal model")
response = { pending = true }
local discovery_before, cancelled_publications = #requests, 0
Servers.rescan(function() return true end, function() cancelled_publications = cancelled_publications + 1 end)
check(run_until(function() return #requests >= discovery_before + 4 end), "all four cancelled probes reached the actual native server")
check(run_until(function() return #requests >= discovery_before + 6 end), "both configured pending probes retain actual native cancellation owners")
local held_configured = Servers.capture("configured:" .. configured_entries[1].id)
local first_cancel = Servers.cancel()
check(first_cancel == false, "native kill acknowledgement alone does not settle process and close debt")
check(run_until(function() return Servers.cancel() == true end) and cancelled_publications == 0,
	"actual native exit and all close callbacks retire discovery without late publication")
check(Servers.apply(held_configured, { model = "obsolete" }, function() return true end) == nil,
	"a held configured menu receipt cannot select after native cancellation")
check(Servers.shutdown() == true, "the stopped discovery owner acknowledges all exact native debt")
os.remove(private_path); os.remove(private_path .. ".tmp"); os.remove(private_path .. ".corrupt")
for _, socket in ipairs(sockets) do close(socket) end
close(server)
uv.run()
local live = 0
uv.walk(function(handle) if uv.is_active(handle) and not uv.is_closing(handle) then live = live + 1 end end)
check(live == 0, "all fixture/native event-loop handles have settled")
if #failures > 0 then io.stderr:write("FAIL native local API authentication: " .. #failures .. " failures\n"); os.exit(1) end
print("PASS native local API authentication: " .. checks .. " checks")
