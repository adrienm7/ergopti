--- tests/unit/modules/keylogger/test_physical_transport_callback_failure.lua

do
--- tests/unit/modules/keylogger/test_transport_error_object_proof.lua

--- Actual Capture/Delivery/Transport callback failures with explicit native task models.
local helpers = require("tests.helpers")
local with_capture = require("tests.support.physical_capture_fixture").run

local function batch(sequence, usage)
	return { version = 1, kind = "batch", coverage = "complete", incarnation = "production-fixture", lease = "7",
		records = { { sequence = tostring(sequence), device = "41", timestamp = tostring(sequence * 10),
			has_page = true, has_usage = true, page = 7, usage = usage, value = "1", has_cookie = true, cookie = usage } } }
end

helpers.describe("actual physical callback failure revocation", function()
	for _, kind in ipairs({ "text", "typed_loss", "throwing_tostring" }) do
		helpers.it("retires actual transport and reports " .. kind .. " failure", function()
			with_capture(function(capture, observed, c)
				local owner, scope, scope_token = {}, nil, nil
				local source, source_token, verdicts = nil, nil, {}
				local formatter_error = {}
				local callback_error = setmetatable({}, { __tostring = function() error(formatter_error, 0) end })
				local original_emit, emissions = c.dependencies.emit, 0
				c.dependencies.emit = function(press)
					emissions = emissions + 1
					if emissions == 2 then error(kind == "text" and "actual sink callback failure" or callback_error, 0) end
					return original_emit(press)
				end
				c.dependencies.on_verdict = function(record) verdicts[#verdicts + 1] = record; return true end
				local original_clock = c.dependencies.clock_ready
				c.dependencies.clock_ready = function(...)
					local bound
					bound, scope = capture.bind_history_scope(owner)
					if bound then scope_token = scope.identity() end
					return original_clock(...)
				end
				helpers.assert_eq(capture.init(c.dependencies), true)
				source = assert(capture.bind_managed_source(owner)); source_token = source.identity(owner)
				helpers.assert_eq(source.start(owner, source_token, c.options), true)
				c.verified(); c.open()
				helpers.assert_eq(type(scope), "table")
				helpers.assert_eq(type(scope.admitted(scope_token)), "string")
				c.frames.first, c.frames.second = batch(1, 44), batch(2, 41)
				observed.tasks[3].chunk(nil, "first\n")
				helpers.assert_eq(#observed.credits, 1)
				helpers.assert_eq(#observed.writes, 3)
				helpers.assert_eq(c.mode.credit_source(), "stream")
				if kind == "typed_loss" then
					c.frames.loss = { version = 1, kind = "lost", coverage = "complete", incarnation = "production-fixture", lease = "7", reason = "overflow" }
				end
				local ok, failure = pcall(observed.tasks[3].chunk, nil, kind == "typed_loss" and "loss\n" or "second\n")
				local before = { native_stops = observed.tasks[3].stops, native_state = observed.tasks[3].state,
					verdicts = #verdicts, capture_state = capture.status().state, credit_source = c.mode.credit_source(),
					admitted = scope.admitted(scope_token), credits = #observed.credits, writes = #observed.writes,
					raised_formatter = rawequal(failure, formatter_error), source_current = source.current(owner, source_token) }
				local successor, successor_token = source.start(owner, source_token, c.options)
				helpers.assert_eq(successor, false)
				helpers.assert_eq(successor_token, nil)
				helpers.assert_eq(#observed.spawns, 3)
				helpers.assert_eq(before.admitted, nil, "actual receiver revocation prevents any retained admission")
				helpers.assert_eq(before.credits, 1)
				helpers.assert_eq(before.writes, 3, "failed publication must never ACK its partial sequence")
				-- Clean up through genuine owned APIs after retaining the before facts.
				source.stop_lease(owner, source_token)
				observed.tasks[3].settle()
				helpers.assert_eq(scope.settled(scope_token), true)
				helpers.assert_eq(scope.release(owner, scope_token), true)
				helpers.assert_eq(source.shutdown(owner, source_token), true)
				if kind == "throwing_tostring" then
					helpers.assert_eq(ok, false)
					helpers.assert_eq(before.raised_formatter, true)
				end
				local facts_path = os.getenv("TRANSPORT_ERROR_PROOF_FACTS")
				local evidence = facts_path and io.open(facts_path, "a")
				if evidence then
					evidence:write(kind, " stops=", tostring(before.native_stops), " verdicts=", tostring(before.verdicts),
						" mode=", before.credit_source, " state=", tostring(before.capture_state),
						" admitted=", tostring(before.admitted), " source_current=", tostring(before.source_current), "\n")
					evidence:close()
				end
				helpers.assert_true(before.native_stops >= 1, "actual callback failure must request native transport retirement before diagnostics")
				helpers.assert_eq(before.verdicts, 1, "actual production on_error path must publish its captured verdict")
				helpers.assert_eq(before.credit_source, "gap")
			end)
		end)
	end
end)

end

local helpers = require("tests.helpers")
local Transport = require("modules.keylogger.physical_transport")
local Delivery = require("modules.keylogger.physical_delivery")
local Frames = require("tests.support.physical_stream_frames")
local Protocol = require("modules.keylogger.physical_protocol")

local function direct_fixture(options)
	options = options or {}
	local facts = { errors = 0, receipts = 0, writes = 0, credits = 0, stops = 0, emits = 0 }
	local frames = Frames.new("failure-callback-fixture", "7", { "41" })
	local receiver, stream, native_settle, transport
	local formatter_marker, stop_marker = {}, {}
	local reason = options.text or "physical callback text failure"
	if options.bad_formatter then
		reason = setmetatable({}, { __tostring = function()
			facts.format_stops, facts.format_active = facts.stops, receiver.active()
			error(formatter_marker, 0)
		end })
	end
	receiver = Delivery.new({ batch_limit = 8, keycode = Frames.keycode,
		admit = function() return "explicit-delivery-fixture" end,
		context = function() return { allowed = true, app = "Fixture", timestamp = "2026-10-06 12:00:00.000" } end,
		emit = function()
			facts.emits = facts.emits + 1
			if facts.emits == 2 then error(reason, 0) end
			facts.credits = facts.credits + 1
			return true
		end,
	})
	transport = Transport.new({ receiver = receiver, frame_limit = 32,
		decode = function(line) return frames[line] end,
		encode = function(record) return record.baseline_ack or record.ack end,
		on_error = function(message, original)
			facts.errors = facts.errors + 1
			facts.message, facts.original = message, original
			facts.error_retired = transport.isSettled()
			if options.settle_in_error then native_settle() end
			facts.after_error_settlement = transport.isSettled()
			facts.error_receipts = facts.receipts
			if options.settle_in_error then facts.error_stop, facts.error_status = transport.stop() end
		end,
		on_settled = function() facts.receipts = facts.receipts + 1 end,
		spawn = function(_, _, _, chunk)
			stream = chunk
			return { start = function() return true end,
				onSettled = function(callback) native_settle = callback; return true end,
				terminate = function()
					facts.stops = facts.stops + 1
					if options.stop_throws then error(stop_marker, 0) end
					if options.stop_refuses then return false, "pending" end
					return true, "pending"
				end,
				set_input = function() facts.writes = facts.writes + 1; return true end }
		end,
	})
	assert(transport.start("/owned/software/fixture", {}) == true)
	stream(nil, "opened\npage\nready\n")
	local function batch(sequence, usage)
		return { version = 1, kind = "batch", coverage = "fixture_only", incarnation = "failure-callback-fixture", lease = "7",
			records = { { sequence = tostring(sequence), device = "41", timestamp = tostring(sequence * 10),
				has_page = true, has_usage = true, page = 7, usage = usage, value = "1", has_cookie = true, cookie = usage } } }
	end
	frames.first, frames.second = batch(1, 44), batch(2, 41)
	stream(nil, "first\n")
	facts.transport, facts.receiver = transport, receiver
	facts.formatter_marker, facts.stop_marker, facts.reason = formatter_marker, stop_marker, reason
	facts.options = options
	function facts.fail()
		if options.loss then
			frames.loss = { version = 1, kind = "lost", coverage = "fixture_only", incarnation = "failure-callback-fixture", lease = "7", reason = "overflow" }
		end
		return pcall(stream, nil, options.loss and "loss\n" or "second\n")
	end
	function facts.settle() native_settle() end
	return facts
end

helpers.describe("physical failure diagnostic ownership", function()
	helpers.it("retains original callback error and retires before its throwing formatter", function()
		local f = direct_fixture({ bad_formatter = true })
		helpers.assert_eq(f.credits, 1); helpers.assert_eq(f.writes, 3)
		local ok, raised = f.fail()
		helpers.assert_eq(ok, false)
		helpers.assert_true(rawequal(raised, f.formatter_marker))
		helpers.assert_eq(f.format_stops, 1, "native retirement is attempted before arbitrary diagnostic code")
		helpers.assert_eq(f.format_active, false)
		helpers.assert_eq(f.errors, 1)
		helpers.assert_true(rawequal(f.original, f.reason), "on_error retains original callback object without diagnostic replacement")
		helpers.assert_eq(f.message, "Physical callback diagnostic unavailable")
		helpers.assert_eq(f.receiver.active(), false)
		helpers.assert_eq(f.transport.isSettled(), false)
		helpers.assert_eq(f.receipts, 0)
		helpers.assert_eq(f.credits, 1); helpers.assert_eq(f.writes, 3)
		f.settle(); helpers.assert_eq(f.transport.isSettled(), true); helpers.assert_eq(f.receipts, 1)
	end)

	helpers.it("keeps a refused native termination as real debt despite formatter failure", function()
		local f = direct_fixture({ bad_formatter = true, stop_refuses = true })
		local ok, raised = f.fail()
		helpers.assert_eq(ok, false); helpers.assert_true(rawequal(raised, f.formatter_marker))
		helpers.assert_eq(f.stops, 1); helpers.assert_eq(f.errors, 1)
		helpers.assert_true(rawequal(f.original, f.reason))
		helpers.assert_eq(f.receiver.active(), false); helpers.assert_eq(f.transport.isSettled(), false)
		helpers.assert_eq(f.receipts, 0)
		local stopped, status = f.transport.stop()
		helpers.assert_eq(stopped, false); helpers.assert_eq(status, "pending")
		helpers.assert_eq(f.transport.isSettled(), false)
		f.settle(); helpers.assert_eq(f.transport.isSettled(), true); helpers.assert_eq(f.receipts, 1)
	end)

	helpers.it("publishes original error despite a thrown native stop and preserves that debt", function()
		local f = direct_fixture({ stop_throws = true })
		local ok, raised = f.fail()
		helpers.assert_eq(ok, false); helpers.assert_true(rawequal(raised, f.stop_marker))
		helpers.assert_eq(f.errors, 1); helpers.assert_eq(f.original, f.reason)
		helpers.assert_eq(f.message, "physical callback text failure")
		helpers.assert_eq(f.receiver.active(), false); helpers.assert_eq(f.transport.isSettled(), false)
		helpers.assert_eq(f.receipts, 0)
		f.options.stop_throws = false
		local stopped, status = f.transport.stop()
		helpers.assert_eq(stopped, true); helpers.assert_eq(status, "pending")
		helpers.assert_eq(f.transport.isSettled(), false)
		f.settle(); helpers.assert_eq(f.transport.isSettled(), true); helpers.assert_eq(f.receipts, 1)
	end)

	helpers.it("retains real observer frame when native completion occurs before formatter exception escapes", function()
		local f = direct_fixture({ bad_formatter = true, settle_in_error = true })
		local ok, raised = f.fail()
		helpers.assert_eq(ok, false); helpers.assert_true(rawequal(raised, f.formatter_marker))
		helpers.assert_eq(f.errors, 1)
		helpers.assert_eq(f.error_retired, false); helpers.assert_eq(f.after_error_settlement, false)
		helpers.assert_eq(f.error_receipts, 0)
		helpers.assert_eq(f.error_stop, false); helpers.assert_eq(f.error_status, "pending")
		helpers.assert_eq(f.transport.isSettled(), true); helpers.assert_eq(f.receipts, 1)
	end)

	helpers.it("preserves healthy text and typed-loss wording and raw classification", function()
		for _, loss in ipairs({ false, true }) do
			local f = direct_fixture({ loss = loss })
			local ok = f.fail()
			helpers.assert_eq(ok, true); helpers.assert_eq(f.errors, 1)
			helpers.assert_eq(f.stops, 1); helpers.assert_eq(f.transport.isSettled(), false)
			if loss then
				helpers.assert_eq(f.message, "Physical stream lost: overflow")
				helpers.assert_eq(Protocol.is_loss(f.original), true)
				helpers.assert_eq(f.original.reason, "overflow")
			else
				helpers.assert_eq(f.message, "physical callback text failure")
				helpers.assert_eq(f.original, f.reason)
			end
			f.settle(); helpers.assert_eq(f.receipts, 1)
		end
	end)
end)
