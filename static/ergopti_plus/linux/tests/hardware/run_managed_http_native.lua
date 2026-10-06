--- tests/hardware/run_managed_http_native.lua
--- tests/native/network/native_public_http.lua

--- ==============================================================================
--- MODULE: Actual Managed HTTP Public Adapter Control
--- DESCRIPTION:
--- Loads the staged production adapter, shared policy, native GIO helper and
--- real curl engine. Every observed detached process group must retire, and
--- public receipts are emitted without private URLs, bodies or proxy values.
--- ==============================================================================

local driver = assert(os.getenv("ERGOPTI_HTTP_STAGE"))
local shared = driver .. "/../_shared"
local repository = assert(os.getenv("ERGOPTI_HTTP_REPOSITORY"))
package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;"
	.. shared .. "/lua/?.lua;" .. shared .. "/lua/?/init.lua;" .. package.path
local uv = require("luv")
local Json = require("json")
local input = Json.decode(assert(io.stdin:read("*a")))
local spawn = uv.spawn
local pids = {}
local stderr_handles, stderr_tails, native_metric_warnings = {}, {}, 0
local read_start = uv.read_start
uv.read_start = function(pipe, callback)
    if not stderr_handles[pipe] then return read_start(pipe, callback) end
    return read_start(pipe, function(err, chunk)
        if type(chunk) == "string" then
            local combined = (stderr_tails[pipe] or "") .. chunk
            if combined:find("unknown --write-out variable", 1, true) then
                native_metric_warnings = native_metric_warnings + 1
            end
            stderr_tails[pipe] = combined:sub(-512)
        end
        return callback(err, chunk)
    end)
end
uv.spawn = function(...)
	local supplied = { ... }
	local process, pid, err = spawn(...)
	if process then
        pids[#pids + 1] = pid
        local options = supplied[2]
        if type(options) == "table" and type(options.stdio) == "table" and options.stdio[3] ~= nil then stderr_handles[options.stdio[3]] = true end
    end
	return process, pid, err
end
local tokens = {}
local unpack_values = table.unpack or unpack
local function packed(...) return { n = select("#", ...), ... } end
local function observe_owner(module, name)
    local original = module[name]
    module[name] = function(...)
        local values = packed(original(...))
        local token = values[1]
        if type(token) == "table" and type(token.is_settled) == "function" then tokens[#tokens + 1] = token end
        return unpack_values(values, 1, values.n)
    end
end
observe_owner(require("adapters.curl_http_client"), "dispatch_owned")
observe_owner(require("adapters.system_proxy"), "lookup_owned")
observe_owner(require("infra.managed_http_deadline"), "start")
local client = require("adapters.http_client")
local hop_trace = { lookups = 0, curls = 0, physical_retirements = 0, full_urls_match = true }
local prior_curls, per_hop_operation = {}, nil
if input.method == "per_hop" then
    -- Transparent observations only: native callbacks/return values are unchanged.
    local proxy = require("adapters.system_proxy")
    local lookup = proxy.lookup_owned
    proxy.lookup_owned = function(...)
        hop_trace.lookups = hop_trace.lookups + 1
        local matches = select(1, ...) == input.expected_urls[hop_trace.lookups]
        hop_trace.full_urls_match = hop_trace.full_urls_match and matches
        assert(matches, "Full native lookup URI differs from independent literal")
        for _, previous in ipairs(prior_curls) do
            assert(previous.token:is_settled(), "Previous curl physical token must retire before new lookup")
            for _, pid in ipairs(previous.pids) do
                local accepted, _, status = uv.kill(-pid, 0)
                assert(accepted == nil and status == "ESRCH", "Previous actual curl group must be absent before new lookup")
            end
        end
        if #prior_curls > 0 then hop_trace.physical_retirements = hop_trace.physical_retirements + 1 end
        local values = packed(lookup(...))
        if input.cancel_at_second_lookup and hop_trace.lookups == 2 then
            assert(client.cancel("native-public"), "Second actual native lookup cancellation must be accepted")
            assert(per_hop_operation and not per_hop_operation:is_settled(), "Cancelled second lookup retains physical debt")
        end
        return unpack_values(values, 1, values.n)
    end
    local curl = require("adapters.curl_http_client")
    local dispatch = curl.dispatch_owned
    curl.dispatch_owned = function(...)
        hop_trace.curls = hop_trace.curls + 1
        local matches = select(1, ...) == input.expected_urls[hop_trace.curls]
        hop_trace.full_urls_match = hop_trace.full_urls_match and matches
        assert(matches, "Full native curl URI differs from independent literal")
        local before = #pids
        local values = packed(dispatch(...))
        local observed = { token = assert(values[1]), pids = {} }
        for index = before + 1, #pids do observed.pids[#observed.pids + 1] = pids[index] end
        prior_curls[#prior_curls + 1] = observed
        return unpack_values(values, 1, values.n)
    end
end
local function live_native_handles()
    local count = 0
    uv.walk(function() count = count + 1 end)
    return count
end
local native_handles_before = live_native_handles()
local guardian_signal, guardian_timer = uv.new_signal(), uv.new_timer()
local original_parent = uv.os_getppid()
local cleanup_requested = false
local fixture_timers = {}
local function retry_native_cleanup()
    for _, timer in ipairs(fixture_timers) do
        local observed, closing = pcall(uv.is_closing, timer)
        if observed and not closing then pcall(uv.timer_stop, timer); pcall(uv.close, timer) end
    end
    pcall(client.cancel, "native-public")
    for _, token in ipairs(tokens) do
        local cancel = token.request_cancel or token.cancel
        if type(cancel) == "function" then pcall(cancel, token) end
    end
end
uv.signal_start(guardian_signal, "sigusr1", function() cleanup_requested = true end)
uv.timer_start(guardian_timer, 50, 50, function()
    if uv.os_getppid() ~= original_parent then cleanup_requested = true end
    if cleanup_requested then retry_native_cleanup() end
    local retired = true
    for _, token in ipairs(tokens) do
        local called, settled = pcall(token.is_settled, token)
        if not called or settled ~= true then retired = false end
    end
    for _, pid in ipairs(pids) do
        local accepted, _, status = uv.kill(-pid, 0)
        if accepted ~= nil or status ~= "ESRCH" then retired = false end
    end
    if live_native_handles() ~= native_handles_before + 2 then retired = false end
    if retired then
        uv.signal_stop(guardian_signal); uv.close(guardian_signal)
        uv.timer_stop(guardian_timer); uv.close(guardian_timer)
    end
end)
local replies, chunks = {}, {}
local function complete(result) replies[#replies + 1] = result end
local options = { owner = "native-public", timeout_ms = input.timeout_ms or 2500 }
local started = uv.hrtime()
local operation
local argv_observations = 0
local constructed = pcall(function()
if input.method == "per_hop" then
    options.follow_redirects = true
    operation = client.get_owned(input.url, input.headers or {}, options, complete)
    per_hop_operation = operation
elseif input.method == "get_owned" then operation = client.get_owned(input.url, {}, options, complete)
elseif input.method == "post" then
	assert(client.post(input.url, { Authorization = "Bearer private-header-vector" }, "private-body-vector", complete, options))
elseif input.method == "stream" then
	assert(client.postStream(input.url, {}, "private-body-vector", options, function(chunk) chunks[#chunks + 1] = chunk end, complete))
elseif input.method == "download" then
	assert(client.download(input.url, {}, input.destination, options, complete))
else assert(client.get(input.url, {}, options, complete)) end
if input.cancel == true and not input.cancel_at_second_lookup then
	local timer = uv.new_timer()
	fixture_timers[#fixture_timers + 1] = timer
	uv.timer_start(timer, 100, 0, function()
		assert(client.cancel("native-public"), "native cancellation must be accepted")
		assert(operation and not operation:is_settled(), "actual proxy child debt must remain after cancellation")
		uv.timer_stop(timer)
		uv.close(timer)
	end)
end
argv_observations = 0
if input.inspect_argv then
    local timer, attempts = uv.new_timer(), 0
    fixture_timers[#fixture_timers + 1] = timer
    uv.timer_start(timer, 50, 50, function()
        attempts = attempts + 1
        for _, pid in ipairs(pids) do
            local image = uv.fs_readlink("/proc/" .. tostring(pid) .. "/exe")
            if type(image) == "string" and image:match("/curl$") then
                local fd = uv.fs_open("/proc/" .. tostring(pid) .. "/cmdline", "r", 0)
                if fd then
                    local bytes, read_error = uv.fs_read(fd, 8192, 0)
                    local closed, close_error = uv.fs_close(fd)
                    assert(closed and close_error == nil, "owned argv observation descriptor must close")
                    assert(type(bytes) == "string" and read_error == nil, "actual native argv receipt is required")
                    if bytes:find("--config", 1, true) then
                        for _, marker in ipairs({ "private-token", "private-user", "private-proxy-vector", "private-body-vector", "private-header-vector" }) do
                            assert(not bytes:find(marker, 1, true), "private fixed marker escaped actual native argv")
                        end
                        argv_observations = argv_observations + 1
                    end
                end
            end
        end
        if argv_observations > 0 or attempts >= 30 then uv.timer_stop(timer); uv.close(timer) end
    end)
end
end)
if not constructed then cleanup_requested = true; retry_native_cleanup() end
local native_run_failed = false
while true do
    local called = pcall(uv.run)
    if called then break end
    native_run_failed, cleanup_requested = true, true
    retry_native_cleanup()
end
assert(not native_run_failed, "Native fixture callback raised; exact token cleanup completed")
assert(constructed, "Native fixture construction raised; owned cleanup completed")
if input.inspect_argv then assert(argv_observations > 0, "actual native curl argv observation is unavailable") end
assert(live_native_handles() == native_handles_before, "every native handle must retire, including inactive boolean-request handles")
assert(not client.isActive("native-public"), "public logical activity must finish")
for _, pid in ipairs(pids) do
	local accepted, _, code = uv.kill(-pid, 0)
	assert(accepted == nil and code == "ESRCH", "every actual managed child group must be absent")
end
if operation then assert(operation:is_settled(), "owned public operation must physically settle") end
if input.cancel then assert(#replies == 0, "cancelled actual operation cannot publish a stale result")
else assert(#replies == 1, "actual public completion must publish once") end
local result = replies[1]
local elapsed_ms = (uv.hrtime() - started) / 1000000
io.stdout:write("ERGOPTI_PUBLIC_HTTP_RESULT:", Json.encode({
	completion_count = #replies, chunk_count = #chunks, process_count = #pids,
	ok = result and result.ok, status = result and result.status,
	failure_receipt = result and result.failure_receipt,
	error = result and result.error, elapsed_ms = elapsed_ms, proxy_used = result and result.proxy_used, argv_observations = argv_observations, native_metric_warnings = native_metric_warnings,
	selection_receipt = result and result.proxy_selection_receipt,
	hop_probe = input.method == "per_hop" and {
        lookups = hop_trace.lookups, curls = hop_trace.curls,
        physical_retirements = hop_trace.physical_retirements, full_urls_match = hop_trace.full_urls_match,
        body_matches = result and result.body == input.expected_body,
        private_receipt_absent = result == nil or result.redirect_receipt == nil,
    } or nil,
}), "\n")
