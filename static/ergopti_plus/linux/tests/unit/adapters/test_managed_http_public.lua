--- tests/unit/adapters/test_managed_http_public.lua

--- ==============================================================================
--- MODULE: Test Managed Http Public
--- DESCRIPTION:
--- Preserves independent managed-network controls and actual production imports.
--- Source registration alone does not qualify native or installed behavior.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Creates the minimum libuv process/pipe surface used by HttpClient.
--- @param config table|nil
--- @return table fake, table state
local function fake_luv(config)
	local options = config or {}
	local state = { kills = {}, handles = {}, requests = {}, closes = {}, deadlines = {}, time = 0 }
	local fake = {}

	local function handle(kind)
		if options.allocation_failure_at == #state.handles + 1 then error("allocation refused") end
		local value = { kind = kind, closing = false }
		state.handles[#state.handles + 1] = value
		return value
	end

	function fake.update_time() end
	function fake.exepath() return "/independent/runtime/luajit" end
	function fake.shutdown(_, callback) callback(nil); return true end
	function fake.new_pipe() return handle("pipe") end
	function fake.new_timer()
		state.timer = handle("timer")
		return state.timer
	end
	function fake.timer_start(timer, timeout_ms, repeat_ms, callback)
		if options.timer_failure then return nil, "timer refused" end
		timer.timeout_ms = timeout_ms
		timer.repeat_ms = repeat_ms
		timer.callback = callback
		return true
	end
	function fake.timer_stop(timer) timer.stopped = true; return true end
	function fake.read_start(pipe, callback) pipe.read_callback = callback; return true end
	function fake.write(pipe, data, callback)
		pipe.written = (pipe.written or "") .. data
		state.config = pipe.written
		if callback then callback(nil) end
		return true
	end
	function fake.read_stop(pipe) pipe.read_stopped = true; return true end
	function fake.is_closing(value) return value.closing end
	function fake.close(value, callback)
		if options.close_failure and not state.allow_closes then return nil, "close refused" end
		value.closing = true
		if callback then
			state.closes[#state.closes + 1] = { handle = value, callback = callback }
			if not options.defer_close then callback() end
		end
	end
	function state.ack_closes()
		for _, receipt in ipairs(state.closes) do
			if not receipt.acknowledged then
				receipt.acknowledged = true
				receipt.callback()
			end
		end
	end
	function fake.kill(pid, signal)
		state.kills[#state.kills + 1] = { pid = pid, signal = signal }
		local captured
		for _, request in ipairs(state.requests) do
			if pid == -request.pid then captured = request; break end
		end
		if not captured then return nil, "EPERM: foreign fake group", "EPERM" end
		-- Only an explicit exact-group fixture ACK proves absence. Neither a
		-- successful signal nor the leader's exit callback establishes it.
		if captured.group_absent or options.kill_missing then return nil, "ESRCH: no such process", "ESRCH" end
		if options.kill_throw and not state.allow_kills then error("independent signal refusal") end
		if options.kill_failure and not state.allow_kills then return nil, "EPERM: operation not permitted", "EPERM" end
		return true
	end
	function fake.spawn(command, options, callback)
		if config and config.spawn_failure then return nil, "EACCES", "permission denied" end
		local pid = 4320 + #state.requests + 1
		state.command = command
		state.options = options
		state.exit_callback = callback
		state.process = handle("process")
		state.requests[#state.requests + 1] = {
			options = options,
			exit_callback = callback,
			process = state.process,
			pid = pid,
		}
		return state.process, pid
	end

	function state.stdout(chunk) state.options.stdio[2].read_callback(nil, chunk) end
	function state.stderr(chunk) state.options.stdio[3].read_callback(nil, chunk) end
	--- Supplies an independent native absence receipt for one captured group.
	function state.ack_group_absent(index)
		local request = assert(state.requests[index], "unknown fake request group")
		request.group_absent = true
	end
	function state.exit(code, signal) state.exit_callback(code or 0, signal or 0) end
	function state.complete(code)
		state.stdout(nil)
		state.stderr(nil)
		-- Full completion supplies a separate absence ACK; bare exit stays leader-only.
		if not options.hold_group_absence then state.ack_group_absent(#state.requests) end
		state.exit(code or 0)
	end
	function state.complete_request(index, stdout_text, code)
		local request = assert(state.requests[index], "unknown fake request")
		if stdout_text ~= nil then request.options.stdio[2].read_callback(nil, stdout_text) end
		request.options.stdio[2].read_callback(nil, nil)
		request.options.stdio[3].read_callback(nil, nil)
		if not options.hold_group_absence then state.ack_group_absent(index) end
		request.exit_callback(code or 0, 0)
	end
	return fake, state
end


local Paths = require("infra.paths")
local driver_root = helpers.driver_root()
local Json = require("json")

--- Provides independent timer events and close acknowledgements to real owners.
--- @param state table
--- @param config table
--- @return function
local function deadline_port(state, config)
 return function(deadline, callback)
  local item = { deadline = deadline, callback = callback, settled = false, listeners = {}, closes = 0, index = #state.deadlines + 1 }
  local token = { started = config.refuse_deadline_arm_index ~= item.index }
  function token:is_settled() return item.settled end
  function token:on_settled(listener)
   if item.settled then listener() else item.listeners[#item.listeners + 1] = listener end
   return true
  end
  function item.ack()
   if item.settled then return end
   item.settled = true
   for _, listener in ipairs(item.listeners) do listener() end
  end
  function token:cancel()
   item.closes = item.closes + 1
   if state.refuse_deadline_close or state.refuse_deadline_index == item.index then return false end
   item.closing = true
   if not config.defer_deadline_close and config.defer_deadline_index ~= item.index then item.ack() end
   return true
  end
  function item.fire()
   if item.fired or item.closing then return end
   item.fired = true
   callback()
   token:cancel()
  end
  item.token = token
  state.deadlines[#state.deadlines + 1] = item
  return token
 end
end

--- Loads the actual public wrapper, core and shared policy with native ports.
--- @param config table|nil
--- @return table client, table state
local function fresh_client(config)
 config = config or {}
 local fake, state = fake_luv(config)
 local names = { "luv", "adapters.http_client", "adapters.curl_http_client", "adapters.system_proxy", "infra.proxy_policy", "infra.managed_http", "infra.monotonic", "infra.managed_http_deadline", "infra.paths" }
 local saved = {}
 for _, name in ipairs(names) do saved[name] = package.loaded[name] end
 local ok, client = pcall(function()
  for _, name in ipairs(names) do package.loaded[name] = nil end
 package.loaded.luv = fake
 package.loaded["infra.monotonic"] = { now_ms = function() return state.time end }
 local policy_module = dofile(assert(Paths.shared("lua/network/proxy_policy.lua")))
 local file = assert(io.open(assert(Paths.shared("modules/network/proxy_policy.json")), "rb"))
 local data = Json.decode(file:read("*a")); file:close()
 local policy = assert(policy_module.new(data))
 package.loaded["infra.proxy_policy"] = { load = function() return policy end, environment = function() return {} end }
 package.loaded["infra.paths"] = { driver_root = function() return driver_root end,
  shared_root = function() return assert(Paths.shared_root()) end,
  shared = function(path) return assert(Paths.shared(path)) end }
 package.loaded["infra.managed_http_deadline"] = { start = deadline_port(state, config) }
 return dofile(driver_root .. "/adapters/http_client.lua")
 end)
 for _, name in ipairs(names) do package.loaded[name] = saved[name] end
 if not ok then error(client, 0) end
 function state.fire_deadlines()
  for _, item in ipairs(state.deadlines) do
   if not item.settled and state.time >= item.deadline then item.fire() end
  end
 end
 return client, state
end

helpers.describe("managed public API: original owned settlement assertions", function()
	helpers.it("owned GET cancellation retains debt and blocks both APIs until physical settlement", function()
		local client, state = fresh_client({ defer_close = true })
		local terminals, rejected = 0, nil
		local operation = client.get_owned("http://127.0.0.1:9000/v1/models", {},
			{ owner = "local-api" }, function() terminals = terminals + 1 end)
		helpers.assert_eq(operation:cancel(), false, "SIGTERM acceptance is not a physical exit receipt")
		helpers.assert_eq(client.isActive("local-api"), false, "the legacy logical activity ABI is unchanged")
		helpers.assert_eq(client.get("http://127.0.0.1:9000/v1/models", {}, { owner = "local-api" },
			function(value) rejected = value end), false)
		helpers.assert_eq(rejected.error, "previous request cleanup pending")
		local successor = client.get_owned("http://127.0.0.1:9000/v1/models", {},
			{ owner = "local-api" }, function() end)
		helpers.assert_eq(successor.started, false)
		helpers.assert_true(successor:is_settled(), "a refused successor acquires no native resource")
		helpers.assert_eq(#state.requests, 1)
		state.ack_closes()
		helpers.assert_eq(operation:is_settled(), false)
		state.exit(0)
		helpers.assert_eq(operation:is_settled(), false)
		state.ack_group_absent(1)
		state.ack_closes()
		helpers.assert_true(operation:cancel())
		helpers.assert_eq(terminals, 0, "late terminal events cannot publish after cancellation")
		local fresh = client.get_owned("http://127.0.0.1:9000/v1/models", {},
			{ owner = "local-api" }, function() end)
		helpers.assert_true(fresh.started)
		state.complete_request(2, '[]\nERGOPTI_HTTP_STATUS:200\n')
		state.ack_closes()
		helpers.assert_true(fresh:is_settled())
		state.exit(0)
		helpers.assert_eq(terminals, 0)
	end)

	helpers.it("owned GET fences callbacks on refused termination and keeps independent requests", function()
		local client, state = fresh_client({ kill_failure = true, defer_close = true })
		local terminals, independent = 0, nil
		local operation = client.get_owned("http://127.0.0.1:9000/v1/models", {},
			{ owner = "local-api" }, function() terminals = terminals + 1 end)
		client.get("http://127.0.0.1:9001/v1/models", {}, { owner = "prediction" },
			function(value) independent = value end)
		helpers.assert_eq(operation:cancel(), false)
		helpers.assert_true(client.isActive("local-api"))
		helpers.assert_true(client.isActive("prediction"))
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n')
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(terminals, 0, "cancel intent fences delivery even if the signal refuses")
		state.complete_request(2, '[]\nERGOPTI_HTTP_STATUS:200\n')
		helpers.assert_true(independent.ok)
	end)

end)

helpers.describe("managed public API: supported native resolution failure", function()
 for _, receipt in ipairs({
  { ok = false, error = "proxy-lookup-failed", backend = "GProxyResolverGnome", native_error_code = 42 },
  { ok = false, error = "proxy-native-failed" },
  { ok = false, error = "proxy-supervision-failed" },
  { ok = false, error = "proxy-child-failed" },
 }) do
  local native_receipt = receipt
  helpers.it("refuses " .. receipt.error .. " without fallback curl acquisition", function()
   local client, state = fresh_client({ defer_close = true })
   local results = {}
   local operation = client.get_owned("https://corporate.invalid/private", {}, { owner = "lookup", timeout_ms = 1000 }, function(result) results[#results + 1] = result end)
   helpers.assert_true(operation.started)
   state.complete_request(1, Json.encode(native_receipt))
   state.ack_closes()
   helpers.assert_eq(#state.requests, 1, "supported resolution failure cannot admit a curl child")
   helpers.assert_true(operation:is_settled())
   helpers.assert_eq(#results, 1)
   helpers.assert_eq(results[1].error, native_receipt.error)
   helpers.assert_eq(results[1].status, 0)
   helpers.assert_eq(results[1].body, "")
   helpers.assert_eq(results[1].failure_receipt.failure_provenance, "unknown")
  end)
 end
 for _, native_receipt in ipairs({ { ok = false, error = "proxy-native-unavailable" }, { ok = false, error = "proxy-backend-unavailable", backend = "GDummyProxyResolver" } }) do
  local unavailable = native_receipt
  helpers.it("retains explicitly acknowledged " .. unavailable.error .. " ordinary routing", function()
   local client, state = fresh_client({ defer_close = true })
   local result
   local operation = client.get_owned("https://corporate.invalid/private", {}, { owner = "lookup" }, function(value) result = value end)
   state.complete_request(1, Json.encode(unavailable))
   state.ack_closes()
   helpers.assert_eq(#state.requests, 2)
   state.complete_request(2, "ordinary\nERGOPTI_HTTP_STATUS:200\n")
   state.ack_closes()
   helpers.assert_true(operation:is_settled() and result.ok)
   helpers.assert_eq(result.proxy_selection_receipt.proxy_resolution_status, "unavailable")
  end)
 end
end)

helpers.describe("managed public API: independent absolute deadline events", function()
 helpers.it("expires an accepted waiter while predecessor close acknowledgements are withheld", function()
  local client, state = fresh_client({ defer_close = true })
  local predecessor = client.get("http://127.0.0.1:9000/models", {}, { owner = "waiter", timeout_ms = 5000 }, function() end)
  helpers.assert_true(predecessor)
  local results = {}
  helpers.assert_true(client.get("http://127.0.0.1:9000/models", {}, { owner = "waiter", timeout_ms = 1000 }, function(result) results[#results + 1] = result end))
  state.time = 1001
  state.fire_deadlines()
  helpers.assert_eq(#results, 1)
  helpers.assert_eq(results[1].error, "timeout")
  helpers.assert_eq(#state.requests, 1, "expired waiter cannot acquire a new child")
  helpers.assert_true(not state.requests[1].process.closing, "predecessor has not received process exit")
  state.complete_request(1, "late\nERGOPTI_HTTP_STATUS:200\n")
  state.ack_closes()
  helpers.assert_eq(#state.requests, 1)
  helpers.assert_eq(#results, 1)
 end)
 helpers.it("publishes proxy-stage logical timeout before child exit or close acknowledgements", function()
  local client, state = fresh_client({ defer_close = true })
  local results = {}
  helpers.assert_true(client.get("https://corporate.invalid/private", {}, { owner = "proxy-timeout", timeout_ms = 1000 }, function(result) results[#results + 1] = result end))
  state.time = 1001
  -- Native resolver supervision fires independently of the composite timer.
  state.timer.callback()
  helpers.assert_eq(#results, 1)
  helpers.assert_eq(results[1].error, "timeout")
  helpers.assert_eq(#state.requests, 1)
  helpers.assert_true(not state.requests[1].process.closing)
  helpers.assert_true(not client.isActive("proxy-timeout"))
  state.complete_request(1, Json.encode({ ok = true, proxies = { "direct://" }, backend = "GProxyResolverGnome", acknowledgement = "native-selection", failure_provenance = "unavailable" }))
  state.ack_closes()
  helpers.assert_eq(#results, 1)
  helpers.assert_eq(#state.requests, 1)
 end)
 for _, owned_api in ipairs({ false, true }) do
  local owned = owned_api
  helpers.it((owned and "owned" or "boolean") .. " refuses successful receipt delivered after absolute deadline before timer dispatch", function()
   local client, state = fresh_client({ defer_close = true })
   local results = {}
   local options = { owner = "late-success", timeout_ms = 1000 }
   local operation
   if owned then operation = client.get_owned("http://127.0.0.1:9000/models", {}, options, function(result) results[#results + 1] = result end)
   else helpers.assert_true(client.get("http://127.0.0.1:9000/models", {}, options, function(result) results[#results + 1] = result end)) end
   state.time = 1001
   state.complete_request(1, "success\nERGOPTI_HTTP_STATUS:200\n")
   if owned then helpers.assert_eq(#results, 0); helpers.assert_true(not operation:is_settled())
   else helpers.assert_eq(#results, 1); helpers.assert_eq(results[1].error, "timeout") end
   state.ack_closes()
   helpers.assert_eq(#results, 1)
   helpers.assert_true(not results[1].ok and results[1].error == "timeout")
   if owned then helpers.assert_true(operation:is_settled()) end
  end)
 end
 helpers.it("retains owned completion behind exact deadline close acknowledgement", function()
  local client, state = fresh_client({ defer_close = true, defer_deadline_close = true })
  local results = {}
  local operation = client.get_owned("http://127.0.0.1:9000/models", {}, { owner = "timer-debt", timeout_ms = 1000 }, function(result) results[#results + 1] = result end)
  state.complete_request(1, "success\nERGOPTI_HTTP_STATUS:200\n")
  state.ack_closes()
  helpers.assert_eq(#results, 0)
  helpers.assert_true(not operation:is_settled())
  state.time = 1001
  state.deadlines[1].ack()
  helpers.assert_eq(#results, 1)
  helpers.assert_true(not results[1].ok and results[1].error == "timeout")
  helpers.assert_true(operation:is_settled())
 end)
end)

helpers.describe("managed public API: independent exact group absence receipts", function()
	for _, mode in ipairs({ "EPERM", "throw" }) do
		local refusal_mode = mode
		helpers.it("leader exit and close ACK cannot hide a retained group after " .. mode, function()
			local client, state = fresh_client({ defer_close = true, hold_group_absence = true,
				kill_failure = refusal_mode == "EPERM", kill_throw = refusal_mode == "throw" })
			local callbacks = 0
			local operation = client.get_owned("http://127.0.0.1:9000/models", {},
				{ owner = "held-group" }, function() callbacks = callbacks + 1 end)
			helpers.assert_eq(operation:cancel(), false)
			state.complete_request(1, "held\nERGOPTI_HTTP_STATUS:200\n")
			state.ack_closes()
			helpers.assert_true(not operation:is_settled(), "leader exit and stream ACKs do not prove group absence")
			local refused = client.get_owned("http://127.0.0.1:9000/models", {},
				{ owner = "held-group" }, function() error("retained group successor published") end)
			helpers.assert_true(refused:is_settled() and not refused.started)
			helpers.assert_eq(#state.requests, 1)
			helpers.assert_eq(callbacks, 0)
			state.ack_group_absent(1)
			operation:cancel()
			helpers.assert_true(not operation:is_settled(), "the original native timer still needs its own close ACK")
			state.ack_closes()
			helpers.assert_true(operation:is_settled())
			helpers.assert_eq(callbacks, 0)
			for _, receipt in ipairs(state.kills) do
				helpers.assert_eq(receipt.pid, -state.requests[1].pid, "only the captured exact group is probed or signalled")
			end
		end)
	end
end)
return helpers
