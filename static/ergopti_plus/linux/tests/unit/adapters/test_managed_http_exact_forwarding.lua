--- tests/unit/adapters/test_managed_http_exact_forwarding.lua

--- ==============================================================================
--- MODULE: Test Managed Http Exact Forwarding
--- DESCRIPTION:
--- Preserves independent managed-network controls and actual production imports.
--- Source registration alone does not qualify native or installed behavior.
--- ==============================================================================

--- Actual wrapper/GIO/coordinator code; independent native child/close ports.
--- The Curl port records admission metadata, not actual native execution.
local helpers = require("tests.helpers")
local Json = require("json")
local Ports = require("tests.support.managed_http_native_ports")
local ExactPorts = require("tests.support.exact_identity_ports")

local function identity()
	return { device = 11, inode = 73, size = 71, mtime_sec = 123, mtime_nsec = 456, ctime_sec = 789, ctime_nsec = 12 }
end

local function start(capabilities, options)
	local wire = { starts = 0, results = {} }
	local Curl = { HAS_ASYNC = true, default_timeout_ms = function() return 1000 end,
		preflight = function() return true end }
	function Curl.dispatch_owned(_, _, _, admitted, _, done)
		wire.starts, wire.options = wire.starts + 1, admitted
		local child, listeners = { started = true }, {}
		function child:is_settled() return self.settled == true end
		function child:on_settled(listener) listeners[#listeners + 1] = listener; return true end
		function child:request_cancel() return true end
		function wire.ack()
			done({ ok = true, status = 200, body = "owned route" })
			child.settled = true
			for _, listener in ipairs(listeners) do listener() end
		end
		return child
	end
	local client, state = Ports.fresh_client({ native_curl = Curl, defer_close = true })
	local request = { owner = "identity-boundary", timeout_ms = 1000 }
	for key, value in pairs(options or {}) do request[key] = value end
	local operation = client.get_owned("https://corporate.invalid/private", {}, request, function(result)
		wire.results[#wire.results + 1] = result
	end)
	state.complete_request(1, Json.encode({ ok = true, proxies = { "http://first.invalid:81" },
		backend = "GProxyResolverGnome", acknowledgement = "native-selection", failure_provenance = "unavailable",
		curl_capabilities = capabilities }))
	helpers.assert_eq(wire.starts, 0, "Native Curl admission must wait for physical GIO close acknowledgements")
	helpers.assert_true(not operation:is_settled(), "GIO retirement debt remains before its native close acknowledgements")
	state.ack_closes()
	return wire, operation, state
end

local function finish(wire, operation, state)
	wire.ack()
	helpers.assert_true(operation:is_settled())
	helpers.assert_eq(#wire.results, 1)
	for _, deadline in ipairs(state.deadlines) do helpers.assert_true(deadline.settled) end
end

helpers.describe("actual public guard and coordinator exact identity", function()
	helpers.it("forwards the independent exact paired native snapshot only after GIO physical close ACK", function()
		local value = ExactPorts.identity()
		local wire, operation, state = start({ proxy_used = true, version = "8.14.1", executable = "/independent/bin/curl",
			executable_observation = "owned-child", executable_identity_exact = value })
		helpers.assert_eq(wire.starts, 1)
		helpers.assert_eq(wire.options.curl_executable, "/independent/bin/curl")
		helpers.assert_nil(wire.options.curl_executable_identity)
		helpers.assert_true(wire.options.proxy_metrics_available)
		helpers.assert_eq(wire.options.curl_executable_identity_exact.inode_decimal, "9223372036855093009")
		value.inode_decimal = "9223372036855093010"
		helpers.assert_eq(wire.options.curl_executable_identity_exact.inode_decimal, "9223372036855093009")
		finish(wire, operation, state)
	end)
	helpers.it("strips caller-injected exact identity and executable when no native pair acknowledges it", function()
		local wire, operation, state = start({ proxy_used = false }, {
			curl_executable = "/caller/bin/curl", curl_executable_identity_exact = ExactPorts.identity(), proxy_metrics_available = true })
		helpers.assert_eq(wire.starts, 1)
		helpers.assert_nil(wire.options.curl_executable)
		helpers.assert_nil(wire.options.curl_executable_identity)
		helpers.assert_nil(wire.options.curl_executable_identity_exact)
		helpers.assert_eq(wire.options.proxy_metrics_available, false)
		finish(wire, operation, state)
	end)
	for _, vector in ipairs({ { malformed = "overflow" }, { malformed = "leadingzero" }, { malformed = "extra" }, { mixed = true } }) do
		local fixed = vector
		helpers.it("refuses malformed or mixed exact native metadata before any curl acquisition", function()
			local exact = ExactPorts.identity()
			if fixed.malformed == "overflow" then exact.inode_decimal = "18446744073709551616" end
			if fixed.malformed == "leadingzero" then exact.inode_decimal = "09223372036855093009" end
			if fixed.malformed == "extra" then exact.inode = 123 end
			local capabilities = { proxy_used = true, version = "8.14.1", executable = "/independent/bin/curl",
				executable_observation = "owned-child", executable_identity_exact = exact }
			if fixed.mixed then capabilities.executable_identity = identity() end
			local wire, operation, state = start(capabilities)
			helpers.assert_eq(wire.starts, 0)
			helpers.assert_true(operation:is_settled())
			helpers.assert_eq(#wire.results, 1)
			helpers.assert_eq(wire.results[1].error, "proxy-receipt-invalid")
			helpers.assert_eq(wire.results[1].failure_receipt.failure_provenance, "unknown")
		end)
	end
end)
