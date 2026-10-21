--- tests/meta/architecture/test_native_lease_budget_parity.lua

--- ==============================================================================
--- MODULE: Native Lease Budget Parity Guard
--- DESCRIPTION:
--- Keeps the Karabiner lease deadlines ordered across the Swift worker and the
--- Lua controller. Issue #95 had three inversions: the outer's private command
--- deadline left 0.25 s over the CLI timeout, so the inner's own answers lost
--- the race; Lua's READY deadline was shorter than the worker's ARM plus one
--- write; and a 4.8 s Hammerspoon main-thread stall fenced a healthy lease.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Spawn, socket round trip and scheduling headroom one CLI child needs beyond
-- its reap polls and SIGTERM grace before the outer deadline may expire.
local MIN_CHILD_SETTLEMENT_HEADROOM_SEC = 0.5
-- Longest Hammerspoon main-thread stall measured in the issue #95 log (a lazily
-- built browser window filter, 4759 ms), rounded up.
local MEASURED_HOST_STALL_SEC = 5.0
-- Pipe and main-thread latency every Lua ACK deadline keeps over the worker.
local MIN_LUA_LATENCY_MARGIN_SEC = 2.0
-- One start of the launcher executable on the loaded Mac of issue #99: its
-- detached revokers and guardian probes ran 2.0 to 2.2 s, and the probe's own
-- 2.0 s deadline expired twice.
local MEASURED_LAUNCHER_LAUNCH_SEC = 2.0
local MICROSECONDS_PER_SECOND = 1000000





-- ===================================
-- ===================================
-- ======= 1/ Constant Readers =======
-- ===================================
-- ===================================

--- Reads one native launcher source; the Lua scan helpers cover only Lua.
--- @param relative string Path under the macOS driver root.
--- @return string source
local function read_source(relative)
	local path = helpers.driver_root() .. "/" .. relative
	local file, open_err = io.open(path, "r")
	helpers.assert_not_nil(file, "lease source must be readable: " .. tostring(open_err))
	local source = file:read("*a")
	file:close()
	return source
end

--- Collects `NAME = expression` declarations, joining continuation lines that
--- start with `+` and dropping trailing comments.
--- @param source string Source text.
--- @param declaration string Lua pattern capturing the constant name.
--- @param comment string Plain comment marker.
--- @return table expressions Name to expression text.
local function collect_expressions(source, declaration, comment)
	local expressions = {}
	local current = nil
	for line in (source .. "\n"):gmatch("([^\n]*)\n") do
		local marker = line:find(comment, 1, true)
		local code = marker and line:sub(1, marker - 1) or line
		local name, expression = code:match(declaration)
		if name then
			expressions[name] = expression
			current = name
		elseif current and code:match("^%s*%+") then
			expressions[current] = expressions[current] .. " " .. code
		else
			current = nil
		end
	end
	return expressions
end

--- Evaluates a sum of numeric literals and named constants.
--- @param expressions table Name to expression text.
--- @param name string Constant to evaluate.
--- @param seen table|nil Names already on the evaluation stack.
--- @return number value
local function evaluate(expressions, name, seen)
	seen = seen or {}
	local expression = expressions[name]
	helpers.assert_not_nil(expression, "lease budget constant must exist: " .. name)
	helpers.assert_true(not seen[name], "lease budget constant must not be cyclic: " .. name)
	seen[name] = true
	local total = 0
	for term in expression:gmatch("[^+]+") do
		local token = term:match("^%s*(.-)%s*$")
		local literal = tonumber((token:gsub("_", "")))
		if literal then
			total = total + literal
		else
			helpers.assert_true(token:match("^[%a_][%w_]*$") ~= nil,
				"lease budget term must be a literal or a constant: " .. token)
			total = total + evaluate(expressions, token, seen)
		end
	end
	seen[name] = nil
	return total
end

local SWIFT_DECLARATION = "^%s*[%a ]-let%s+([%a_][%w_]*)%s*[:%w_ ]-=%s*(.-)%s*$"
local LUA_DECLARATION = "^local%s+([%u_][%u%d_]*)%s*=%s*(.-)%s*$"

local function swift_constants()
	local worker = collect_expressions(
		read_source("launcher/Sources/ErgoptiPlus/RemapLeaseWorker.swift"), SWIFT_DECLARATION, "//")
	local guardian = collect_expressions(
		read_source("launcher/Sources/ErgoptiPlus/RemapLeaseGuardian.swift"), SWIFT_DECLARATION, "//")
	for name, expression in pairs(guardian) do worker[name] = worker[name] or expression end
	return worker
end

local function lua_constants()
	local source, err = helpers.read_driver_unit("local WORKER_COMMAND_BUDGET_SEC =")
	helpers.assert_not_nil(source, "the lease controller must mirror the worker budgets: " .. tostring(err))
	return collect_expressions(source, LUA_DECLARATION, "--")
end





-- ===================================
-- ===================================
-- ======= 2/ Budget Ordering ========
-- ===================================
-- ===================================

helpers.describe("native Karabiner lease budgets stay ordered", function()
	helpers.it("(lease-command-settlement) the outer deadline outlasts one CLI child's own timeout path", function()
		local swift = swift_constants()
		local cli = evaluate(swift, "kCLITimeoutSeconds")
		local command = evaluate(swift, "kPrivateCommandAckTimeoutSeconds")
		local child_poll = evaluate(swift, "kChildPollMicroseconds") / MICROSECONDS_PER_SECOND
		local termination_grace = evaluate(swift, "kProcessTerminationGraceSeconds")
		local required = child_poll + termination_grace + MIN_CHILD_SETTLEMENT_HEADROOM_SEC
		helpers.assert_true(command - cli >= required, string.format(
			"the private command budget (%.2f s) must exceed the CLI timeout (%.2f s) by %.2f s, "
				.. "or a timed-out heartbeat loses the lease instead of answering PING_FAILED",
			command, cli, required))
	end)

	helpers.it("(lease-host-stall) inner silence tolerates a measured main-thread stall", function()
		local swift = swift_constants()
		local command = evaluate(swift, "kPrivateCommandAckTimeoutSeconds")
		local slack = evaluate(swift, "kLeaseInnerSilenceSlackSeconds")
		helpers.assert_true(slack >= command + MEASURED_HOST_STALL_SEC, string.format(
			"the inner silence slack (%.2f s) must cover one command (%.2f s) plus a %.1f s "
				.. "Hammerspoon stall, or the stall exits the worker with 73",
			slack, command, MEASURED_HOST_STALL_SEC))
	end)

	helpers.it("(lease-lua-mirrors) Lua mirrors the worker's budgets exactly", function()
		local swift = swift_constants()
		local lua = lua_constants()
		helpers.assert_eq(evaluate(lua, "WORKER_COMMAND_BUDGET_SEC"),
			evaluate(swift, "kPrivateCommandAckTimeoutSeconds"),
			"WORKER_COMMAND_BUDGET_SEC mirrors kPrivateCommandAckTimeoutSeconds")
		helpers.assert_eq(evaluate(lua, "WORKER_GUARDIAN_ARM_BUDGET_SEC"),
			evaluate(swift, "kGuardianArmTimeoutSeconds"),
			"WORKER_GUARDIAN_ARM_BUDGET_SEC mirrors kGuardianArmTimeoutSeconds")
	end)

	helpers.it("(lease-ready-budget) Lua waits for READY past the worker's ARM plus one write", function()
		local swift = swift_constants()
		local lua = lua_constants()
		local arm = evaluate(swift, "kGuardianArmTimeoutSeconds")
		local command = evaluate(swift, "kPrivateCommandAckTimeoutSeconds")
		local ready = evaluate(lua, "READY_ACK_TIMEOUT_SEC")
		local ack = evaluate(lua, "COMMAND_ACK_TIMEOUT_SEC")
		helpers.assert_true(ready >= arm + command + MIN_LUA_LATENCY_MARGIN_SEC, string.format(
			"READY_ACK_TIMEOUT_SEC (%.2f s) must cover ARM (%.2f s), one write (%.2f s) and %.1f s of latency",
			ready, arm, command, MIN_LUA_LATENCY_MARGIN_SEC))
		helpers.assert_true(ack >= command + MIN_LUA_LATENCY_MARGIN_SEC, string.format(
			"COMMAND_ACK_TIMEOUT_SEC (%.2f s) must cover one write (%.2f s) and %.1f s of latency",
			ack, command, MIN_LUA_LATENCY_MARGIN_SEC))
	end)

	-- The worker's budgets start once it runs; READY also waits for the outer
	-- and its suspended inner to launch. Issue #99 activated leases in 3.4 to
	-- 6.0 s on a loaded Mac and failed every slower one at 7.5 s, each failure
	-- redeploying karabiner.json and starting another lease.
	helpers.it("(lease-ready-launch) Lua's READY deadline also covers launching the outer and its inner", function()
		local swift = swift_constants()
		local lua = lua_constants()
		local arm = evaluate(swift, "kGuardianArmTimeoutSeconds")
		local command = evaluate(swift, "kPrivateCommandAckTimeoutSeconds")
		local ready = evaluate(lua, "READY_ACK_TIMEOUT_SEC")
		local required = 2 * MEASURED_LAUNCHER_LAUNCH_SEC + arm + command + MIN_LUA_LATENCY_MARGIN_SEC
		helpers.assert_true(ready >= required, string.format(
			"READY_ACK_TIMEOUT_SEC (%.2f s) must cover two launcher launches (%.1f s each), ARM (%.2f s), "
				.. "one write (%.2f s) and %.1f s of latency",
			ready, MEASURED_LAUNCHER_LAUNCH_SEC, arm, command, MIN_LUA_LATENCY_MARGIN_SEC))
	end)
end)
