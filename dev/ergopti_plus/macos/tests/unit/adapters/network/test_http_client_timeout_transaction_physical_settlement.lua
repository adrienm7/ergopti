--- tests/unit/adapters/network/test_http_client_timeout_transaction_physical_settlement.lua

--- ==============================================================================
--- MODULE: HttpClient Timeout Transaction Regression Tests
--- DESCRIPTION:
--- Exercises the HttpClient timeout as one exact asynchronous capability. A
--- request must not reach the network unless its timeout timer committed, and a
--- timer whose rollback or terminal stop is uncertain must stay owned and block
--- every successor until that same capability is released.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.adapters.network.http_client_timeout_transaction_fixture"] = nil
local Fixture = require("tests.support.adapters.network.http_client_timeout_transaction_fixture")
local load_client = Fixture.load_client
local make_exact_stop_timer = Fixture.make_exact_stop_timer
local make_exact_task_http = Fixture.make_exact_task_http
local make_http_stub = Fixture.make_http_stub
local make_single_timer = Fixture.make_single_timer





helpers.describe("HTTP physical settlement migration admission", function()
	helpers.it("(http-migration-timer-debt) inactive business completion keeps exact native timer debt", function()
		local timer_stub, timer = make_exact_stop_timer("false")
		local http_stub, http = make_http_stub()
		local client = load_client(timer_stub, http_stub)
		helpers.assert_true(client.isSettled())
		client.post("http://localhost/fixture", {}, "{}", function() end)
		helpers.assert_eq(client.isSettled(), false)
		http.callbacks[1](200, "ok", {})
		helpers.assert_eq(client.isActive(), false)
		helpers.assert_eq(client.isSettled(), false)
		local attempts = timer.stop_calls
		helpers.assert_eq(client.isSettled(), false)
		helpers.assert_eq(timer.stop_calls, attempts, "settlement query never retries cleanup")
		timer.stop_mode = "success"
		helpers.assert_true(client.cancel())
		helpers.assert_true(client.isSettled())
	end)

	helpers.it("(http-migration-task-debt) cancel acceptance cannot replace the native owner join", function()
		local timer_stub = make_exact_stop_timer("success")
		local http_stub, http = make_exact_task_http("false")
		local client = load_client(timer_stub, http_stub)
		client.post("http://localhost/fixture", {}, "{}", function() end)
		helpers.assert_eq(client.cancel(), false)
		helpers.assert_eq(client.isActive(), false)
		helpers.assert_eq(client.isSettled(), false)
		http.cancel_mode = "success"
		helpers.assert_true(client.cancel())
		helpers.assert_true(client.isSettled())
	end)
end)

helpers.describe("Native HTTP infrastructure receipts (local-configured-native-owner)", function()
	for _, kind in ipairs({ "false", "throw" }) do
		helpers.it("marks native dispatch " .. kind .. " without classifying ordinary network failure (local-configured-native-owner)", function()
			local timers = make_single_timer("success")
			local client = load_client(timers, { doAsyncRequest = function()
				if kind == "throw" then error("native fixture dispatch refusal") end
				return false
			end }, { follow_redirects = false })
			local receipt, deliveries = nil, 0
			helpers.assert_eq(client.get("http://127.0.0.1:19423/v1/models", {}, function(response)
				receipt = response; deliveries = deliveries + 1
			end), false)
			helpers.assert_eq(deliveries, 1)
			helpers.assert_eq(receipt.ok, false); helpers.assert_eq(receipt.status, 0)
			helpers.assert_eq(receipt.error_kind, "native_dispatch")
			helpers.assert_eq(client.isSettled(), true, "typed failure retains the exact existing timeout retirement")
		end)
	end
end)
