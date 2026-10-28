--- tests/unit/modules/llm/streaming/test_payload_file_admission.lua

--- ==============================================================================
--- MODULE: Streaming Payload File Admission
--- DESCRIPTION:
--- Drive both real streaming request paths over controlled file refusals and
--- actual temporary files. No transport may observe an unflushed JSON payload.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_stream = require("tests.support.modules.llm.streaming_payload_fixture").with_stream

helpers.describe("streaming requires an acknowledged complete payload", function()
	for _, backend in ipairs({ "mlx", "ollama" }) do
		helpers.it(backend .. " admits the actual closed JSON bytes to transport", function()
			with_stream(backend, function(h)
				helpers.assert_true(h.request())
				helpers.assert_eq(h.writes, 1); helpers.assert_eq(h.closes, 1)
				helpers.assert_eq(h.spawns, 1)
				local payload = require("adapters.json_codec").decode(h.payload)
				helpers.assert_eq(payload.stream, true)
				helpers.assert_true(h.payload:find("typed context", 1, true) ~= nil)
			end)
		end)
		for _, phase in ipairs({ "open", "write", "close" }) do
			local refusals = phase == "open" and { "nil", "false", "throw" } or { "nil", "false", "throw", "foreign" }
			for _, refusal in ipairs(refusals) do
				helpers.it(backend .. " refuses " .. phase .. " " .. refusal .. " before transport admission", function()
					with_stream(backend, function(h)
						h.phase, h.refusal = phase, refusal
						helpers.assert_true(h.request(), "native I/O failure must reach on_fail rather than escape")
						helpers.assert_eq(h.failures, 1); helpers.assert_eq(h.successes, 0)
						helpers.assert_eq(h.spawns, 0); helpers.assert_eq(h.timers, 0)
						helpers.assert_eq(h.closes, phase == "open" and 0 or 1, "close must still run after refused writes")
						h.phase, h.refusal = nil, nil
						helpers.assert_true(h.request()); helpers.assert_eq(h.spawns, 1, "a failed file must not poison the next request")
					end)
				end)
			end
		end
		helpers.it(backend .. " preserves a replacement at the failed payload path", function()
			with_stream(backend, function(h)
				h.phase, h.refusal, h.replace = "close", "nil", true
				helpers.assert_true(h.request())
				helpers.assert_eq(h.spawns, 0); helpers.assert_eq(h.failures, 1)
				helpers.assert_eq(h.read(h.paths[1]), "FOREIGN_REPLACEMENT")
				helpers.assert_nil(h.removed[h.paths[1]], "a pathname alone cannot authorize deleting a concurrent replacement")
			end)
		end)
	end
end)
