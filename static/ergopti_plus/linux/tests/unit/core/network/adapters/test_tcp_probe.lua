--- tests/unit/core/network/adapters/test_tcp_probe.lua

--- ==============================================================================
--- MODULE: Test TCP Reachability Probe
--- DESCRIPTION:
--- Drives core/network/adapters/tcp_probe.lua over real libuv sockets on loopback: a
--- listening port answers reachable, a closed one refused, and each child
--- settles only after its native handles are closed. The relay address parser
--- reads what the shared proxy policy admits.
--- ==============================================================================

local helpers = require("tests.helpers")
local luv = require("luv")
local Probe = require("core.network.adapters.tcp_probe")

local function it(name, body) helpers.it(name .. " (tcp-probe)", body) end

--- Runs the loop until `done()` or a two-second guard.
local function run_until(done)
	local deadline = luv.now() + 2000
	while not done() and luv.now() < deadline do luv.run("once") end
end

--- A loopback listener on an ephemeral port.
local function listener()
	local server = assert(luv.new_tcp())
	assert(server:bind("127.0.0.1", 0))
	assert(server:listen(4, function()
		local client = luv.new_tcp()
		server:accept(client)
		client:close()
	end))
	return server, server:getsockname().port
end

it("a listening loopback port is reachable and the child settles once its handles close", function()
	local server, port = listener()
	local answers = {}
	local child = assert(Probe.probe("127.0.0.1", port, 1000, function(reachable, reason)
		answers[#answers + 1] = { reachable, reason }
	end, luv))
	local settled = false
	child.on_settled(function() settled = true end)
	run_until(function() return settled end)
	server:close()
	run_until(function() return server:is_closing() end)
	helpers.assert_eq(#answers, 1)
	helpers.assert_eq(answers[1][1], true)
	helpers.assert_eq(child.is_settled(), true)
end)

it("rejects a NUL-bearing host before libuv can truncate it", function()
	local server, port = listener()
	local child, reason = Probe.probe("127.0.0.1\0different.example", port, 1000, function() end, luv)
	if child then run_until(function() return child.is_settled() end) end
	server:close()
	run_until(function() return server:is_closing() end)
	helpers.assert_nil(child, "the native resolver must not see a truncated host")
	helpers.assert_eq(reason, "tcp probe arguments are invalid")
end)

it("tries the next resolved address when the first connection is refused", function()
	local server, port = listener()
	local backend = setmetatable({
		getaddrinfo = function(host, service, hints, callback)
			return luv.getaddrinfo(host, service, hints, function(err)
				callback(err, { { addr = "127.0.0.2", port = port }, { addr = "127.0.0.1", port = port } })
			end)
		end,
	}, { __index = luv })
	local answers = {}
	local child = assert(Probe.probe("localhost", port, 1000, function(reachable, reason)
		answers[#answers + 1] = { reachable, reason }
	end, backend))
	run_until(function() return child.is_settled() end)
	server:close()
	run_until(function() return server:is_closing() end)
	helpers.assert_eq(#answers, 1)
	helpers.assert_eq(answers[1][1], true, "a later reachable address must keep the proxy usable")
end)

it("probes an IPv4-mapped IPv6 relay accepted by proxy policy", function()
	local server, port = listener()
	local relay = "http://[::ffff:127.0.0.1]:" .. port
	local policy = assert(require("core.network.engine.proxy_policy").load())
	local choices = assert(policy.selection({ ok = true, proxies = { relay, "direct://" } }))
	helpers.assert_eq(choices[1].proxy, relay)
	local host, parsed_port = Probe.relay_address(relay)
	local reachable
	local child = host and Probe.probe(host, parsed_port, 1000, function(value) reachable = value end, luv)
	if child then run_until(function() return child.is_settled() end) end
	server:close()
	run_until(function() return server:is_closing() end)
	helpers.assert_true(child ~= nil, "the mapped relay must be admitted")
	helpers.assert_eq(reachable, true)
end)

it("probes percent-encoded proxy host bytes the same way as curl", function()
	local server, port = listener()
	local relay = "http://%31%32%37.0.0.1:" .. port
	local policy = assert(require("core.network.engine.proxy_policy").load())
	local choices = assert(policy.selection({ ok = true, proxies = { relay, "direct://" } }))
	helpers.assert_eq(choices[1].proxy, relay)
	local host, parsed_port = Probe.relay_address(relay)
	local reachable
	local child = host and Probe.probe(host, parsed_port, 1000, function(value) reachable = value end, luv)
	if child then run_until(function() return child.is_settled() end) end
	server:close()
	run_until(function() return server:is_closing() end)
	helpers.assert_eq(host, "127.0.0.1")
	helpers.assert_eq(reachable, true)
end)

for _, failure in ipairs({ "throw", "return", "inspect", "inspect_nil" }) do
it("retains a refused native close until cancellation retries it: " .. failure, function()
	local resolve, connect, delivered = nil, nil, false
	local attempts, fail = 0, true
	local function handle(is_timer)
		return {
			is_closing = function()
				if is_timer and fail and failure == "inspect" then error("controlled inspection refusal") end
				if is_timer and fail and failure == "inspect_nil" then return nil end
				return false
			end,
			close = function(_, callback)
				if is_timer then
					attempts = attempts + 1
					if fail and failure == "throw" then error("controlled close refusal") end
					if fail and failure == "return" then return false, "controlled close refusal" end
				end
				callback()
			end,
			connect = function(_, _, _, callback) connect = callback; return true end,
		}
	end
	local backend = {
		new_timer = function() return handle(true) end, new_tcp = function() return handle(false) end,
		update_time = function() end, timer_start = function() return true end,
		getaddrinfo = function(_, _, _, callback) resolve = callback; return {} end,
	}
	local child = assert(Probe.probe("example", 80, 1000, function() delivered = true end, backend))
	resolve(nil, { { addr = "127.0.0.1", port = 80 } })
	helpers.assert_true(pcall(connect, nil), "native close refusal cannot escape the event loop")
	helpers.assert_eq(child.is_settled(), false)
	helpers.assert_eq(delivered, false)
	fail = false
	helpers.assert_true(child.cancel())
	helpers.assert_true(child.is_settled())
	helpers.assert_eq(attempts, (failure == "inspect" or failure == "inspect_nil") and 1 or 2)
	helpers.assert_eq(delivered, false, "cancellation revokes the unanswered probe")
end)
end

it("does not publish during a reentrant close callback", function()
	local resolve, connect, closed = nil, nil, 0
	local function handle()
		return {
			is_closing = function() return false end,
			close = function(_, callback) closed = closed + 1; callback() end,
			connect = function(_, _, _, callback) connect = callback; return true end,
		}
	end
	local backend = {
		new_timer = handle, new_tcp = handle,
		update_time = function() end,
		timer_start = function() return true end,
		getaddrinfo = function(_, _, _, callback) resolve = callback; return {} end,
	}
	local observed
	local child = assert(Probe.probe("example", 80, 1000, function() observed = closed end, backend))
	resolve(nil, { { addr = "127.0.0.1", port = 80 } })
	connect(nil)
	helpers.assert_true(child.is_settled())
	helpers.assert_eq(observed, 2, "both exact handles must finish before publication")
end)

it("preserves the interface scope discarded by libuv DNS results", function()
	local resolve, destination
	local function handle()
		return {
			is_closing = function() return false end,
			close = function(_, callback) callback() end,
			connect = function(_, address, _, callback) destination = address; callback(nil); return true end,
		}
	end
	local backend = {
		new_timer = handle, new_tcp = handle, update_time = function() end,
		timer_start = function() return true end,
		getaddrinfo = function(_, _, _, callback) resolve = callback; return {} end,
	}
	local child = assert(Probe.probe("fe80::1%eth0", 80, 1000, function() end, backend))
	resolve(nil, { { addr = "fe80::1", port = 80, family = "inet6" } })
	helpers.assert_eq(destination, "fe80::1%eth0")
	helpers.assert_true(child.is_settled())
end)

it("settles a real link-local relay whose interface scope does not exist", function()
	local answer
	local child = assert(Probe.probe("fe80::1%4294967295", 80, 1000, function(reachable, reason)
		answer = { reachable, reason }
	end, luv))
	run_until(function() return child.is_settled() end)
	helpers.assert_true(child.is_settled(), "the invalid native scope must not strand the probe")
	helpers.assert_eq(answer[1], false)
	helpers.assert_true(answer[2] == "resolve" or answer[2] == "connect" or answer[2] == "timeout", tostring(answer[2]))
end)

it("publishes the answer only after its native timer and socket retire", function()
	local server, port = listener()
	local owned = {}
	local backend = setmetatable({
		new_timer = function() local handle = assert(luv.new_timer()); owned[handle] = true; return handle end,
		new_tcp = function() local handle = assert(luv.new_tcp()); owned[handle] = true; return handle end,
	}, { __index = luv })
	local observed = nil
	local child = assert(Probe.probe("127.0.0.1", port, 1000, function(reachable)
		local count = 0
		luv.walk(function(handle) if owned[handle] then count = count + 1 end end)
		observed = { reachable = reachable, remaining = count }
	end, backend))
	run_until(function() return child.is_settled() end)
	server:close()
	luv.run("nowait")
	helpers.assert_true(observed and observed.reachable)
	helpers.assert_eq(observed.remaining, 0, "a successor must not replace an unsettled native child")
end)

it("a closed loopback port answers unreachable with the connect reason", function()
	local server, port = listener()
	server:close()
	run_until(function() return server:is_closing() end)
	luv.run("nowait")
	local answer
	local child = assert(Probe.probe("127.0.0.1", port, 1000, function(reachable, reason) answer = { reachable, reason } end, luv))
	run_until(function() return child.is_settled() end)
	helpers.assert_eq(answer[1], false)
	helpers.assert_eq(answer[2], "connect")
end)

it("isolates throwing callbacks and delivers all settlement listeners", function()
	local server, port = listener()
	local notified = 0
	local child = assert(Probe.probe("127.0.0.1", port, 1000, function()
		error("controlled completion failure")
	end, luv))
	child.on_settled(function() error("controlled settlement failure") end)
	child.on_settled(function() notified = notified + 1 end)
	local ok = pcall(run_until, function() return child.is_settled() end)
	server:close()
	luv.run("nowait")
	helpers.assert_true(ok, "a callback exception must not escape into the native loop")
	helpers.assert_true(child.is_settled())
	helpers.assert_eq(notified, 1, "one listener must not suppress another")
	local late = 0
	local immediate = pcall(child.on_settled, function() late = late + 1; error("controlled late failure") end)
	helpers.assert_true(immediate, "late listeners use the same exception isolation")
	helpers.assert_eq(late, 1, "a settled child invokes late listeners immediately")
end)

it("retires real sockets when both a callback and its diagnostic throw", function()
	local logger = require("core.logger.engine.shim")
	local old_error = logger.error
	local server, port = listener()
	local child = assert(Probe.probe("127.0.0.1", port, 1000, function()
		error("controlled callback failure")
	end, luv))
	local notified = 0
	child.on_settled(function() notified = notified + 1 end)
	logger.error = function() error("controlled diagnostic failure") end
	local tested, reason = pcall(run_until, function() return child.is_settled() end)
	logger.error = old_error
	server:close()
	luv.run("nowait")
	helpers.assert_true(tested, tostring(reason))
	helpers.assert_true(child.is_settled())
	helpers.assert_eq(notified, 1)
end)

it("continues socket retirement when a refused timer close and its diagnostic throw", function()
	local logger = require("core.logger.engine.shim")
	local old_error = logger.error
	local resolve, connect, allow_close, socket_closed = nil, nil, false, false
	local function handle(is_timer)
		return {
			is_closing = function() return false end,
			close = function(_, done)
				if is_timer and not allow_close then return false, "controlled refusal" end
				if not is_timer then socket_closed = true end
				done(); return true
			end,
			connect = function(_, _, _, callback) connect = callback; return true end,
		}
	end
	local backend = {
		new_timer = function() return handle(true) end, new_tcp = function() return handle(false) end,
		update_time = function() end, timer_start = function() return true end,
		getaddrinfo = function(_, _, _, callback) resolve = callback; return {} end,
	}
	local child = assert(Probe.probe("example", 80, 1000, function() end, backend))
	resolve(nil, { { addr = "127.0.0.1", port = 80 } })
	logger.error = function() error("controlled diagnostic failure") end
	local called, reason = pcall(connect, nil)
	logger.error = old_error
	helpers.assert_true(called, tostring(reason))
	helpers.assert_true(socket_closed, "a timer diagnostic must not prevent socket close")
	helpers.assert_eq(child.is_settled(), false)
	allow_close = true
	child.cancel()
	helpers.assert_true(child.is_settled())
end)

it("a cancel answers nothing and still settles the child", function()
	local server, port = listener()
	local called = false
	local child = assert(Probe.probe("127.0.0.1", port, 1000, function() called = true end, luv))
	helpers.assert_eq(child.cancel(), true)
	run_until(function() return child.is_settled() end)
	server:close()
	run_until(function() return server:is_closing() end)
	helpers.assert_eq(called, false)
	helpers.assert_eq(child.is_settled(), true)
end)

it("waits for a late DNS callback after timeout without starting a stale connection", function()
	local expire, resolve, cancelled, sockets = nil, nil, 0, 0
	local timer = {
		is_closing = function() return false end,
		close = function(_, done) done() end,
	}
	local request = {}
	local backend = {
		new_timer = function() return timer end,
		update_time = function() end,
		timer_start = function(_, _, _, callback) expire = callback; return true end,
		getaddrinfo = function(_, _, _, callback) resolve = callback; return request end,
		cancel = function(value) helpers.assert_eq(value, request); cancelled = cancelled + 1; return true end,
		new_tcp = function() sockets = sockets + 1; error("stale DNS must not connect") end,
	}
	local answers = {}
	local child = assert(Probe.probe("relay.invalid", 80, 1000, function(ok, reason)
		answers[#answers + 1] = { ok, reason }
	end, backend))
	expire()
	helpers.assert_eq(cancelled, 1)
	helpers.assert_eq(child.is_settled(), false, "resolver still owns its callback")
	helpers.assert_eq(#answers, 0)
	resolve(nil, { { addr = "127.0.0.1", port = 80 } })
	helpers.assert_true(child.is_settled())
	helpers.assert_eq(answers, { { false, "timeout" } })
	helpers.assert_eq(sockets, 0)
end)

it("returns the DNS refusal after its timer has closed", function()
	local resolve, closed, sockets = nil, false, 0
	local backend = {
		new_timer = function() return {
			is_closing = function() return false end,
			close = function(_, done) closed = true; done() end,
		} end,
		update_time = function() end,
		timer_start = function() return true end,
		getaddrinfo = function(_, _, _, callback) resolve = callback; return {} end,
		new_tcp = function() sockets = sockets + 1; error("failed DNS must not connect") end,
	}
	local answer
	local child = assert(Probe.probe("relay.invalid", 80, 1000, function(ok, reason)
		answer = { ok, reason, closed }
	end, backend))
	resolve("EAI_NONAME", nil)
	helpers.assert_true(child.is_settled())
	helpers.assert_eq(answer, { false, "resolve", true })
	helpers.assert_eq(sockets, 0)
end)

it("refuses invalid arguments without starting a handle", function()
	for _, args in ipairs({ { "", 80 }, { "h", 0 }, { "h", 70000 }, { "h", 1.5 } }) do
		local child, err = Probe.probe(args[1], args[2], 1000, function() end, luv)
		helpers.assert_eq(child, nil)
		helpers.assert_type(err, "string")
	end
end)

it("reads the relay address of every relay form the policy admits", function()
	local cases = {
		{ "http://proxy.corp.example:3128", "proxy.corp.example", 3128 },
		{ "socks5h://user:secret@gate.example:1080", "gate.example", 1080 },
		{ "http://[::1]:8080", "::1", 8080 },
		{ "http://[::ffff:127.0.0.1]:8080", "::ffff:127.0.0.1", 8080 },
		{ "http://proxy.example", "proxy.example", 1080 },
		{ "https://proxy.example", "proxy.example", 443 },
		{ "HTTPS://proxy.example", "proxy.example", 443 },
		{ "http://proxy.example:3128/path?name=value#fragment", "proxy.example", 3128 },
		{ "http://[fe80::1%25eth0]:8080", "fe80::1%eth0", 8080 },
		{ "socks5h://user:secret@[::1]", "::1", 1080 },
	}
	for _, case in ipairs(cases) do
		local policy = assert(require("core.network.engine.proxy_policy").load())
		local choices = assert(policy.selection({ ok = true, proxies = { case[1], "direct://" } }))
		helpers.assert_eq(choices[1].proxy, case[1])
		local host, port = Probe.relay_address(case[1])
		helpers.assert_eq(host, case[2])
		helpers.assert_eq(port, case[3])
	end
	helpers.assert_eq(Probe.relay_address("http://"), nil)
	helpers.assert_eq(Probe.relay_address("http://proxy%00.example:80"), nil)
	helpers.assert_eq(Probe.relay_address("proxy.example:3128"), nil)
end)
