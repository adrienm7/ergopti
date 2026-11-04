--- tests/unit/adapters/network/test_tcp_probe.lua

--- ==============================================================================
--- MODULE: Test TCP Reachability Probe
--- DESCRIPTION:
--- Drives adapters/tcp_probe.lua over real libuv sockets on loopback: a
--- listening port answers reachable, a closed one refused, and each child
--- settles only after its native handles are closed. The relay address parser
--- reads what the shared proxy policy admits.
--- ==============================================================================

local helpers = require("tests.helpers")
local luv = require("luv")
local Probe = require("adapters.tcp_probe")

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
	}
	for _, case in ipairs(cases) do
		local host, port = Probe.relay_address(case[1])
		helpers.assert_eq(host, case[2])
		helpers.assert_eq(port, case[3])
	end
	helpers.assert_eq(Probe.relay_address("http://proxy.example"), nil)
	helpers.assert_eq(Probe.relay_address("proxy.example:3128"), nil)
end)
