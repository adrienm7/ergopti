--- tests/unit/adapters/test_managed_prepared_queue.lua

--- ==============================================================================
--- MODULE: Public Managed HTTP Prepared Replacement Controls
--- DESCRIPTION:
--- Uses the actual public wrapper, native engine and shared policy with explicit
--- native process/handle/group acknowledgements. These are models, not OS proof.
--- ==============================================================================

local helpers = require("tests.helpers")
local Ports = require("tests.support.managed_http_native_ports")
local url = "http://127.0.0.1:9000/fixed"
local function options() return { owner = "prepared-owner", timeout_ms = 1000 } end
local wire = "fixed body\nERGOPTI_HTTP_STATUS:200\n"

helpers.describe("public immutable preparation and owned replacement", function()
	helpers.it("converts an admitted header once across real preflight and dispatch", function()
		local client, state = Ports.fresh_client()
		local conversions = 0
		local value = setmetatable({}, { __tostring = function() conversions = conversions + 1; return "fixed value" end })
		local result
		local operation = client.get_owned(url, { ["X-Fixed"] = value }, options(), function(r) result = r end)
		helpers.assert_true(operation.started)
		helpers.assert_eq(conversions, 1)
		helpers.assert_true(state.config:find('header = "X-Fixed: fixed value"', 1, true) ~= nil)
		state.complete_request(1, wire)
		helpers.assert_true(operation:is_settled())
		helpers.assert_true(result.ok)
		helpers.assert_eq(conversions, 1)
	end)
	helpers.it("publishes an initial malformed-header refusal without native allocation", function()
		local client, state = Ports.fresh_client()
		local result, callbacks = nil, 0
		local operation = client.get_owned(url, { ["X-Fixed"] = setmetatable({}, { __tostring = function() error("fixed metadata refusal") end }) }, options(), function(r) result, callbacks = r, callbacks + 1 end)
		helpers.assert_eq(operation.started, false)
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(#state.requests + #state.handles + #state.deadlines, 0)
		helpers.assert_eq(callbacks, 1)
		helpers.assert_eq(result.ok, false)
	end)
	helpers.it("queues a once-prepared owned replacement until every old close ACK", function()
		local client, state = Ports.fresh_client({ defer_close = true })
		local old, current, conversions = nil, nil, 0
		helpers.assert_true(client.get(url, {}, options(), function(r) old = r end))
		local header = setmetatable({}, { __tostring = function() conversions = conversions + 1; return "fixed successor" end })
		local operation = client.get_owned(url, { ["X-Fixed"] = header }, options(), function(r) current = r end)
		helpers.assert_true(operation.started)
		helpers.assert_eq(conversions, 1)
		helpers.assert_eq(#state.requests, 1)
		helpers.assert_eq(operation:is_settled(), false)
		state.complete_request(1, "", 143)
		helpers.assert_eq(#state.requests, 1)
		helpers.assert_eq(current, nil)
		state.ack_closes()
		helpers.assert_eq(#state.requests, 2)
		helpers.assert_true(state.config:find('header = "X-Fixed: fixed successor"', 1, true) ~= nil)
		helpers.assert_eq(conversions, 1)
		state.complete_request(2, wire)
		helpers.assert_eq(current, nil)
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_true(current.ok)
		helpers.assert_eq(old, nil)
	end)
	helpers.it("leaves a valid boolean incumbent running after invalid owned preparation", function()
		local client, state = Ports.fresh_client()
		helpers.assert_true(client.get(url, {}, options(), function() end))
		local kills, result = #state.kills, nil
		local refused = client.get_owned(url, { ["X-Fixed"] = "invalid\0value" }, options(), function(r) result = r end)
		helpers.assert_eq(refused.started, false)
		helpers.assert_true(refused:is_settled())
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(#state.requests, 1)
		helpers.assert_eq(#state.kills, kills)
		helpers.assert_true(client.isActive("prepared-owner"))
		state.complete_request(1, wire)
	end)
	helpers.it("refuses owned incumbent metadata without evaluating it", function()
		local client, state = Ports.fresh_client()
		local incumbent = client.get_owned(url, {}, options(), function() end)
		local conversions, result = 0, nil
		local header = setmetatable({}, { __tostring = function() conversions = conversions + 1; error("must not convert") end })
		local refused = client.get_owned(url, { ["X-Fixed"] = header }, options(), function(r) result = r end)
		helpers.assert_eq(refused.started, false)
		helpers.assert_true(refused:is_settled())
		helpers.assert_eq(result.error, "previous request cleanup pending")
		helpers.assert_eq(conversions, 0)
		helpers.assert_true(client.isActive("prepared-owner"))
		state.complete_request(1, wire)
		helpers.assert_true(incumbent:is_settled())
	end)
	helpers.it("does not dispatch a cancelled queued successor after predecessor retirement", function()
		local client, state = Ports.fresh_client({ defer_close = true })
		helpers.assert_true(client.get(url, {}, options(), function() end))
		local callbacks = 0
		local successor = client.get_owned(url, {}, options(), function() callbacks = callbacks + 1 end)
		helpers.assert_true(successor.started)
		helpers.assert_eq(successor:cancel(), false)
		state.complete_request(1, "", 143)
		state.ack_closes()
		helpers.assert_true(successor:is_settled())
		helpers.assert_eq(#state.requests, 1)
		helpers.assert_eq(callbacks, 0)
	end)
	helpers.it("expires a queued owned replacement without acquiring a successor child", function()
		local client, state = Ports.fresh_client({ defer_close = true })
		helpers.assert_true(client.get(url, {}, options(), function() end))
		local result
		local successor = client.get_owned(url, {}, { owner = "prepared-owner", timeout_ms = 10 }, function(r) result = r end)
		helpers.assert_true(successor.started)
		state.time = 11
		state.fire_deadlines()
		helpers.assert_eq(result, nil)
		helpers.assert_eq(successor:is_settled(), false)
		helpers.assert_eq(#state.requests, 1)
		state.complete_request(1, "", 143)
		state.ack_closes()
		helpers.assert_true(successor:is_settled())
		helpers.assert_eq(result.error, "timeout")
		helpers.assert_eq(#state.requests, 1)
	end)
	helpers.it("failed successor timer arming does not cancel the valid incumbent", function()
		local client, state = Ports.fresh_client({ refuse_deadline_arm_index = 2, defer_deadline_index = 2 })
		helpers.assert_true(client.get(url, {}, options(), function() end))
		local kills, result = #state.kills, nil
		local successor = client.get_owned(url, {}, options(), function(r) result = r end)
		helpers.assert_eq(successor.started, false)
		helpers.assert_eq(successor:is_settled(), false)
		helpers.assert_eq(result, nil)
		helpers.assert_eq(#state.kills, kills)
		state.deadlines[2].ack()
		helpers.assert_true(successor:is_settled())
		helpers.assert_eq(result.error, "managed-http-deadline-unavailable")
		helpers.assert_true(client.isActive("prepared-owner"))
		state.complete_request(1, wire)
	end)
	helpers.it("cancellation during header conversion cannot acquire a successor child", function()
		local client, state = Ports.fresh_client({ defer_close = true })
		helpers.assert_true(client.get(url, {}, options(), function() end))
		local calls = 0
		local header = setmetatable({}, { __tostring = function() calls = calls + 1; client.cancel("prepared-owner"); return "fixed" end })
		local callbacks = 0
		local successor = client.get_owned(url, { ["X-Fixed"] = header }, options(), function() callbacks = callbacks + 1 end)
		helpers.assert_eq(calls, 1)
		helpers.assert_eq(callbacks, 0)
		helpers.assert_eq(successor.started, false)
		helpers.assert_eq(#state.requests, 1)
		state.complete_request(1, "", 143)
		state.ack_closes()
		helpers.assert_true(successor:is_settled())
		helpers.assert_eq(#state.requests, 1)
		helpers.assert_eq(callbacks, 0)
	end)
end)

-- Independent compatibility cases execute actual wrapper/core/shared policy
-- under the existing explicit native process/pipe/group acknowledgement ports.
local function hop_receipt(state, index, status, effective, target, body)
	local request = assert(state.requests[index])
	local packet = string.format('{"http_code":%d,"response_code":%d,"exitcode":0,"num_redirects":0,"url_effective":"%s","redirect_url":"%s"}',
		status, status, effective, target)
	request.options.stdio[3].read_callback(nil, "\nERGOPTI_GET_REDIRECT_JSON:\n" .. effective .. "\n" .. target .. "\n" .. packet .. "\n\nERGOPTI_PROXY_STATUS:000:?\n")
	state.complete_request(index, (body or "") .. "\nERGOPTI_HTTP_STATUS:" .. status .. "\n")
end
local initial = "https://127.0.0.1:9000/start"
local next_origin = "https://127.0.0.1:9001/final"
local downgrade = "http://127.0.0.1:9001/final"

helpers.describe("preserved legacy and explicit owned redirect admission", function()
	helpers.it("legacy boolean sensitive GET retains its original302 without another child", function()
		local client, state = Ports.fresh_client()
		local result, calls = nil, 0
		assert(client.get(initial, { ["X-Api-Key"] = "fixed-secret" },
			{ owner = "legacy-sensitive", timeout_ms = 1000, follow_redirects = true },
			function(value) result = value; calls = calls + 1 end))
		state.complete_request(1, "\nERGOPTI_HTTP_STATUS:302\n")
		assert(#state.requests == 1 and calls == 1 and result.status == 302 and result.error == "HTTP 302")
		assert(not client.isActive("legacy-sensitive"))
	end)
	helpers.it("legacy owned empty Authorization retains302 and physical settlement", function()
		local client, state = Ports.fresh_client()
		local result
		local operation = client.get_owned(initial, { Authorization = "" },
			{ owner = "legacy-owned", timeout_ms = 1000, follow_redirects = true }, function(value) result = value end)
		assert(operation.started)
		state.complete_request(1, "\nERGOPTI_HTTP_STATUS:302\n")
		assert(#state.requests == 1 and operation:is_settled() and result.status == 302 and result.error == "HTTP 302")
	end)
	helpers.it("explicit owned managed GET strips credentials and follows after exact old ACK", function()
		local client, state = Ports.fresh_client()
		local result, calls = nil, 0
		local request_options = { owner = "explicit-managed", timeout_ms = 1000, follow_redirects = true, managed_redirects = true }
		local operation = client.get_owned(initial, { Authorization = "fixed-secret", ["X-Api-Key"] = "fixed-secret", Accept = "application/json" },
			request_options, function(value) result = value; calls = calls + 1 end)
		assert(operation.started and state.config:find("fixed-secret", 1, true))
		request_options.managed_redirects = false -- Captured initial ownership cannot be withdrawn/borrowed by this mutation.
		hop_receipt(state, 1, 302, initial, next_origin, "intermediate")
		assert(#state.requests == 2 and calls == 0 and not operation:is_settled())
		assert(not state.config:find("fixed-secret", 1, true) and state.config:find("application/json", 1, true))
		hop_receipt(state, 2, 200, next_origin, "", "final")
		assert(operation:is_settled() and calls == 1 and result.status == 200 and result.body == "final")
		assert(result.redirect_receipt == nil)
	end)
	helpers.it("changing old caller options cannot opt a legacy operation into managed hops", function()
		local client, state = Ports.fresh_client()
		local result
		local request_options = { owner = "immutable-legacy", timeout_ms = 1000, follow_redirects = true, managed_redirects = false }
		local operation = client.get_owned(initial, { Authorization = "fixed-secret" }, request_options, function(value) result = value end)
		request_options.managed_redirects = true
		state.complete_request(1, "\nERGOPTI_HTTP_STATUS:302\n")
		assert(#state.requests == 1 and operation:is_settled() and result.status == 302)
	end)
	helpers.it("managed opt in on the boolean port refuses before transport", function()
		local client, state = Ports.fresh_client()
		local result
		assert(client.get(initial, {}, { owner = "wrong-boolean", timeout_ms = 1000, follow_redirects = true, managed_redirects = true },
			function(value) result = value end) == false)
		assert(#state.requests == 0 and #state.handles == 0 and result.status == 0 and result.ok == false)
	end)
	helpers.it("truthy non Boolean redirect flags refuse without transport", function()
		for _, flag in ipairs({ "true", 1, {}, function() end }) do
			local client, state = Ports.fresh_client()
			local result
			local operation = client.get_owned(initial, {}, { owner = "wrong-flag", timeout_ms = 1000, follow_redirects = true, managed_redirects = flag },
				function(value) result = value end)
			assert(not operation.started and operation:is_settled() and #state.requests == 0 and result.ok == false)
		end
	end)
	helpers.it("managed opt in cannot borrow POST or stream ownership", function()
		local client, state = Ports.fresh_client()
		local result
		local operation = client.post_stream_owned(initial, {}, "body",
			{ owner = "wrong-method", timeout_ms = 1000, follow_redirects = true, managed_redirects = true }, function() end,
			function(value) result = value end)
		assert(not operation.started and operation:is_settled() and #state.requests == 0 and result.ok == false)
	end)
	helpers.it("managed opt in cannot silently degrade into ETag or pathname redirect handling", function()
		for _, excluded in ipairs({ { etag_compare = "/fixed/cache" }, { etag_save = "/fixed/cache" }, { output_path = "/fixed/output" }, { follow_redirects = false } }) do
			local client, state = Ports.fresh_client()
			local result
			local opts = { owner = "wrong-scope", timeout_ms = 1000, follow_redirects = true, managed_redirects = true }
			for key, value in pairs(excluded) do opts[key] = value end
			local operation = client.get_owned(initial, {}, opts, function(value) result = value end)
			assert(not operation.started and operation:is_settled() and #state.requests == 0 and result.ok == false)
		end
	end)
	helpers.it("legacy boolean verified HTTPS downgrade keeps original307 HTTP receipt", function()
		local client, state = Ports.fresh_client()
		local result, calls = nil, 0
		assert(client.get(initial, {}, { owner = "legacy-tls", timeout_ms = 1000, follow_redirects = true },
			function(value) result = value; calls = calls + 1 end))
		hop_receipt(state, 1, 307, initial, downgrade, "")
		assert(#state.requests == 1 and calls == 1 and result.ok == false and result.status == 307 and result.error == "HTTP 307")
		assert(result.redirect_receipt == nil and not client.isActive("legacy-tls"))
	end)
	helpers.it("legacy owned verified HTTPS downgrade keeps original307 after physical ACK", function()
		local client, state = Ports.fresh_client()
		local result
		local operation = client.get_owned(initial, {}, { owner = "legacy-owned-tls", timeout_ms = 1000, follow_redirects = true }, function(value) result = value end)
		hop_receipt(state, 1, 307, initial, downgrade, "")
		assert(#state.requests == 1 and operation:is_settled() and result.status == 307 and result.error == "HTTP 307")
	end)
	helpers.it("explicit managed HTTPS downgrade retains strict status0 without next child", function()
		local client, state = Ports.fresh_client()
		local result
		local operation = client.get_owned(initial, {},
			{ owner = "strict-owned-tls", timeout_ms = 1000, follow_redirects = true, managed_redirects = true }, function(value) result = value end)
		hop_receipt(state, 1, 307, initial, downgrade, "")
		assert(#state.requests == 1 and operation:is_settled() and result.status == 0 and result.body == "")
		assert(result.error == "HTTP redirect protocol refused" and result.redirect_receipt == nil)
	end)
	helpers.it("unverified307 cannot borrow legacy HTTPS downgrade receipt preservation", function()
		local client, state = Ports.fresh_client()
		local result
		local operation = client.get_owned(initial, {}, { owner = "unverified-tls", timeout_ms = 1000, follow_redirects = true }, function(value) result = value end)
		state.complete_request(1, "\nERGOPTI_HTTP_STATUS:307\n")
		assert(#state.requests == 1 and operation:is_settled() and result.status == 0 and result.body == "")
		assert(result.error == "HTTP redirect receipt refused")
	end)
end)

helpers.describe("detached header redirect permission", function()
	helpers.it("one normalized sensitive table key retains legacy302 without a second conversion or child", function()
		local client, state = Ports.fresh_client()
		local conversions, result = 0, nil
		local name = setmetatable({}, { __tostring = function() conversions = conversions + 1; return "X-Api-Key" end })
		local operation = client.get_owned(initial, { [name] = "fixed-secret" },
			{ owner = "normalized-sensitive-key", timeout_ms = 1000, follow_redirects = true }, function(value) result = value end)
		assert(operation.started and conversions == 1 and state.config:find('header = "X-Api-Key: fixed-secret"', 1, true))
		state.complete_request(1, "\nERGOPTI_HTTP_STATUS:302\n")
		assert(conversions == 1 and #state.requests == 1 and operation:is_settled() and result.status == 302 and result.error == "HTTP 302")
	end)
end)
