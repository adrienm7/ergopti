--- tests/unit/modules/llm/streaming/test_stream_payload_cleanup.lua

--- Replays admitted payload cleanup through both real public streaming fetch paths.
local helpers = require("tests.helpers")
local Fixture = require("tests.support.modules.llm.stream_payload_cleanup_fixture")

helpers.describe("streaming payload cleanup admission and retirement", function()
	for _, backend in ipairs({ "ollama", "mlx" }) do
		helpers.it("(stream-payload-cleanup) " .. backend .. " removes a healthy completed payload", function()
			Fixture.with_stream(backend, function(h)
				h.request()
				helpers.assert_eq(#h.tasks, 1)
				local path = h.tasks[1].payload
				helpers.assert_contains(h.read(path), "typed context")
				h.complete(1)
				helpers.assert_nil(h.read(path))
				helpers.assert_eq(h.successes, 1)
				helpers.assert_eq(h.failures, 0)
			end)
		end)
		helpers.it("(stream-payload-cleanup) " .. backend .. " keeps unsettled task input owned", function()
			Fixture.with_stream(backend, function(h)
				h.request()
				local path = h.tasks[1].payload
				h.fire(h.timers[1])
				helpers.assert_not_nil(h.read(path), "a delivered cleanup timer does not prove original task settlement")
				helpers.assert_eq(h.tasks[1].running, true)
				h.complete(1)
				helpers.assert_nil(h.read(path))
				helpers.assert_eq(h.successes, 1)
			end)
		end)
		helpers.it("(stream-payload-cleanup) " .. backend .. " revokes a fallback after successful unlink", function()
			Fixture.with_stream(backend, function(h)
				h.request()
				local path, fallback = h.tasks[1].payload, h.timers[1]
				h.complete(1)
				helpers.assert_nil(h.read(path))
				h.replace(path)
				h.fire(fallback)
				helpers.assert_eq(h.read(path), "NEW_OWNED_REPLACEMENT",
					"an acknowledged unlink retires this request's delete authority")
				helpers.assert_eq(h.attempts[path], 1)
			end)
		end)
		helpers.it("(stream-payload-cleanup) " .. backend .. " settles refused cleanup before another payload", function()
			Fixture.with_stream(backend, function(h)
				h.request()
				local path, fallback = h.tasks[1].payload, h.timers[1]
				h.denied[path] = true
				h.complete(1)
				helpers.assert_eq(h.successes, 1, "provider completion remains independent of physical cleanup debt")
				h.fire(fallback)
				helpers.assert_not_nil(h.read(path))
				h.request()
				helpers.assert_eq(h.allocations, 1, "pending cleanup must refuse allocation of a successor payload")
				helpers.assert_eq(#h.tasks, 1)
				helpers.assert_eq(h.failures, 1)
				local diagnostics = table.concat(h.errors, "\n")
				helpers.assert_contains(diagnostics, "cleanup")
				helpers.assert_nil(diagnostics:find("PRIVATE_PATH", 1, true))
				h.denied[path] = nil
				h.request()
				helpers.assert_eq(#h.tasks, 2)
				helpers.assert_nil(h.read(path), "the earlier exact receipt is settled before successor dispatch")
				h.complete(2)
				helpers.assert_eq(h.successes, 2)
			end)
		end)
		helpers.it("(stream-payload-cleanup) " .. backend .. " keeps generation revocation separate from cleanup", function()
			Fixture.with_stream(backend, function(h)
				h.request()
				local path = h.tasks[1].payload
				h.denied[path] = true
				helpers.assert_eq(h.cancel(), false)
				h.complete(1, 15)
				helpers.assert_eq(h.successes, 0)
				helpers.assert_eq(h.failures, 0)
				h.request()
				helpers.assert_eq(h.allocations, 1)
				h.denied[path] = nil
				h.request()
				helpers.assert_eq(#h.tasks, 2)
				h.tasks[1].done(15, "", "")
				helpers.assert_eq(h.tasks[2].running, true)
				helpers.assert_not_nil(h.read(h.tasks[2].payload))
				h.complete(2)
				helpers.assert_eq(h.successes, 1)
			end)
		end)
		for _, stage in ipairs({ "creation", "start" }) do
			helpers.it("(stream-payload-cleanup) " .. backend .. " retains cleanup after refused " .. stage, function()
				Fixture.with_stream(backend, function(h)
					h.refuse_creation, h.refuse_start = stage == "creation", stage == "start"
					h.deny_at_spawn = true
					h.request()
					local path = h.payloads[1]
					helpers.assert_not_nil(h.read(path))
					if stage == "start" then h.complete(1, 15) end
					h.request()
					helpers.assert_eq(h.allocations, 1)
					h.denied[path], h.refuse_creation, h.refuse_start, h.deny_at_spawn = nil, false, false, false
					h.request()
					helpers.assert_eq(h.allocations, 2)
					helpers.assert_nil(h.read(path))
					h.complete(#h.tasks)
				end)
			end)
		end
		helpers.it("(stream-payload-cleanup) " .. backend .. " preserves a failed writer's replacement", function()
			Fixture.with_stream(backend, function(h)
				h.refuse_writer = true
				h.request()
				helpers.assert_eq(#h.tasks, 0)
				helpers.assert_eq(h.failures, 1)
				helpers.assert_eq(h.read(h.failed_writer_path), "FOREIGN_REPLACEMENT")
			end)
		end)
	end
end)

helpers.it("(stream-payload-cleanup) mlx retains unlink debt after watchdog admission refuses", function()
	Fixture.with_stream("mlx", function(h)
		h.refuse_watchdog, h.deny_at_spawn = true, true
		h.request()
		local path = h.payloads[1]
		helpers.assert_eq(#h.tasks, 1)
		helpers.assert_eq(h.tasks[1].running, true)
		h.complete(1, 15)
		helpers.assert_eq(h.failures, 1)
		h.request()
		helpers.assert_eq(h.allocations, 1, "a refused watchdog's settled task does not discard unlink debt")
		h.denied[path], h.refuse_watchdog, h.deny_at_spawn = nil, false, false
		h.request()
		helpers.assert_eq(h.allocations, 2)
		helpers.assert_nil(h.read(path))
		h.complete(#h.tasks)
		helpers.assert_eq(h.successes, 1)
	end)
end)
