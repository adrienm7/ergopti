--- tests/unit/adapters/test_public_cancelled_boolean_successor.lua

--- ==============================================================================
--- MODULE: Public Cancelled Boolean Successor Boundary Controls
--- DESCRIPTION:
--- Actual public/native engine imports use independent physical ACK ports.
--- Accepted operation.started does not acknowledge successor child acquisition.
--- ==============================================================================

local helpers = require("tests.helpers")
local Ports = require("tests.support.managed_http_native_ports")
local URL = "http://127.0.0.1:9000/fixed"
local function options() return { owner = "public-cancelled-boolean", timeout_ms = 1000 } end
local WIRE = "fixed body\nERGOPTI_HTTP_STATUS:200\n"

helpers.describe("public positive cancelled BOOLEAN successor", function()
	helpers.it("preserves accepted successor.started while the exact old child and timer still own debt", function()
		local client, state = Ports.fresh_client({ defer_close = true, defer_deadline_index = 1 })
		local old, current, conversions = nil, nil, 0
		helpers.assert_true(client.get(URL, {}, options(), function(result) old = result end))
		helpers.assert_true(client.cancel("public-cancelled-boolean"))
		local header = setmetatable({}, { __tostring = function() conversions = conversions + 1; return "fixed successor" end })
		local successor = client.get_owned(URL, { ["X-Fixed"] = header }, options(), function(result) current = result end)
		helpers.assert_true(successor.started)
		helpers.assert_eq(conversions, 1)
		helpers.assert_eq(#state.requests, 1)
		state.complete_request(1, "", 143)
		helpers.assert_eq(#state.requests, 1)
		state.ack_closes()
		helpers.assert_eq(#state.requests, 1, "old managed deadline close ACK is still withheld")
		helpers.assert_eq(successor:is_settled(), false)
		state.deadlines[1].ack()
		helpers.assert_eq(#state.requests, 2)
		helpers.assert_eq(current, nil)
		state.complete_request(2, WIRE); state.ack_closes()
		helpers.assert_true(successor:is_settled())
		helpers.assert_true(current.ok)
		helpers.assert_eq(old, nil)
		helpers.assert_eq(conversions, 1)
	end)
	helpers.it("keeps an owned predecessor cleanup refusal before public header conversion", function()
		local client, state = Ports.fresh_client({ defer_close = true })
		local predecessor = client.get_owned(URL, {}, options(), function() end)
		helpers.assert_true(client.cancel("public-cancelled-boolean"))
		local conversions, result = 0, nil
		local header = setmetatable({}, { __tostring = function() conversions = conversions + 1; error("must not convert owned debt") end })
		local refused = client.get_owned(URL, { ["X-Fixed"] = header }, options(), function(value) result = value end)
		helpers.assert_eq(refused.started, false)
		helpers.assert_true(refused:is_settled())
		helpers.assert_eq(result.error, "previous request cleanup pending")
		helpers.assert_eq(conversions, 0)
		helpers.assert_eq(#state.requests, 1)
		state.complete_request(1, "", 143); state.ack_closes()
		helpers.assert_true(predecessor:is_settled())
	end)
end)
