--- tests/unit/adapters/log_transport/test_protocol.lua

--- ==============================================================================
--- MODULE: LogTransport configure and one-in-flight protocol Tests
--- DESCRIPTION:
--- Exercises real transport behavior inside an isolated native and module scope.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.log_transport_fixture")
local new_context, configure = Fixture.new_context, Fixture.configure
local TOKEN, SESSION, LOOPBACK = Fixture.TOKEN, Fixture.SESSION, Fixture.LOOPBACK

helpers.describe("LogTransport configure and one-in-flight protocol", function()
	helpers.it("returns startup success only after a bounded exact configure ACK", function()
		Fixture.with_fixture(function()
			local context = new_context()
			local started, start_err = context:start()
			helpers.assert_eq(started, true, tostring(start_err))
			helpers.assert_eq(context.state.bootstrap_new_calls, 1)
			helpers.assert_eq(context.state.bootstrap_close_calls, 1,
				"the boot-only blocking socket must be closed before runtime activation")
			helpers.assert_true(
				type(context.state.preflight_timeouts[1]) == "number"
					and context.state.preflight_timeouts[1] > 0
					and context.state.preflight_timeouts[1] <= 0.25,
				"boot preflight must have a short positive deadline"
			)
			helpers.assert_eq(context.state.listen_calls, 1)
			helpers.assert_eq(context.state.listen_port, 0,
				"the runtime socket needs a concrete ephemeral ACK endpoint")
			helpers.assert_eq(table.concat(context.state.activation_order, ","), "listen,receive,timer",
				"bind and receive must commit before the pump can send sequence one")
			helpers.assert_eq(context.transport.status().configured, true)
		end)
	end)

	helpers.it("rejects caller attempts to widen or disable the boot deadline", function()
		Fixture.with_fixture(function()
			for _, timeout in ipairs({ -1, 0, 0.251, 5 }) do
				local context = new_context()
				context.options.bootstrap_timeout_sec = timeout
				local started = context:start()
				helpers.assert_eq(started, false, "timeout=" .. tostring(timeout))
				helpers.assert_eq(#context.state.preflight_payloads, 0,
					"an invalid deadline must fail before a blocking receive becomes possible")
				helpers.assert_eq(context.state.bootstrap_close_calls, 1,
					"the exact bootstrap handle must still be released")
				helpers.assert_eq(context.state.new_calls, 0)
			end
		end)
	end)

	helpers.it("refuses timeout, NACK, wrong identity, and wrong source before input", function()
		Fixture.with_fixture(function()
			local cases = {
				{ name = "timeout", mode = "timeout" },
				{ name = "native NACK", mode = "nack" },
				{ name = "wrong token", mode = "wrong-token" },
				{ name = "wrong session", mode = "wrong-session" },
				{ name = "wrong sequence", mode = "wrong-sequence" },
				{ name = "wrong source host", address = { host = "192.0.2.9", port = 49321 } },
				{ name = "wrong source port", address = { host = "127.0.0.1", port = 49322 } },
			}
			for _, case in ipairs(cases) do
				local context = new_context()
				context.state.preflight_mode = case.mode
				context.state.preflight_address = case.address
				local started = context:start()
				helpers.assert_eq(started, false,
					case.name .. " is not evidence that the native sink committed")
				helpers.assert_eq(context.transport.status().configured, false)
				helpers.assert_eq(context.transport.status().active, false)
				helpers.assert_eq(context.state.every_calls, 0,
					case.name .. " must not arm the runtime pump before preflight succeeds")
			end
		end)
	end)

	helpers.it("sends configure sequence zero before any queued record", function()
		Fixture.with_fixture(function()
			local context = new_context()
			local started, start_err = context:start()
			helpers.assert_eq(started, true, tostring(start_err))
			local configure_payload = context:payload(1)
			helpers.assert_eq(configure_payload.v, 1)
			helpers.assert_eq(configure_payload.kind, "configure")
			helpers.assert_eq(configure_payload.sequence, 0)
			helpers.assert_eq(configure_payload.token, TOKEN)
			helpers.assert_eq(configure_payload.session, SESSION)
			helpers.assert_eq(configure_payload.log_dir, "/tmp/ergopti/logs")
			helpers.assert_eq(configure_payload.retention_days, 21)

			-- Deliberately differs from the wall date. A record retained across midnight
			-- belongs to the date already frozen into its canonical timestamp, not the
			-- later retry/pump date.
			local first_line = "2001-02-03 12:00:00:001 | INFO | test | LLM first"
			context.transport.enqueue(first_line, "info")
			context.state.pump()
			helpers.assert_eq(#context.state.sends, 2,
				"record sequence one may follow only after preflight ACKed sequence zero")
			local record_payload = context:payload(2)
			helpers.assert_eq(record_payload.kind, "record")
			helpers.assert_eq(record_payload.sequence, 1)
			helpers.assert_eq(record_payload.line, first_line)
			helpers.assert_eq(record_payload.calendar_date, "2001-02-03",
				"worker date rotation must derive from the canonical record timestamp")
			helpers.assert_eq(record_payload.topics[1], "ErgoptiPlus_llm.log",
				"topical routes must use the native worker's validated filename contract")
		end)
	end)

	helpers.it("freezes an undated record's calendar date at enqueue time", function()
		Fixture.with_fixture(function()
			local context = new_context()
			configure(context)
			local original_date = os.date
			local wall_date = "2001-02-03"
			os.date = function(format)
				helpers.assert_eq(format, "%Y-%m-%d")
				return wall_date
			end

			local call_ok, call_err = xpcall(function()
				local line = string.rep("u", 9000)
				local retained, enqueue_err = context.transport.enqueue(line, "info")
				helpers.assert_not_nil(retained, tostring(enqueue_err))
				wall_date = "2001-02-04"

				context.state.pump()
				local first = context:payload()
				helpers.assert_eq(first.calendar_date, "2001-02-03",
					"the first fragment must use the producer's admission date")
				helpers.assert_contains(first.line, "2001-02-03 00:00:00:000")
				context:ack(first.sequence)

				context.state.pump()
				local second = context:payload()
				helpers.assert_eq(second.calendar_date, "2001-02-03",
					"every fragment must reuse the one frozen admission date")
				helpers.assert_contains(second.line, "2001-02-03 00:00:00:000")
			end, debug.traceback)
			os.date = original_date
			helpers.assert_true(call_ok, tostring(call_err))
		end)
	end)

	helpers.it("keeps exactly one record in flight and delivers in queue order", function()
		Fixture.with_fixture(function()
			local context = new_context()
			configure(context)
			context.transport.enqueue("one", "info")
			context.transport.enqueue("two", "warn")
			context.state.pump()
			helpers.assert_eq(#context.state.sends, 2)
			local first_payload = context:payload()
			helpers.assert_eq(first_payload.sequence, 1)
			helpers.assert_nil(first_payload.topics,
				"an empty Lua table encodes ambiguously; the wire contract omits empty topics")

			context.state.pump()
			helpers.assert_eq(#context.state.sends, 2,
				"a second queue entry must not overtake an unacknowledged head")
			context:ack(1)
			helpers.assert_eq(#context.state.delivered, 1)
			helpers.assert_eq(context.state.delivered[1].line, "one")
			context.state.pump()
			helpers.assert_eq(context:payload().sequence, 2)
			context:ack(2)

			helpers.assert_eq(#context.state.delivered, 2)
			helpers.assert_eq(context.state.delivered[2].line, "two")
			helpers.assert_eq(context.transport.status().queued, 0)
		end)
	end)

	helpers.it("encodes one complete short-record batch once instead of serializing every prefix", function()
		Fixture.with_fixture(function()
			local context = new_context({ batch_records = 64 })
			configure(context)
			local original_encode = context.hs.json.encode
			local batch_encode_calls = 0
			context.hs.json.encode = function(value)
				if type(value) == "table" and value.kind == "batch" then
					batch_encode_calls = batch_encode_calls + 1
				end
				return original_encode(value)
			end
			for index = 1, 64 do
				local retained, enqueue_err = context.transport.enqueue(
					"codec-linear-" .. tostring(index),
					"info"
				)
				helpers.assert_not_nil(retained, tostring(enqueue_err))
			end
			context.state.pump()
			context.hs.json.encode = original_encode
			local batch = context:batch()
			helpers.assert_eq(#batch.records, 64)
			helpers.assert_eq(batch_encode_calls, 1,
				"the timer hot path must encode the complete fitting batch only once")
			context:ack(64)
			helpers.assert_eq(context.transport.status().queued, 0)
		end)
	end)

	helpers.it("shrinks oversized JSON batches logarithmically without loss or reordering", function()
		Fixture.with_fixture(function()
			local context = new_context({ batch_records = 64 })
			configure(context)
			local expected = {}
			for index = 1, 16 do
				local line = string.rep("\\", 7000) .. tostring(index)
				expected[index] = line
				local retained, enqueue_err = context.transport.enqueue(line, "info")
				helpers.assert_not_nil(retained, tostring(enqueue_err))
			end
			local original_encode = context.hs.json.encode
			local batch_encode_calls = 0
			context.hs.json.encode = function(value)
				if type(value) == "table" and value.kind == "batch" then
					batch_encode_calls = batch_encode_calls + 1
				end
				return original_encode(value)
			end
			local completion = nil
			helpers.assert_true(context.transport.drain(function(settled, detail)
				completion = { settled = settled, detail = detail }
			end, 2.0))

			local expected_sequence = 1
			local batch_count = 0
			local body_ok, body_err = xpcall(function()
				while context.transport.status().queued > 0 do
					batch_count = batch_count + 1
					context.state.pump()
					local sent = context.state.sends[#context.state.sends]
					local batch = context:batch()
					helpers.assert_eq(batch.kind, "batch")
					helpers.assert_true(#batch.records > 0 and #batch.records < 16,
						"the oversized full candidate must reduce to a non-empty fitting prefix")
					helpers.assert_true(#sent.data < 60000)
					for _, record in ipairs(batch.records) do
						helpers.assert_eq(record.sequence, expected_sequence)
						helpers.assert_eq(record.line, expected[expected_sequence])
						expected_sequence = expected_sequence + 1
					end
					context:ack(batch.records[#batch.records].sequence)
				end
			end, debug.traceback)
			context.hs.json.encode = original_encode
			helpers.assert_true(body_ok, tostring(body_err))
			helpers.assert_eq(expected_sequence, 17)
			helpers.assert_true(batch_encode_calls > batch_count,
				"the fixture must exercise the too-large reduction branch")
			helpers.assert_true(batch_encode_calls <= batch_count * 7,
				"64 candidates need at most one full encode plus six binary-search probes")
			helpers.assert_eq(#context.state.delivered, 16)
			for index, delivered in ipairs(context.state.delivered) do
				helpers.assert_eq(delivered.sequence, index)
				helpers.assert_eq(delivered.line, expected[index])
			end
			helpers.assert_nil(completion,
				"the final socket ACK must leave terminal continuation to the pump")
			context.state.pump()
			helpers.assert_eq(completion.settled, true, tostring(completion.detail))
		end)
	end)

	helpers.it("preserves FIFO order across the deque compaction boundary", function()
		Fixture.with_fixture(function()
			local context = new_context()
			configure(context)
			local count = 1030
			for index = 1, count do
				local record, enqueue_err = context.transport.enqueue(
					"ordered-record-" .. tostring(index),
					"info"
				)
				helpers.assert_not_nil(record, tostring(enqueue_err))
			end

			for index = 1, count do
				context.state.pump()
				local payload = context:payload()
				helpers.assert_eq(payload.sequence, index)
				helpers.assert_eq(payload.line, "ordered-record-" .. tostring(index),
					"deque compaction must not skip, duplicate, or reorder a retained record")
				context:ack(index)
			end
			helpers.assert_eq(context.transport.status().queued, 0)
			helpers.assert_eq(#context.state.delivered, count)
			helpers.assert_eq(context.state.delivered[count].line, "ordered-record-" .. tostring(count))
		end)
	end)

	helpers.it("bounds ordinary traffic while reserving exact warning/error ownership", function()
		Fixture.with_fixture(function()
			local context = new_context()
			configure(context)
			for index = 1, 7168 do
				local record = context.transport.enqueue("capacity-" .. tostring(index), "trace")
				helpers.assert_not_nil(record, "the ordinary queue capacity must remain usable")
			end
			local refused, refusal = context.transport.enqueue("capacity-overflow", "trace")
			helpers.assert_nil(refused)
			helpers.assert_contains(refusal, "capacity",
				"overflow must fail visibly instead of silently evicting an earlier record")

			local diagnostic, diagnostic_err = context.transport.enqueue(
				"diagnostic after ordinary saturation",
				"error"
			)
			helpers.assert_not_nil(diagnostic,
				"ordinary saturation must not consume the ERROR ownership reserve: "
					.. tostring(diagnostic_err))
			for index = 2, 1024 do
				local retained = context.transport.enqueue("reserved-warning-" .. tostring(index), "warn")
				helpers.assert_not_nil(retained, "the complete diagnostic reserve must be usable")
			end
			local full_refusal, full_detail = context.transport.enqueue("absolute-overflow", "error")
			helpers.assert_nil(full_refusal)
			helpers.assert_contains(full_detail, "capacity")
			local saturated = context.transport.status()
			helpers.assert_eq(saturated.queued, 8192)
			helpers.assert_eq(saturated.dropped_total, 2,
				"every refused producer record must remain visible in the health snapshot")
			helpers.assert_eq(saturated.dropped_noncritical, 1)
			helpers.assert_eq(saturated.dropped_critical, 1)
			helpers.assert_eq(saturated.dropped_by_variant.trace, 1)
			helpers.assert_eq(saturated.dropped_by_variant.error, 1)
			helpers.assert_eq(saturated.rejected_error_fallback_queued, 1,
				"an ERROR refused by the native queue must retain one bounded fallback owner")
			helpers.assert_eq(#context.state.failures, 0,
				"producer-side capacity refusal must not call the fail-safe on the HID stack")

			context.state.pump()
			helpers.assert_eq(#context.state.failures, 1,
				"the next timer-owned pump must surface producer-side capacity refusal")
			helpers.assert_contains(context.state.failures[1], "capacity")
			helpers.assert_eq(#context.state.rejected, 1,
				"the timer-owned fallback must release the exact refused ERROR")
			helpers.assert_eq(context.state.rejected[1].line, "absolute-overflow")
			helpers.assert_eq(context.state.rejected[1].variant, "error")
			helpers.assert_eq(context.transport.status().rejected_error_fallback_queued, 0)
		end)
	end)

	helpers.it("refuses a producer record above the documented byte ceiling", function()
		Fixture.with_fixture(function()
			local context = new_context()
			configure(context)
			local maximum_line = string.rep("x", 65536)
			local retained, retained_err = context.transport.enqueue(maximum_line, "info")
			helpers.assert_not_nil(retained, tostring(retained_err))
			helpers.assert_eq(context.transport.status().queued, 1,
				"the exact 64 KiB producer ceiling must remain usable")

			local oversized = string.rep("y", 65537)
			local refused, refusal, fallback = context.transport.enqueue(oversized, "error")
			helpers.assert_nil(refused)
			helpers.assert_contains(refusal, "65536 bytes",
				"the refusal must state the exact admission ceiling")
			helpers.assert_nil(fallback,
				"an oversized ERROR must not retain its original line in the fallback queue")
			local status = context.transport.status()
			helpers.assert_eq(status.queued, 1)
			helpers.assert_eq(status.max_record_bytes, 65536,
				"health status must publish the same ceiling enforced at admission")
			helpers.assert_eq(status.dropped_total, 1)
			helpers.assert_eq(status.dropped_critical, 1)
			helpers.assert_eq(status.dropped_by_variant.error, 1)
			helpers.assert_eq(status.rejected_error_fallback_queued, 0)
		end)
	end)

	helpers.it("bounds rejected ERROR fallback ownership and timer work per tick", function()
		Fixture.with_fixture(function()
			local context = new_context()
			configure(context)
			for index = 1, 7168 do
				local retained, enqueue_err = context.transport.enqueue(
					"fallback-normal-" .. tostring(index), "info")
				helpers.assert_not_nil(retained, tostring(enqueue_err))
			end
			for index = 1, 1024 do
				local retained, enqueue_err = context.transport.enqueue(
					"fallback-critical-" .. tostring(index), "warn")
				helpers.assert_not_nil(retained, tostring(enqueue_err))
			end

			for index = 1, 65 do
				local retained, enqueue_err, fallback = context.transport.enqueue(
					"rejected-error-" .. tostring(index), "error")
				helpers.assert_nil(retained)
				helpers.assert_contains(enqueue_err, "capacity")
				if index <= 64 then
					helpers.assert_type(fallback, "table",
						"each bounded slot must return the exact record Logger can annotate")
				else
					helpers.assert_nil(fallback,
						"the sixty-fifth refusal must not grow fallback memory beyond its cap")
				end
			end
			local saturated = context.transport.status()
			helpers.assert_eq(saturated.dropped_total, 65)
			helpers.assert_eq(saturated.dropped_critical, 65)
			helpers.assert_eq(saturated.rejected_error_fallback_queued, 64)
			helpers.assert_eq(saturated.rejected_error_fallback_overflow, 1)

			context.state.pump()
			helpers.assert_eq(#context.state.rejected, 8,
				"one pump tick must release only the documented bounded fallback quota")
			helpers.assert_eq(context.transport.status().rejected_error_fallback_queued, 56)
			for _ = 1, 7 do context.state.pump() end
			helpers.assert_eq(#context.state.rejected, 64)
			helpers.assert_eq(context.state.rejected[1].line, "rejected-error-1")
			helpers.assert_eq(context.state.rejected[64].line, "rejected-error-64")
			helpers.assert_eq(context.transport.status().rejected_error_fallback_queued, 0)
		end)
	end)

	helpers.it("drains the maximum admitted backlog in FIFO batches before the two-second deadline", function()
		Fixture.with_fixture(function()
			local context = new_context({ batch_records = 64 })
			configure(context)
			local expected = {}
			for index = 1, 7168 do
				local line = "backlog-normal-" .. tostring(index)
				expected[#expected + 1] = line
				local retained, enqueue_err = context.transport.enqueue(line, "trace")
				helpers.assert_not_nil(retained, tostring(enqueue_err))
			end
			for index = 7169, 8191 do
				local line = "backlog-critical-" .. tostring(index)
				expected[#expected + 1] = line
				local retained, enqueue_err = context.transport.enqueue(line, "warn")
				helpers.assert_not_nil(retained, tostring(enqueue_err))
			end
			local final_line = "backlog-critical-8192"
			expected[#expected + 1] = final_line
			local final_record, enqueue_err = context.transport.enqueue(final_line, "error")
			helpers.assert_not_nil(final_record, tostring(enqueue_err))
			final_record.notification = {
				module_name = "logger",
				message = "maximum backlog drained",
			}
			helpers.assert_eq(context.transport.status().queued, 8192,
				"the test must exercise the exact admitted producer ceiling")

			local completion = nil
			local drained, drain_err = context.transport.drain(function(settled, detail)
				completion = { settled = settled, detail = detail, clock = context.state.clock }
			end, 2.0)
			helpers.assert_true(drained, tostring(drain_err))

			local expected_sequence = 1
			local batch_count = 0
			local saw_full_batch = false
			while expected_sequence <= 8192 do
				batch_count = batch_count + 1
				helpers.assert_true(batch_count <= 200,
					"the admitted queue must not exceed its drain-timer pump budget")
				context.state.clock = context.state.clock + 0.01
				context.state.pump()
				local sent = context.state.sends[#context.state.sends]
				local batch = context:batch()
				helpers.assert_eq(batch.kind, "batch")
				helpers.assert_true(#batch.records >= 1 and #batch.records <= 64,
					"every datagram must carry one bounded non-empty record batch")
				if #batch.records == 64 then saw_full_batch = true end
				helpers.assert_true(#sent.data < 60000,
					"dynamic batching must stay below the authenticated datagram ceiling")
				for _, record in ipairs(batch.records) do
					helpers.assert_eq(record.sequence, expected_sequence)
					helpers.assert_eq(record.line, expected[expected_sequence],
						"batching must preserve exact producer FIFO order")
					expected_sequence = expected_sequence + 1
				end
				context:ack(batch.records[#batch.records].sequence)
				if expected_sequence <= 8192 then
					helpers.assert_nil(completion,
						"a partial backlog ACK cannot certify a completed drain")
				end
			end
			helpers.assert_true(saw_full_batch,
				"ordinary short records must exercise the complete 64-record batch capacity")
			helpers.assert_eq(expected_sequence, 8193)
			helpers.assert_eq(context.transport.status().queued, 0)
			helpers.assert_nil(completion,
				"the UDP callback must not run the timer-owned terminal continuation")
			context.state.clock = context.state.clock + 0.01
			context.state.pump()
			helpers.assert_not_nil(completion)
			helpers.assert_eq(completion.settled, true, tostring(completion.detail))
			helpers.assert_true(completion.clock < 102,
				"the maximum admitted queue must settle inside the two-second drain window")
			helpers.assert_eq(#context.state.delivered, 8192,
				"every ACKed batch record must reach the post-durability callback")
			local delivered_final = context.state.delivered[#context.state.delivered]
			helpers.assert_eq(delivered_final.line, final_line)
			helpers.assert_eq(delivered_final.notification.message, "maximum backlog drained",
				"a tail critical notification must not be starved behind ordinary traffic")
		end)
	end)

	helpers.it("fragments oversized UTF-8 records without losing ordered ownership", function()
		Fixture.with_fixture(function()
			local context = new_context()
			configure(context)
			local line = "2026-08-14 12:00:00:001 | INFO | test | LLM "
				.. string.rep("x", 7952) .. "é" .. string.rep("y", 8050)
			local retained, enqueue_err = context.transport.enqueue(line, "info")
			helpers.assert_not_nil(retained, tostring(enqueue_err))
			local fragment_count = 3
			helpers.assert_eq(context.transport.status().queued, 1,
				"one producer must consume one queue slot before timer-owned fragmentation")

			for sequence = 1, fragment_count do
				context.state.pump()
				local payload = context:payload()
				helpers.assert_eq(payload.sequence, sequence)
				helpers.assert_eq(payload.calendar_date, "2026-08-14")
				helpers.assert_contains(payload.line,
					"[fragment " .. tostring(sequence) .. "/" .. tostring(fragment_count) .. "]")
				local utf8_ok, utf8_length = pcall(utf8.len, payload.line)
				helpers.assert_true(utf8_ok and utf8_length ~= nil,
					"a byte boundary must never publish malformed UTF-8")
				helpers.assert_eq(payload.topics[1], "ErgoptiPlus_llm.log",
					"each fragment must route from the immutable original record")
				context:ack(sequence)
			end
			helpers.assert_eq(context.transport.status().queued, 0)
		end)
	end)

	helpers.it("routes a literal that crosses a timer-owned fragment boundary", function()
		Fixture.with_fixture(function()
			local context = new_context({ route_overlap_bytes = 2 })
			configure(context)
			local line = string.rep("x", 7999) .. "LLM" .. string.rep("y", 100)
			local retained, enqueue_err = context.transport.enqueue(line, "info")
			helpers.assert_not_nil(retained, tostring(enqueue_err))
			for sequence = 1, 2 do
				context.state.pump()
				local payload = context:payload()
				helpers.assert_eq(payload.sequence, sequence)
				helpers.assert_eq(payload.topics[1], "ErgoptiPlus_llm.log",
					"bounded routing windows must preserve a cross-boundary literal")
				context:ack(sequence)
			end
			helpers.assert_eq(context.transport.status().queued, 0)
		end)
	end)

	helpers.it("sanitizes malformed UTF-8 only off-HID and reuses the exact safe delivery", function()
		Fixture.with_fixture(function()
			local context = new_context()
			configure(context)
			local raw_encode = context.hs.json.encode
			local record_encode_calls = 0
			context.hs.json.encode = function(value)
				if type(value) == "table" and value.kind == "batch" then
					record_encode_calls = record_encode_calls + 1
					for _, record in ipairs(value.records or {}) do
						local valid, length = pcall(utf8.len, record.line)
						if not valid or length == nil then error("synthetic JSON UTF-8 refusal") end
					end
				end
				return raw_encode(value)
			end

			local raw_line = "2026-08-14 | INFO | test | été bad" .. string.char(255) .. "tail"
			local retained, enqueue_err = context.transport.enqueue(raw_line, "info")
			helpers.assert_not_nil(retained, tostring(enqueue_err))
			retained.notification = {
				module_name = "module" .. string.char(254),
				message = "détail" .. string.char(128),
			}
			helpers.assert_eq(record_encode_calls, 0,
				"enqueue/eventtap must not scan or encode malformed UTF-8")
			helpers.assert_eq(retained.line, raw_line,
				"the immutable producer record must retain its byte-exact source")

			context.state.pump()
			helpers.assert_eq(record_encode_calls, 1)
			local payload = context:payload()
			local safe_line = "2026-08-14 | INFO | test | été bad\\xFFtail"
			helpers.assert_eq(payload.line, safe_line,
				"the native sink must receive an ASCII escape for each invalid byte")
			local valid, length = pcall(utf8.len, payload.line)
			helpers.assert_true(valid and length ~= nil, "the persisted line must be valid UTF-8")

			context:ack(1)
			helpers.assert_eq(#context.state.delivered, 1)
			helpers.assert_eq(context.state.delivered[1].line, safe_line,
				"post-ACK console output must reuse the native worker's exact safe line")
			helpers.assert_eq(context.state.delivered[1].notification.module_name, "module\\xFE")
			helpers.assert_eq(context.state.delivered[1].notification.message, "détail\\x80")
			helpers.assert_eq(#context.state.failures, 0,
				"one malformed user-derived diagnostic must not fail the transport")
		end)
	end)

	helpers.it("bounds long invalid-continuation runs before escaped UDP encoding", function()
		Fixture.with_fixture(function()
			local context = new_context()
			configure(context)
			local line = string.rep("x", 8000) .. string.rep(string.char(128), 16000)
			local retained, enqueue_err = context.transport.enqueue(line, "warn")
			helpers.assert_not_nil(retained, tostring(enqueue_err))
			local fragment_count = 3
			helpers.assert_eq(context.transport.status().queued, 1,
				"an invalid continuation run remains one producer before the pump fragments it")

			for sequence = 1, fragment_count do
				context.state.pump()
				local sent = context.state.sends[#context.state.sends]
				helpers.assert_true(#sent.data < 60000,
					"escaped fragment must remain inside the authenticated UDP envelope")
				local payload = context:payload()
				local valid, length = pcall(utf8.len, payload.line)
				helpers.assert_true(valid and length ~= nil)
				context:ack(sequence)
			end
			helpers.assert_eq(context.transport.status().queued, 0)
			helpers.assert_eq(#context.state.failures, 0)
		end)
	end)
end)
