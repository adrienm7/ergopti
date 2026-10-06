--- tests/support/managed_http_native_ports.lua

--- ==============================================================================
--- MODULE: Managed Http Native Ports
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
 if config.native_curl then package.loaded["adapters.curl_http_client"] = config.native_curl end
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


return { fresh_client = fresh_client }
