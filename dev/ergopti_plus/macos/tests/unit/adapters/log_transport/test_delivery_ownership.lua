--- tests/unit/adapters/log_transport/test_delivery_ownership.lua

--- ==============================================================================
--- MODULE: Log Transport Delivery Ownership Tests
--- DESCRIPTION:
--- Keeps acknowledged and rejected notifications owned until callbacks settle.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.log_transport_fixture")

--- Reaches the real admission ceiling and retains one rejected error fallback.
--- @param context table Real transport fixture.
--- @return number admitted
local function fill_until_rejected(context)
	for index = 1, 10000 do
		local record, _, fallback = context.transport.enqueue("retained-" .. index, "error")
		if record == nil then
			helpers.assert_not_nil(fallback)
			helpers.assert_true(index > 1, "admit real records before testing overflow")
			return index - 1
		end
	end
	error("the bounded admission refusal was not reached")
end

helpers.describe("Log transport delivery ownership", function()
	helpers.it("(transport-delivery-lease) refuses teardown until the whole ACK batch is delivered", function()
		Fixture.with_fixture(function()
			local context = Fixture.new_context({ batch_records = 2 })
			local original, successor = {}, {}
			local stopped, restarted
			context.options.on_delivered = function(record)
				original[#original + 1] = record.line
				if #original == 1 then
					stopped = context.transport.stop()
					if stopped then
						context.options.session = "successor-delivery-session"
						context.options.on_delivered = function(next_record)
							successor[#successor + 1] = next_record.line
							return true
						end
						restarted = context:start()
					end
				end
				return true
			end
			Fixture.configure(context)
			helpers.assert_not_nil(context.transport.enqueue("old1", "info"))
			helpers.assert_not_nil(context.transport.enqueue("old2", "info"))
			context.state.pump()
			helpers.assert_eq(#context:batch().records, 2)
			context:ack(2)
			helpers.assert_eq(stopped, false, "delivery still owns the transport after dequeuing its batch")
			helpers.assert_nil(restarted)
			helpers.assert_eq(#original, 2)
			helpers.assert_eq(original[1], "old1")
			helpers.assert_eq(original[2], "old2")
			helpers.assert_eq(#successor, 0)
			helpers.assert_eq(context.state.cancel_calls, 0)
			helpers.assert_eq(context.state.close_calls, 0)
			helpers.assert_contains(context.transport.status().last_error, "delivery")
			helpers.assert_eq(context.transport.stop(), true, "settled notifications release teardown ownership")
		end)
	end)

	helpers.it("(transport-delivery-lease) postpones a recursive expired drain until delivery settles", function()
		Fixture.with_fixture(function()
			local context = Fixture.new_context({ batch_records = 2 })
			local delivered, drained, observed_inside = {}, {}, nil
			local drain_accepted
			context.options.on_delivered = function(record)
				delivered[#delivered + 1] = record.line
				if #delivered == 1 then
					drain_accepted = context.transport.drain(function(settled)
						drained[#drained + 1] = { settled = settled, deliveries = #delivered }
					end, 1)
					context.state.clock = context.state.clock + 2
					context.state.pump()
					observed_inside = #drained
				end
				return true
			end
			Fixture.configure(context)
			helpers.assert_not_nil(context.transport.enqueue("first", "info"))
			helpers.assert_not_nil(context.transport.enqueue("second", "info"))
			context.state.pump()
			context:ack(2)
			helpers.assert_eq(drain_accepted, true)
			helpers.assert_eq(observed_inside, 0, "a delivery callback cannot recursively settle its own drain")
			helpers.assert_eq(#delivered, 2)
			helpers.assert_eq(#drained, 0)
			context.state.pump()
			helpers.assert_eq(#drained, 1)
			helpers.assert_eq(drained[1].settled, true)
			helpers.assert_eq(drained[1].deliveries, 2)
			helpers.assert_eq(context.transport.stop(), true)
		end)
	end)

	for _, failure in ipairs({ "throw", "refuse", "format_throw", "error_object" }) do
		helpers.it("(transport-delivery-lease) finishes remaining deliveries after " .. failure, function()
			Fixture.with_fixture(function()
				local context = Fixture.new_context({ batch_records = 2 })
				local delivered = {}
				context.options.on_delivered = function(record)
					delivered[#delivered + 1] = record.line
					if #delivered == 1 then
						if failure == "throw" then error("delivery failure marker") end
						if failure == "error_object" then
							error(setmetatable({}, { __tostring = function()
								error("unprintable delivery object")
							end }), 0)
						end
						if failure == "format_throw" then
							return false, setmetatable({}, { __tostring = function()
								error("delivery failure marker")
							end })
						end
						return false, "delivery failure marker"
					end
					return true
				end
				Fixture.configure(context)
				helpers.assert_not_nil(context.transport.enqueue("first", "info"))
				helpers.assert_not_nil(context.transport.enqueue("second", "info"))
				context.state.pump()
				context:ack(2)
				helpers.assert_eq(#delivered, 2, "one callback failure must not discard later ACK notifications")
				helpers.assert_eq(delivered[2], "second")
				helpers.assert_eq(context.transport.status().queued, 0)
				local expected_error = failure == "error_object" and "unprintable callback error" or "delivery failure marker"
				helpers.assert_contains(context.transport.status().last_error, expected_error)
				context.state.pump()
				helpers.assert_eq(#context.state.failures, 1)
				helpers.assert_eq(context.transport.stop(), true)
			end)
		end)
	end

	helpers.it("(transport-delivery-lease) prevents a rejected-record callback from recursively pumping", function()
		Fixture.with_fixture(function()
			local context = Fixture.new_context({ batch_records = 64 })
			local rejected, nested_sends = 0, nil
			context.options.on_rejected = function()
				rejected = rejected + 1
				local sent_before = #context.state.sends
				context.state.pump()
				nested_sends = #context.state.sends - sent_before
				return true
			end
			Fixture.configure(context)
			local admitted = fill_until_rejected(context)
			context.state.pump()
			helpers.assert_eq(rejected, 1)
			helpers.assert_eq(nested_sends, 0, "rejected delivery owns the outer pump until it returns")
			for _ = 1, admitted do
				local sequence = context.transport.status().inflight_sequence
				if sequence then context:ack(sequence) end
				if context.transport.status().queued == 0 then break end
				context.state.pump()
			end
			helpers.assert_eq(context.transport.status().queued, 0)
			helpers.assert_eq(#context.state.delivered, admitted)
			helpers.assert_eq(context.transport.stop(), true)
		end)
	end)

	helpers.it("(transport-delivery-lease) retains the outer owner through a nested ACK delivery", function()
		Fixture.with_fixture(function()
			local context = Fixture.new_context({ batch_records = 64 })
			local rejected, delivered_inside, active_after_ack, stopped_inside = 0, nil, nil, nil
			context.options.on_rejected = function()
				rejected = rejected + 1
				if rejected == 2 then
					context:ack(context.transport.status().inflight_sequence)
					delivered_inside = #context.state.delivered
					active_after_ack = context.transport.status().delivery_active
					stopped_inside = context.transport.stop()
				end
				return true
			end
			Fixture.configure(context)
			local admitted = fill_until_rejected(context)
			context.state.pump()
			local batch_size = #context:batch().records
			helpers.assert_true(batch_size > 0)
			local record, _, fallback = context.transport.enqueue("second-rejection", "error")
			helpers.assert_nil(record)
			helpers.assert_not_nil(fallback)
			context.state.pump()
			helpers.assert_eq(rejected, 2)
			helpers.assert_eq(delivered_inside, batch_size, "a nested ACK must deliver its retired records")
			helpers.assert_eq(active_after_ack, true, "the nested delivery must not release its outer owner")
			helpers.assert_eq(stopped_inside, false)
			helpers.assert_eq(context.state.cancel_calls, 0)
			helpers.assert_eq(context.state.close_calls, 0)
			helpers.assert_eq(context.transport.status().delivery_active, false)
			for _ = 1, admitted do
				local sequence = context.transport.status().inflight_sequence
				if sequence then context:ack(sequence) end
				if context.transport.status().queued == 0 then break end
				context.state.pump()
			end
			helpers.assert_eq(context.transport.status().queued, 0)
			helpers.assert_eq(#context.state.delivered, admitted)
			helpers.assert_eq(context.transport.stop(), true)
		end)
	end)
end)
