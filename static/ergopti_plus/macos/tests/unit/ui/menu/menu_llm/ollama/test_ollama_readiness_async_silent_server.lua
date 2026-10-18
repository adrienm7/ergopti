--- tests/unit/ui/menu/menu_llm/ollama/test_ollama_readiness_async_silent_server.lua

-- =============================================================================
-- MODULE: Asynchronous Ollama Readiness Regression
-- DESCRIPTION:
-- Proves that readiness and delegated native daemon work is owned asynchronously,
-- generation-fenced, and terminal exactly once without blocking the Lua runloop.
-- Also proves that a requirement request receives every terminal from the real
-- pull continuation that it dispatches.
-- =============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.ui.menu.menu_llm.ollama.ollama_readiness_async_fixture"] = nil
local Fixture = require("tests.support.ui.menu.menu_llm.ollama.ollama_readiness_async_fixture")
local accept_model_download = Fixture.accept_model_download
local publish_daemon_ready = Fixture.publish_daemon_ready
local receive_pull_argv = Fixture.receive_pull_argv
local retained_receivers = Fixture.retained_receivers
local retire_daemon = Fixture.retire_daemon
local start_missing_model_pull = Fixture.start_missing_model_pull
local with_fixture = Fixture.with_fixture





--- Counts the generic "Ollama failed" notices.
--- @param fixture table The real-manager fixture.
--- @return integer count
local function failure_notices(fixture)
	local count = 0
	for _, notice in ipairs(fixture.notifications) do
		if notice[1] == "ollama.fail_title" then count = count + 1 end
	end
	return count
end

helpers.describe("A silent Ollama is one reason, told once (llm-enable-unreachable-local)", function()
	helpers.it("a start that never answers cancels as unreachable, with its caller's error only (llm-enable-unreachable-local)",
		function()
			with_fixture({}, function(fixture)
				local cancellations, details = {}, {}
				fixture.manager.check_requirements("demo", function() end, function(reason, detail)
					cancellations[#cancellations + 1] = reason
					details[#details + 1] = detail
				end, {is_current = function() return true end, reports_unreachable = true})
				fixture.spawns[1].complete(7, "", "connection refused")
				publish_daemon_ready(fixture.daemon)
				for _ = 1, 30 do
					local timer = fixture.timers[#fixture.timers]
					timer.fire()
					fixture.spawns[#fixture.spawns].complete(7, "", "connection refused")
				end
				helpers.assert_eq(cancellations, {require("modules.llm.ollama_endpoint").UNREACHABLE})
				helpers.assert_eq(details, {"readiness_timeout"})
				helpers.assert_eq(failure_notices(fixture), 0,
					"the caller's error names the fix; a second, generic notice would repeat it")
			end)
		end)

	helpers.it("a caller that does not report it still gets the generic notice (llm-enable-unreachable-local)", function()
		with_fixture({}, function(fixture)
			fixture.manager.check_requirements("demo", function() end, function() end,
				{is_current = function() return true end})
			fixture.spawns[1].complete(7, "", "connection refused")
			retire_daemon(fixture.daemon, 78)
			helpers.assert_eq(failure_notices(fixture), 1, "nobody else tells the user")
		end)
	end)
end)

helpers.describe("HS035 receiver exceptional closure", function()
	local vectors = {
		{ id = "write-throws", write = "throw", error = "writer-sentinel", file_closes = 1, process_closes = 0, removes = 1 },
		{ id = "write-nil", write = "nil", error = "writer-sentinel", file_closes = 1, process_closes = 0, removes = 1 },
		{ id = "source-close-throws", file_close = "throw", error = "source-close-sentinel", file_closes = 1, process_closes = 0, removes = 0, retained = true },
		{ id = "read-throws", read = "throw", error = "reader-sentinel", file_closes = 1, process_closes = 1, removes = 1 },
		{ id = "read-nil", read = "nil", error = "reader-sentinel", file_closes = 1, process_closes = 1, removes = 1 },
		{ id = "process-close-throws", process_close = "throw", error = "process-close-sentinel", file_closes = 1, process_closes = 1, removes = 0, retained = true },
		{ id = "read-and-close-throw", read = "throw", process_close = "throw", error = "reader-sentinel", file_closes = 1, process_closes = 1, removes = 0, retained = true },
		{ id = "nonzero-exit-is-retired", process_close = "nonzero", error = "expected: true", file_closes = 1, process_closes = 1, removes = 1 },
		{ id = "packet-remove-refused", remove = "nil", error = "remove-sentinel", file_closes = 1, process_closes = 1, removes = 1, retained = true },
	}
	for _, vector in ipairs(vectors) do
		helpers.it(vector.id, function()
			local saved_open, saved_popen, saved_remove = io.open, io.popen, os.remove
			local counts = { file_closes = 0, process_closes = 0, removes = 0 }
			local events = {}
			local before = #retained_receivers
			local file = {
				write = function()
					if vector.write == "throw" then error("writer-sentinel", 0) end
					if vector.write == "nil" then return nil, "writer-sentinel" end
					return true
				end,
				close = function()
					counts.file_closes = counts.file_closes + 1
					events[#events + 1] = "file-close"
					if vector.file_close == "throw" then error("source-close-sentinel", 0) end
					return true
				end,
			}
			local process = {
				read = function()
					if vector.read == "throw" then error("reader-sentinel", 0) end
					if vector.read == "nil" then return nil, "reader-sentinel" end
					return '{"executable":"/opt/homebrew/bin/ollama","args":["pull","missing-model"]}'
				end,
				close = function()
					counts.process_closes = counts.process_closes + 1
					events[#events + 1] = "process-close"
					if vector.process_close == "throw" then error("process-close-sentinel", 0) end
					if vector.process_close == "nonzero" then return nil, "exit", 2 end
					return true, "exit", 0
				end,
			}
			io.open = function() return file end
			io.popen = function() return process end
			os.remove = function()
				counts.removes = counts.removes + 1
				events[#events + 1] = "remove"
				if vector.remove == "nil" then return nil, "remove-sentinel" end
				return true
			end
			local ok, err = xpcall(function()
				return receive_pull_argv("/bin/bash", { "-c", "receiver-owned fault input" })
			end, debug.traceback)
			io.open, io.popen, os.remove = saved_open, saved_popen, saved_remove
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(err):find(vector.error, 1, true) ~= nil, tostring(err))
			helpers.assert_eq(counts, { file_closes = vector.file_closes, process_closes = vector.process_closes, removes = vector.removes })
			if vector.removes == 1 then helpers.assert_eq(events[#events], "remove") end
			helpers.assert_eq(#retained_receivers, before + (vector.retained and 1 or 0))
			if vector.retained then
				local owner = retained_receivers[#retained_receivers]
				helpers.assert_eq(owner.packet_created, true)
				if vector.file_close == "throw" then helpers.assert_eq(owner.file, file) end
				if vector.process_close == "throw" then helpers.assert_eq(owner.process, process) end
				-- These are receiver-owned fake handles, not an unretired native child.
				-- Drop only this injected record; real unresolved records stay owned.
				table.remove(retained_receivers)
			end
		end)
	end
end)


helpers.describe("Ollama loadability follows the configured endpoint", function()
	helpers.it("(ollama-loadability-origin) checks the configured service before publishing a model", function()
		with_fixture({shared_system_check = accept_model_download, ollama_port = 11470}, function(fixture)
			local accepted, terminal = start_missing_model_pull(fixture, {current = true})
			helpers.assert_true(accepted)
			fixture.native_tasks[2].on_done(0, "", "")
			helpers.assert_eq(fixture.http_callbacks[1].url, "http://127.0.0.1:11470/api/chat")
			fixture.http_callbacks[1].callback(200, "{}", {})
			helpers.assert_eq(terminal.successes, 1)
			helpers.assert_eq(terminal.failures, 0)
		end)
	end)
	helpers.it("(ollama-loadability-origin) rejects success from a superseded configured service", function()
		with_fixture({shared_system_check = accept_model_download}, function(fixture)
			local accepted, terminal = start_missing_model_pull(fixture, {current = true})
			helpers.assert_true(accepted)
			fixture.native_tasks[2].on_done(0, "", "")
			fixture.set_ollama_port(11471)
			fixture.http_callbacks[1].callback(200, "{}", {})
			fixture.http_callbacks[1].callback(200, "duplicate", {})
			helpers.assert_eq(terminal.successes, 0)
			helpers.assert_eq(terminal.failures, 1)
			helpers.assert_eq(terminal.reasons, {"stale"})
		end)
	end)
end)

helpers.describe("Ollama pull loadability failure", function()
	helpers.it("(ollama-loadability-failure) refuses the selected model when post-pull loadability fails", function()
		with_fixture({shared_system_check = accept_model_download}, function(fixture)
			local accepted, terminal = start_missing_model_pull(fixture, {current = true})
			helpers.assert_true(accepted)
			fixture.native_tasks[2].on_done(0, "", "")
			fixture.http_callbacks[1].callback(500, "unable to load model", {})
			helpers.assert_eq(terminal.successes, 0)
			helpers.assert_eq(terminal.failures, 1)
			helpers.assert_eq(terminal.reasons, {"model_load_failed"})
		end)
	end)
end)

helpers.describe("Ollama model-ready presentation owns loadability", function()
	local function ready_notice_count(fixture)
		local count = 0
		for _, notice in ipairs(fixture.notifications) do
			if notice[2] == "ollama.model_ready" then count = count + 1 end
		end
		return count
	end

	helpers.it("(ollama-ready-toast) waits for a successful loadability receipt and notifies once", function()
		with_fixture({shared_system_check = accept_model_download}, function(fixture)
			local accepted, terminal = start_missing_model_pull(fixture, {current = true})
			helpers.assert_true(accepted)
			fixture.native_tasks[2].on_done(0, "", "")
			helpers.assert_eq(ready_notice_count(fixture), 0,
				"a downloaded archive cannot qualify a model before its loadability receipt")
			fixture.http_callbacks[1].callback(200, "{}", {})
			helpers.assert_eq(terminal.successes, 1)
			helpers.assert_eq(ready_notice_count(fixture), 1)
			fixture.http_callbacks[1].callback(200, "duplicate", {})
			fixture.native_tasks[2].on_done(0, "", "duplicate")
			helpers.assert_eq(terminal.successes, 1)
			helpers.assert_eq(ready_notice_count(fixture), 1)
		end)
	end)

	helpers.it("(ollama-ready-toast) never presents a downloaded model whose loadability fails as ready", function()
		with_fixture({shared_system_check = accept_model_download}, function(fixture)
			local accepted, terminal = start_missing_model_pull(fixture, {current = true})
			helpers.assert_true(accepted)
			fixture.native_tasks[2].on_done(0, "", "")
			fixture.http_callbacks[1].callback(500, "unable to load model", {})
			helpers.assert_eq(terminal.successes, 0)
			helpers.assert_eq(terminal.failures, 1)
			helpers.assert_eq(ready_notice_count(fixture), 0)
		end)
	end)

	helpers.it("(ollama-ready-toast) never presents a held receipt from the former endpoint as ready", function()
		with_fixture({shared_system_check = accept_model_download}, function(fixture)
			local accepted, terminal = start_missing_model_pull(fixture, {current = true})
			helpers.assert_true(accepted)
			fixture.native_tasks[2].on_done(0, "", "")
			fixture.set_ollama_port(11471)
			fixture.http_callbacks[1].callback(200, "{}", {})
			helpers.assert_eq(terminal.successes, 0)
			helpers.assert_eq(terminal.failures, 1)
			helpers.assert_eq(ready_notice_count(fixture), 0)
		end)
	end)
end)

return { retained_receivers = retained_receivers }
