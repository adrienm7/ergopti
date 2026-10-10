--- tests/unit/modules/llm/test_managed_ollama_daemon_protocol.lua

--- ==============================================================================
--- MODULE: Managed foreground daemon caller protocol regressions
--- DESCRIPTION:
--- Checks the existing builder's opt-in argv and exact-task fixed frame joins.
--- Controlled observations never qualify a native READY or enable production.
--- ==============================================================================

local helpers = require("tests.helpers")
local Receiver = require("adapters.managed_ollama_daemon")
local next_nonce = 0

local function owned_task()
	next_nonce = next_nonce + 1
	local task = { settled = false }
	function task.isSettled() return task.settled end
	return task, string.format("%032x", next_nonce)
end

local function frame(nonce, role)
	return "ERGOPTI_MANAGED_DAEMON_V1 " .. nonce .. " " .. role .. "\n"
end

local function with_builder(callback)
	helpers.with_stub_scope({ "modules.llm.ollama_server_command", "modules.llm.ollama_binary",
		"modules.llm.managed_native_python", "adapters.file_system" }, function()
		local builder = helpers.load_with_stubs("modules.llm.ollama_server_command")
		local binary = require("modules.llm.ollama_binary")
		local python = require("modules.llm.managed_native_python")
		local files = require("adapters.file_system")
		local old_candidate, old_python, old_exists = binary.native_candidate, python.resolve, files.exists
		local path = "/fixture/managed/ollama"
		binary.native_candidate = function() return path, { admission = 17, idle = 23, retirement = 11 } end
		python.resolve = function() return "/fixture/native/python3" end
		files.exists = function(candidate) return candidate:match("/modules/llm/managed_ollama_serve%.py$") ~= nil end
		local outcome = table.pack(xpcall(function() callback(builder, binary, path) end, debug.traceback))
		binary.native_candidate, python.resolve, files.exists = old_candidate, old_python, old_exists
		if not outcome[1] then error(outcome[2], 0) end
	end)
end

helpers.describe("Managed daemon foreground command", function()
	helpers.it("(daemon-bound-command) binds the existing native command to one opt-in caller nonce", function()
		with_builder(function(builder, binary, path)
			local nonce = string.rep("a", 32)
			local legacy, legacy_error = builder.build(path, "/tmp/fixture.log", 45678, binary.SOURCE_NATIVE_MANAGED)
			helpers.assert_eq(legacy_error, nil)
			helpers.assert_true(type(legacy) == "string")
			helpers.assert_eq(legacy:find("--caller-nonce", 1, true), nil)
			helpers.assert_eq(legacy:find("--acquire-readiness", 1, true), nil)
			helpers.assert_eq(legacy:find("--owned-stdin", 1, true), nil)
			local bound, err = builder.build(path, "/tmp/fixture.log", 45678, binary.SOURCE_NATIVE_MANAGED, nonce)
			helpers.assert_eq(err, nil)
			helpers.assert_eq(bound, legacy .. " --caller-nonce '" .. nonce .. "' --acquire-readiness --owned-stdin")
			helpers.assert_true(bound:find("--timeout 17 --idle-timeout 23 --retirement-timeout 11", 1, true) ~= nil)
			helpers.assert_true(bound:match("^exec ") ~= nil)
			helpers.assert_eq(bound:find("nohup", 1, true), nil)
		end)
	end)

	for _, case in ipairs({ { false }, { "" }, { string.rep("a", 31) }, { string.rep("a", 33) },
		{ string.rep("A", 32) }, { string.rep("g", 32) }, { string.rep("a", 31) .. "\n" } }) do
		helpers.it("(daemon-invalid-nonce) refuses malformed existing-builder caller input " .. tostring(case[1]), function()
			with_builder(function(builder, binary, path)
				local command, reason = builder.build(path, "/tmp/fixture.log", 45678, binary.SOURCE_NATIVE_MANAGED, case[1])
				helpers.assert_eq(command, nil)
				helpers.assert_eq(reason, "managed daemon caller nonce is invalid")
			end)
		end)
	end

	for _, kind in ipairs({ "app", "user_app", "homebrew", "managed", "path", "unknown" }) do
		helpers.it("(daemon-foreign-source) refuses nonce authority for source " .. kind, function()
			with_builder(function(builder, _, path)
				local command, reason = builder.build(path, "/tmp/fixture.log", 45678, kind, string.rep("a", 32))
				helpers.assert_eq(command, nil)
				helpers.assert_eq(reason, "managed daemon caller requires its native source owner")
			end)
		end)
	end
end)

helpers.describe("Managed daemon original-task lifecycle receiver", function()
	helpers.it("(daemon-complete-join) requires complete frames plus original physical settlement", function()
		local task, nonce = owned_task()
		local receiver = assert(Receiver.new(task, nonce))
		local active = frame(nonce, "ACTIVE")
		helpers.assert_true(receiver.feed(task, active:sub(1, 9)))
		helpers.assert_eq(receiver.ready_observed(task), false)
		helpers.assert_true(receiver.feed(task, active:sub(10) .. frame(nonce, "READY")))
		helpers.assert_true(receiver.ready_observed(task))
		helpers.assert_true(receiver.feed(task, frame(nonce, "RETIRED 0")))
		helpers.assert_eq(receiver.ready_observed(task), false)
		local retired, state = receiver.finish(task, 0)
		helpers.assert_eq(retired, false)
		helpers.assert_eq(state, "pending")
		task.settled = true
		helpers.assert_eq(receiver.finish(task, 0), true)
	end)

	helpers.it("(daemon-guard-refusal) receives RETIRED 78 without manufacturing ACTIVE or READY", function()
		local task, nonce = owned_task()
		local receiver = assert(Receiver.new(task, nonce))
		helpers.assert_true(receiver.feed(task, frame(nonce, "RETIRED 78")))
		helpers.assert_eq(receiver.ready_observed(task), false)
		helpers.assert_eq(receiver.finish(task, 78), false)
		task.settled = true
		helpers.assert_eq(receiver.finish(task, 78), true)
	end)

	helpers.it("(daemon-exit-is-not-retirement) retains custody when exit has no RETIRED frame", function()
		local task, nonce = owned_task()
		local receiver = assert(Receiver.new(task, nonce))
		receiver.feed(task, frame(nonce, "ACTIVE") .. frame(nonce, "READY"))
		task.settled = true
		helpers.assert_eq(receiver.finish(task, 0), false)
	end)

	helpers.it("(daemon-foreign-task) rejects a borrowed task despite the exact same nonce", function()
		local task, nonce = owned_task()
		local receiver = assert(Receiver.new(task, nonce))
		local foreign = { isSettled = function() return true end }
		helpers.assert_eq(receiver.feed(foreign, frame(nonce, "ACTIVE")), false)
		helpers.assert_eq(receiver.finish(foreign, 0), false)
		helpers.assert_true(receiver.feed(task, frame(nonce, "RETIRED 78")))
		task.settled = true
		helpers.assert_eq(receiver.finish(task, 78), true)
	end)

	helpers.it("(daemon-status-join) refuses a callback different from the native retirement status", function()
		local task, nonce = owned_task()
		local receiver = assert(Receiver.new(task, nonce))
		receiver.feed(task, frame(nonce, "RETIRED 78"))
		task.settled = true
		helpers.assert_eq(receiver.finish(task, 0), false)
		helpers.assert_eq(receiver.finish(task, 78), false, "a contradictory completion remains uncertain")
	end)

	helpers.it("(daemon-ready-freshness) never reports READY after original task settlement", function()
		local task, nonce = owned_task()
		local receiver = assert(Receiver.new(task, nonce))
		receiver.feed(task, frame(nonce, "ACTIVE") .. frame(nonce, "READY"))
		helpers.assert_true(receiver.ready_observed(task))
		task.settled = true
		helpers.assert_eq(receiver.ready_observed(task), false)
	end)

	for _, vector in ipairs({
		{ name = "ready-before-active", roles = { "READY" } },
		{ name = "duplicate-active", roles = { "ACTIVE", "ACTIVE" } },
		{ name = "duplicate-ready", roles = { "ACTIVE", "READY", "READY" } },
		{ name = "success-without-ready", roles = { "ACTIVE", "RETIRED 0" } },
		{ name = "foreign-pre-ready-status", roles = { "RETIRED 1" } },
		{ name = "leading-zero-status", roles = { "RETIRED 078" } },
		{ name = "status-out-of-domain", roles = { "RETIRED 256" } },
		{ name = "trailing-status-field", roles = { "RETIRED 78 secret" } },
		{ name = "frame-after-retirement", roles = { "RETIRED 78", "ACTIVE" } },
	}) do
		helpers.it("(daemon-malformed-frame) refuses " .. vector.name, function()
			local task, nonce = owned_task()
			local receiver = assert(Receiver.new(task, nonce))
			local accepted
			for _, role in ipairs(vector.roles) do accepted = receiver.feed(task, frame(nonce, role)) end
			helpers.assert_eq(accepted, false)
			task.settled = true
			helpers.assert_eq(receiver.finish(task, 78), false)
		end)
	end

	helpers.it("(daemon-incomplete-frame) refuses a truncated terminal frame at physical exit", function()
		local task, nonce = owned_task()
		local receiver = assert(Receiver.new(task, nonce))
		receiver.feed(task, frame(nonce, "RETIRED 78"):sub(1, -2))
		task.settled = true
		helpers.assert_eq(receiver.finish(task, 78), false)
	end)

	helpers.it("(daemon-foreign-nonce) retains debt after a foreign nonce on the original pipe", function()
		local task, nonce = owned_task()
		local receiver = assert(Receiver.new(task, nonce))
		helpers.assert_eq(receiver.feed(task, frame(string.rep("f", 32), "RETIRED 78")), false)
		task.settled = true
		helpers.assert_eq(receiver.finish(task, 78), false)
	end)

	helpers.it("(daemon-output-bound) rejects excessive or non-protocol stdout without raw diagnostics", function()
		for _, chunk in ipairs({ string.rep("x", 513), "\000", "\r\n", "\255" }) do
			local task, nonce = owned_task()
			local receiver = assert(Receiver.new(task, nonce))
			local accepted, reason = receiver.feed(task, chunk)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(reason, "protocol")
		end
	end)

	helpers.it("(daemon-retained-nonce) cannot reissue a live nonce when a caller loses its receiver", function()
		local task, nonce = owned_task()
		local function prepare_and_abandon()
			helpers.assert_not_nil(Receiver.new(task, nonce))
		end
		prepare_and_abandon()
		collectgarbage("collect")
		helpers.assert_eq(task.isSettled(), false)
		local foreign = { isSettled = function() return false end }
		helpers.assert_eq(Receiver.new(foreign, nonce), nil,
			"GC is not an acknowledgment from the original task or its native namespace")
	end)

	helpers.it("(daemon-duplicate-binding) refuses another receiver for an original task or live nonce", function()
		local task, nonce = owned_task()
		local receiver = assert(Receiver.new(task, nonce))
		helpers.assert_eq(Receiver.new(task, string.rep("b", 32)), nil)
		local foreign = { isSettled = function() return false end }
		helpers.assert_eq(Receiver.new(foreign, nonce), nil)
		receiver.feed(task, frame(nonce, "RETIRED 78"))
		task.settled = true
		helpers.assert_eq(receiver.finish(task, 78), true)
	end)
end)

helpers.describe("Managed daemon shared policy ports", function()
	helpers.it("(daemon-shared-ports) captures explicit transport ports without Mac dependencies", function()
		local Shared = require("core.llm.managed_ollama_daemon_receipt")
		local task, nonce = owned_task()
		task.isSettled = nil
		local ports = {
			max_protocol_bytes = 88,
			is_settled = function(original)
				helpers.assert_true(rawequal(original, task))
				return task.settled
			end,
		}
		local receiver = assert(Shared.new(task, nonce, ports))
		ports.is_settled = function() return true end
		helpers.assert_true(receiver.feed(task, frame(nonce, "RETIRED 78")))
		helpers.assert_eq(receiver.finish(task, 78), false)
		task.settled = true
		helpers.assert_eq(receiver.finish(task, 78), true)

		local bounded, bounded_nonce = owned_task()
		local budget = { max_protocol_bytes = 88, is_settled = function(original) return original.settled end }
		local bounded_receiver = assert(Shared.new(bounded, bounded_nonce, budget))
		budget.max_protocol_bytes = 512
		helpers.assert_eq(bounded_receiver.feed(bounded, string.rep("x", 89)), false)
		bounded.settled = true
		helpers.assert_eq(bounded_receiver.finish(bounded, 78), false)

		for _, invalid in ipairs({ {}, { max_protocol_bytes = 0, is_settled = function() return false end },
			{ max_protocol_bytes = math.huge, is_settled = function() return false end },
			{ max_protocol_bytes = 88, is_settled = function() return false end, extra = true } }) do
			local other, other_nonce = owned_task()
			local refused, reason = Shared.new(other, other_nonce, invalid)
			helpers.assert_eq(refused, nil)
			helpers.assert_eq(reason, "state")
		end
	end)

	helpers.it("(daemon-original-predicate) never substitutes a later task getter for physical settlement", function()
		local task, nonce = owned_task()
		local receiver = assert(Receiver.new(task, nonce))
		helpers.assert_true(receiver.feed(task, frame(nonce, "RETIRED 78")))
		task.isSettled = function() return true end
		local retired, state = receiver.finish(task, 78)
		helpers.assert_eq(retired, false)
		helpers.assert_eq(state, "pending")
		task.settled = true
		helpers.assert_eq(receiver.finish(task, 78), true)
	end)
end)

helpers.describe("Managed daemon constructor publication", function()
	helpers.it("(daemon-constructor-reentry) preserves the first receiver acquired inside a predicate", function()
		local Shared = require("core.llm.managed_ollama_daemon_receipt")
		local task, nonce = owned_task()
		local inner
		local outer, reason = Shared.new(task, nonce, {
			max_protocol_bytes = 88,
			is_settled = function(original)
				helpers.assert_true(rawequal(original, task))
				inner = assert(Shared.new(task, nonce, {
					max_protocol_bytes = 88,
					is_settled = function(owned) return owned.settled end,
				}))
				return false
			end,
		})
		helpers.assert_eq(outer, nil)
		helpers.assert_eq(reason, "protocol")
		helpers.assert_not_nil(inner)
		local foreign = { settled = false }
		helpers.assert_eq(Shared.new(foreign, nonce, {
			max_protocol_bytes = 88,
			is_settled = function(owned) return owned.settled end,
		}), nil)
		helpers.assert_true(inner.feed(task, frame(nonce, "RETIRED 78")))
		helpers.assert_eq(inner.finish(task, 78), false)
		task.settled = true
		helpers.assert_eq(inner.finish(task, 78), true)
		local successor = assert(Shared.new(foreign, nonce, {
			max_protocol_bytes = 88,
			is_settled = function(owned) return owned.settled end,
		}))
		helpers.assert_true(successor.feed(foreign, frame(nonce, "RETIRED 78")))
		foreign.settled = true
		helpers.assert_eq(successor.finish(foreign, 78), true)
	end)
end)

helpers.describe("Managed daemon exact preactivation rollback", function()
	helpers.it("(daemon-prepared-rollback) releases only the same settled never-started task", function()
		local task, nonce = owned_task()
		function task.wasStartAttempted() return false end
		local receiver = assert(Receiver.new(task, nonce))
		helpers.assert_eq(receiver.rollback_prepared({}), false)
		helpers.assert_eq(receiver.rollback_prepared(task), false)
		task.settled = true
		local released, state = receiver.rollback_prepared(task)
		helpers.assert_eq(released, true)
		helpers.assert_eq(state, "prepared")
		helpers.assert_eq(receiver.feed(task, frame(nonce, "RETIRED 78")), false)
		local foreign = { isSettled = function() return false end }
		helpers.assert_not_nil(Receiver.new(foreign, nonce))
	end)

	helpers.it("(daemon-attempted-rollback) retains debt for unknown, refused or attempted native start", function()
		for _, check in ipairs({ function() return true end, function() return nil end,
			function() return "false" end, function() error("controlled unknown attempt") end }) do
			local task, nonce = owned_task()
			task.wasStartAttempted = check
			local receiver = assert(Receiver.new(task, nonce))
			task.settled = true
			local released, state = receiver.rollback_prepared(task)
			helpers.assert_eq(released, false)
			helpers.assert_eq(state, "pending")
			local foreign = { isSettled = function() return false end }
			helpers.assert_eq(Receiver.new(foreign, nonce), nil)
		end
		local task, nonce = owned_task()
		local receiver = assert(Receiver.new(task, nonce))
		task.settled = true
		helpers.assert_eq(receiver.rollback_prepared(task), false, "missing start provenance never acknowledges rollback")
	end)

	helpers.it("(daemon-observed-rollback) keeps frame custody and rechecks attempt after settlement lookup", function()
		local Shared = require("core.llm.managed_ollama_daemon_receipt")
		local task, nonce = owned_task()
		function task.wasStartAttempted() return false end
		local receiver = assert(Receiver.new(task, nonce))
		helpers.assert_true(receiver.feed(task, frame(nonce, "RETIRED 78")))
		task.settled = true
		helpers.assert_eq(receiver.rollback_prepared(task), false)
		helpers.assert_eq(receiver.finish(task, 78), true)

		local other, other_nonce = owned_task()
		local attempted = false
		local current = assert(Shared.new(other, other_nonce, {
			max_protocol_bytes = 88,
			was_start_attempted = function() return attempted end,
			is_settled = function(original)
				if original.settled then attempted = true end
				return original.settled
			end,
		}))
		other.settled = true
		helpers.assert_eq(current.rollback_prepared(other), false)
	end)

	helpers.it("(daemon-native-start-latch) distinguishes prepared cancellation from a false native start", function()
		local original_new = hs.task.new
		local handles = {}
		local native = {}
		local outcome = table.pack(xpcall(function()
			helpers.with_stub_scope({ "adapters.shell_runner" }, function()
				local controlled_new = function(_, done)
					local environment = { HOME = "/fixture/home" }
					local task = { starts = 0, complete = done }
					function task:environment() return environment end
					function task:setEnvironment(value) environment = value; return self end
					function task:isRunning() return false end
					function task:start() self.starts = self.starts + 1; return false end
					function task:closeInput() return self end
					native[#native + 1] = task
					return task
				end
				local runner = helpers.load_with_stubs("adapters.shell_runner", { task = { new = controlled_new } })
				local prepared = runner.spawn("/fixture/managed-serve", {}, nil, nil, nil, true, true)
				handles[#handles + 1] = prepared
				local _, nonce = owned_task()
				local receipt = assert(Receiver.new(prepared, nonce))
				helpers.assert_eq(prepared.wasStartAttempted(), false)
				helpers.assert_eq(prepared.terminate(), true)
				helpers.assert_eq(prepared.isSettled(), true)
				helpers.assert_eq(receipt.rollback_prepared(prepared), true)
				helpers.assert_eq(native[1].starts, 0)

				local attempted = runner.spawn("/fixture/managed-serve", {}, nil, nil, nil, true, true)
				handles[#handles + 1] = attempted
				local _, attempted_nonce = owned_task()
				local attempted_receipt = assert(Receiver.new(attempted, attempted_nonce))
				helpers.assert_eq(attempted.wasStartAttempted(), false)
				helpers.assert_eq(attempted.start(), false)
				helpers.assert_eq(attempted.wasStartAttempted(), true)
				helpers.assert_eq(attempted.isSettled(), false, "owned false-start keeps the exact task until physical completion")
				helpers.assert_eq(attempted_receipt.rollback_prepared(attempted), false)
				helpers.assert_eq(native[2].starts, 1)
				helpers.assert_true(attempted_receipt.feed(attempted, frame(attempted_nonce, "RETIRED 78")))
				native[2].complete(78, "", "")
				helpers.assert_eq(attempted.isSettled(), true)
				helpers.assert_eq(attempted_receipt.finish(attempted, 78), true)
			end)
		end, debug.traceback))
		for _, handle in ipairs(handles) do pcall(handle.terminate) end
		hs.task.new = original_new
		if not outcome[1] then error(outcome[2], 0) end
	end)
end)
