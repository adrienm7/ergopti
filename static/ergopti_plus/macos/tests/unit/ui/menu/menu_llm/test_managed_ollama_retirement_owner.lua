--- tests/unit/ui/menu/menu_llm/test_managed_ollama_retirement_owner.lua

--- ==============================================================================
--- MODULE: Managed Ollama Exact Retirement Owner Regression
--- DESCRIPTION:
--- Exercises the original model manager with its native task boundary and the
--- real private receipt adapter. Literal injected daemon proofs are receiving
--- vectors, never native source, socket, HMAC, or model acceptance evidence.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.ollama_pull_fixture").with_fixture
local Json = require("json")
local NONCE = "12345678-abcd-4321-abcd-123456789abc"

local function proof(status, changes)
	local value = { version = 1, nonce = NONCE, state = "retired", worker_status = status,
		source_admitted = true, listener_bound = true, request_reaped = true,
		daemon_operation_retired = true, operation = string.rep("a", 32),
		source_commit = string.rep("b", 40), binary_sha256 = string.rep("c", 64), asset_sha256 = string.rep("d", 64) }
	for name, change in pairs(changes or {}) do value[name] = change end
	return Json.encode(value)
end

--- Uses the real adapter and manager around controlled native task/file ports.
--- @param options table Native start/cancel receiving behavior.
--- @param callback function Exact-owner assertions.
local function with_managed(options, callback)
	local saved_adapter = package.loaded["adapters.managed_ollama_pull"]
	local saved_fs = package.loaded["adapters.file_system"]
	package.loaded["adapters.managed_ollama_pull"] = nil
	local raw, removed, handle, adapter, cleanup_hook, reentry_result = "", false, nil, nil, nil, nil
	package.loaded["adapters.file_system"] = {
		exists = function() return true end,
		read_with_status = function(path)
			if path:find("proxy_policy.json", 1, true) then return '{"max_proxy_bytes":4096}', "ok" end
			if path:find("network-retry.sh", 1, true) then
				return "CURL_CONNECT_TIMEOUT_SEC=30\nCURL_STALL_SEC=60\nCURL_MAX_TIME_SEC=600\n", "ok"
			end
			return raw, "ok"
		end,
		create_secure_temp_file = function() return "/private/controlled-receipt" end,
		classify_no_follow = function() return { mode = "file", dev = 1, ino = 2, size = #raw }, "ok" end,
		remove_if_unchanged = function(_, expected, _, fence)
			if fence() and expected.content == raw then
				if cleanup_hook then local hook = cleanup_hook; cleanup_hook = nil; hook() end
				removed = true
				return true
			end
			return false
		end,
	}
	options.network_env = { opaque_prelude = function()
		_G.hs.host = { uuid = function() return NONCE end }
		adapter = require("adapters.managed_ollama_pull")
		local ready
		handle, ready = adapter.prepare("owned/model:tiny", 11434, "/native/python")
		helpers.assert_true(ready)
		local lifecycle = package.loaded["adapters.task_lifecycle"]
		local native = lifecycle.native
		lifecycle.native = function(...)
			local task = native(...)
			if task and task.label == "Ollama model pull" then
				function task:setInput(input) self.input = input; return self end
				helpers.assert_true(handle.bind_input(task))
				if options.receipt_during_start then
					local start_task = task.start
					function task:start()
						raw = options.receipt_during_start
						return start_task(self)
					end
					cleanup_hook = function() reentry_result = task.on_done(options.complete_during_start) end
				end
			end
			return task
		end
		return ""
	end }
	local ok, error_value = xpcall(function()
		with_fixture(options, function(f)
			f.receipt = function(value) raw = value end
			f.cleanup_hook = function(value) cleanup_hook = value end
			f.reentry_result = function() return reentry_result end
			f.removed = function() return removed end
			f.adapter = function() return adapter end
			f.handle = function() return handle end
			callback(f)
		end)
	end, debug.traceback)
	package.loaded["adapters.managed_ollama_pull"] = saved_adapter
	package.loaded["adapters.file_system"] = saved_fs
	if not ok then error(error_value, 0) end
end

local function start(f)
	local terminals = { success = 0, cancel = 0 }
	local accepted = f.manager.pull_model("owned/model:tiny", "owned/model:tiny",
		function() terminals.success = terminals.success + 1; return true end,
		function() terminals.cancel = terminals.cancel + 1; return true end,
		{ is_current = function() return true end })
	return accepted, terminals
end

helpers.describe("Managed Ollama exact daemon retirement owner", function()
	helpers.it("retains the original slot after callback and a pending daemon ACK", function()
		with_managed({}, function(f)
			helpers.assert_true(start(f))
			local task = f.pulls[1]
			f.receipt(proof(78, { state = "pending", daemon_operation_retired = false }))
			task.running = false
			task.on_done(78)
			helpers.assert_eq(f.active_tasks.ollama_pull, task)
			helpers.assert_eq(f.removed(), false)
			helpers.assert_nil(f.http_callback())
			helpers.assert_eq(start(f), false)
			helpers.assert_eq(#f.pulls, 1)
		end)
	end)

	helpers.it("refuses callback zero without a same-session retirement receipt", function()
		with_managed({}, function(f)
			local accepted, terminals = start(f)
			helpers.assert_true(accepted)
			local task = f.pulls[1]
			task.on_done(0)
			helpers.assert_eq(f.active_tasks.ollama_pull, task)
			helpers.assert_nil(f.http_callback())
			helpers.assert_eq(terminals.cancel, 1)
			helpers.assert_eq(terminals.success, 0)
		end)
	end)

	helpers.it("retains attempted start refusal despite proven-not-running", function()
		with_managed({ start_result = false }, function(f)
			local accepted, terminals = start(f)
			helpers.assert_eq(accepted, false)
			local task = f.pulls[1]
			helpers.assert_eq(task:isRunning(), false)
			helpers.assert_eq(f.active_tasks.ollama_pull, task)
			helpers.assert_eq(f.removed(), false)
			helpers.assert_eq(terminals.cancel, 1)
		end)
	end)

	helpers.it("retains reentrant callback from a refused start without daemon proof", function()
		with_managed({ start_result = false, complete_during_start = 0 }, function(f)
			local accepted, terminals = start(f)
			helpers.assert_eq(accepted, false)
			local task = f.pulls[1]
			helpers.assert_eq(f.active_tasks.ollama_pull, task)
			helpers.assert_nil(f.http_callback())
			helpers.assert_eq(terminals.cancel, 1)
			helpers.assert_eq(terminals.success, 0)
		end)
	end)

	helpers.it("cancellation and repeated callbacks retain debt until exact ACK", function()
		with_managed({}, function(f)
			local accepted, terminals = start(f)
			helpers.assert_true(accepted)
			local task = f.pulls[1]
			helpers.assert_true(f.progress.on_cancel())
			task.on_done(130)
			task.on_done(130)
			helpers.assert_eq(f.active_tasks.ollama_pull, task)
			helpers.assert_eq(terminals.cancel, 1)
			f.receipt(proof(130))
			task.on_done(0)
			helpers.assert_eq(f.active_tasks.ollama_pull, task)
			task.on_done(130)
			helpers.assert_nil(f.active_tasks.ollama_pull)
			helpers.assert_true(f.removed())
			helpers.assert_eq(terminals.cancel, 1)
			helpers.assert_eq(terminals.success, 0)
		end)
	end)

	helpers.it("requires the exact nonce and exact native callback status", function()
		with_managed({}, function(f)
			helpers.assert_true(start(f))
			local task = f.pulls[1]
			f.receipt(proof(0, { nonce = "ffffffff-abcd-4321-abcd-123456789abc" }))
			task.on_done(0)
			helpers.assert_eq(f.active_tasks.ollama_pull, task)
			f.receipt(proof(130))
			task.on_done(0)
			helpers.assert_eq(f.active_tasks.ollama_pull, task)
			helpers.assert_eq(f.removed(), false)
		end)
	end)

	helpers.it("releases successful proof before existing loadability owner receives", function()
		with_managed({}, function(f)
			local accepted, terminals = start(f)
			helpers.assert_true(accepted)
			f.receipt(proof(0))
			f.pulls[1].on_done(0)
			helpers.assert_nil(f.active_tasks.ollama_pull)
			helpers.assert_true(f.removed())
			helpers.assert_eq(terminals.success, 0)
			helpers.assert_type(f.http_callback(), "function")
			f.http_callback()(200, "{}", {})
			helpers.assert_eq(terminals.success, 1)
		end)
	end)

	helpers.it("rejects duplicate private input binding and dispatch without cleanup loss", function()
		with_managed({}, function(f)
			helpers.assert_true(start(f))
			local task = f.pulls[1]
			helpers.assert_eq(f.handle().bind_input(task), false)
			helpers.assert_eq(f.adapter().mark_start_attempted(task), false)
			helpers.assert_eq(f.adapter().rollback(task), false)
			helpers.assert_eq(f.active_tasks.ollama_pull, task)
		end)
	end)
	helpers.it("fences reentry while exact private cleanup is dispatching", function()
		with_managed({}, function(f)
			local accepted, terminals = start(f)
			helpers.assert_true(accepted)
			local task = f.pulls[1]
			f.receipt(proof(0))
			local hook_called = false
			f.cleanup_hook(function()
				hook_called = true
				helpers.assert_eq(f.active_tasks.ollama_pull, task)
				helpers.assert_eq(task.on_done(0), false)
			end)
			task.on_done(0)
			helpers.assert_true(hook_called)
			helpers.assert_nil(f.active_tasks.ollama_pull)
			helpers.assert_eq(f.notifications(), 1)
			f.http_callback()(200, "{}", {})
			helpers.assert_eq(terminals.success, 1)
		end)
	end)

	helpers.it("fences cleanup reentry from a refused start with valid callback proof", function()
		with_managed({ start_result = false, complete_during_start = 0, receipt_during_start = proof(0) }, function(f)
			local accepted, terminals = start(f)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(f.reentry_result(), false)
			helpers.assert_nil(f.active_tasks.ollama_pull)
			helpers.assert_true(f.removed())
			helpers.assert_nil(f.http_callback())
			helpers.assert_eq(terminals.cancel, 1)
			helpers.assert_eq(terminals.success, 0)
		end)
	end)

end)

return true
