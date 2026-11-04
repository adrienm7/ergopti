--- tests/unit/adapters/network/test_http_client_curl_native_private_managed.lua

--- ==============================================================================
--- MODULE: Asynchronous HTTP Process Ownership
--- DESCRIPTION:
--- Drives the Linux HttpClient through a controllable libuv double. The tests
--- prove dispatch returns before output, timeout and cancel kill the detached
--- process group, and exactly one terminal callback survives late events.
--- ==============================================================================

package.loaded["tests.support.adapters.network.http_client_curl_fixture"] = nil
local Fixture = require("tests.support.adapters.network.http_client_curl_fixture")
local helpers, fresh_client, EXECUTABLE_IDENTITY, private_client, exact_core_client, exact_options, native_write_out, retired_leader_with_live_descendant, complete_owned_leader, nonzero_signals, assert_successor_blocked =
	Fixture.helpers, Fixture.fresh_client, Fixture.EXECUTABLE_IDENTITY, Fixture.private_client, Fixture.exact_core_client, Fixture.exact_options, Fixture.native_write_out, Fixture.retired_leader_with_live_descendant, Fixture.complete_owned_leader, Fixture.nonzero_signals, Fixture.assert_successor_blocked




helpers.describe("native-private managed HTTP bridge", function()
	for _, invalid in ipairs({ { value = nil }, { value = false } }) do
		helpers.it("private-options: typed refusal cannot cancel or acquire from an incumbent (" .. tostring(invalid.value) .. ")", function()
			local client, state = fresh_client()
			helpers.assert_true(client.get("http://127.0.0.1/", {}, { owner = "kept" }, function() end))
			local handles, kills, result = #state.handles, #state.kills, nil
			local allowed, err = client.preflight("http://127.0.0.1/", {}, nil, invalid.value)
			helpers.assert_eq(allowed, false)
			helpers.assert_eq(err, "native HTTP options are invalid")
			local operation = client.dispatch_owned("http://127.0.0.1/", {}, nil, invalid.value, nil, function(value) result = value end)
			helpers.assert_eq(operation.started, false)
			helpers.assert_true(operation:is_settled())
			helpers.assert_eq(result.error, "native HTTP options are invalid")
			helpers.assert_eq(#state.handles, handles)
			helpers.assert_eq(#state.kills, kills)
			helpers.assert_true(client.isActive("kept"))
		end)
	end

	helpers.it("private-preflight: established truthy redirect admission is preserved", function()
		local client, state = fresh_client()
		local options = { method = "GET", follow_redirects = "truthy", timeout_ms = 500, buffered = true }
		helpers.assert_true(client.preflight("http://127.0.0.1/", {}, nil, options))
		helpers.assert_eq(options.follow_redirects, "truthy")
		local operation = client.dispatch_owned("http://127.0.0.1/", {}, nil, options, nil, function() end)
		helpers.assert_true(operation.started)
		helpers.assert_true(table.concat(state.options.args, "\n"):find("--location", 1, true) ~= nil)
	end)

	helpers.it("private-preflight: invalid body metadata cannot replace an incumbent", function()
		local client, state = fresh_client()
		helpers.assert_true(client.get("http://127.0.0.1/", {}, { owner = "kept" }, function() end))
		local handles, kills = #state.handles, #state.kills
		local options = { owner = "kept", method = "POST", timeout_ms = 500, buffered = true }
		local allowed, err = client.preflight("http://127.0.0.1/", {}, "a\0b", options)
		helpers.assert_eq(allowed, false)
		helpers.assert_eq(err, "curl request body cannot contain NUL")
		helpers.assert_eq(#state.handles, handles)
		helpers.assert_eq(#state.kills, kills)
		helpers.assert_true(client.isActive("kept"))
	end)

	helpers.it("private-preflight: admitted redirect normalization does not mutate caller options", function()
		local client, state = fresh_client()
		local options = { method = "GET", follow_redirects = true, timeout_ms = 500, buffered = true }
		helpers.assert_true(client.preflight("https://example.invalid/", { ["X-API-Key"] = "private" }, nil, options))
		helpers.assert_eq(options.follow_redirects, true)
		helpers.assert_eq(#state.handles, 0)
		helpers.assert_eq(#state.requests, 0)
	end)

	for _, buffered in ipairs({ true, false }) do
		helpers.it("private-dispatch: POST body keeps owned anonymous pipe and native method (buffered=" .. tostring(buffered) .. ")", function()
			local client, state = fresh_client({ defer_close = true })
			local operation = client.dispatch_owned("http://127.0.0.1/", {}, "@literal\r\n", {
				owner = "private-post", method = "POST", buffered = buffered, timeout_ms = 500,
			}, function() end, function() end)
			helpers.assert_true(operation.started)
			helpers.assert_eq(state.body, "@literal\r\n")
			helpers.assert_true(state.config:find('data-binary = "@/dev/fd/3"', 1, true) ~= nil)
			helpers.assert_true(state.options.stdio[4] ~= nil)
			helpers.assert_eq(state.options.args[1], "--disable")
			helpers.assert_true(table.concat(state.options.args, "\n"):find("--globoff", 1, true) ~= nil)
			helpers.assert_true(table.concat(state.options.args, "\n"):find("--request", 1, true) == nil)
			helpers.assert_true(operation:request_cancel())
			helpers.assert_eq(operation:is_settled(), false)
			state.exit(0); state.ack_closes()
			helpers.assert_true(operation:is_settled())
		end)
	end

	helpers.it("private-cancel: boolean signal refusal keeps delivery eligible and activity", function()
		local client, state = fresh_client({ kill_failure = true, defer_close = true })
		local delivered = 0
		local operation = client.dispatch_owned("http://127.0.0.1/", {}, nil, {
			owner = "legacy-private", owned_api = false, method = "GET", buffered = true, timeout_ms = 500,
		}, nil, function() delivered = delivered + 1 end)
		helpers.assert_eq(operation:request_cancel(), false)
		helpers.assert_true(client.isActive("legacy-private"))
		state.stdout("ok\nERGOPTI_HTTP_STATUS:200\n"); state.complete()
		helpers.assert_eq(delivered, 0)
		state.ack_closes()
		helpers.assert_eq(delivered, 1)
	end)

	helpers.it("private-cancel: owned refusal fences delivery while preserving physical debt", function()
		local client, state = fresh_client({ kill_failure = true, defer_close = true })
		local delivered = 0
		local operation = client.dispatch_owned("http://127.0.0.1/", {}, nil, {
			owner = "owned-private", owned_api = true, method = "GET", buffered = true, timeout_ms = 500,
		}, nil, function() delivered = delivered + 1 end)
		helpers.assert_eq(operation:request_cancel(), false)
		helpers.assert_eq(operation:is_settled(), false)
		state.stdout("ok\nERGOPTI_HTTP_STATUS:200\n"); state.complete(); state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(delivered, 0)
	end)

	helpers.it("private-cancel: reaped leader cannot release a still-nonterminal group", function()
		local client, state = fresh_client({ kill_failure = true, defer_close = true })
		local operation = client.dispatch_owned("http://127.0.0.1/", {}, nil, {
			owner = "descendants", method = "GET", buffered = true, timeout_ms = 500,
		}, nil, function() end)
		state.exit(0)
		helpers.assert_eq(operation:request_cancel(), false)
		helpers.assert_eq(operation:is_settled(), false)
		helpers.assert_eq(#state.kills, 1)
		helpers.assert_eq(state.kills[1].pid, -state.requests[1].pid)
		state.stdout("exact\nERGOPTI_HTTP_STATUS:200\n"); state.stdout(nil); state.stderr(nil)
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
	end)

	helpers.it("private-observer: snapshot mutation cannot alter pending physical completion", function()
		local client, state = fresh_client({ defer_close = true })
		local observed, delivered, operation = 0, nil, nil
		local settled_inside, active_inside
		operation = client.dispatch_owned("http://127.0.0.1/", {}, nil, {
			owner = "observed", method = "GET", buffered = true, timeout_ms = 500,
			on_native_terminal = function(value)
				observed = observed + 1
				settled_inside = operation:is_settled()
				active_inside = client.isActive("observed")
				value.body, value.status = "MUTATED", 599
			end,
		}, nil, function(value) delivered = value end)
		state.stdout("exact\nERGOPTI_HTTP_STATUS:200\n"); state.complete()
		helpers.assert_eq(observed, 1)
		helpers.assert_eq(settled_inside, false)
		helpers.assert_eq(active_inside, false)
		helpers.assert_nil(delivered)
		state.ack_closes()
		helpers.assert_eq(delivered.body, "exact")
		helpers.assert_eq(delivered.status, 200)
		state.exit(0)
		helpers.assert_eq(observed, 1)
	end)

	helpers.it("private-observer: reentrant cleanup cannot settle until the observer returns", function()
		local client, state = fresh_client()
		local observed, settled, operation, delivered = 0, 0, nil, 0
		local accepted_inside, physically_settled_inside, listeners_inside
		operation = client.dispatch_owned("http://127.0.0.1/", {}, nil, {
			owner = "reentrant", method = "GET", buffered = true, timeout_ms = 500,
			on_native_terminal = function()
				observed = observed + 1
				accepted_inside = operation:request_cancel()
				physically_settled_inside = operation:is_settled()
				listeners_inside = settled
			end,
		}, nil, function() delivered = delivered + 1 end)
		operation:on_settled(function() settled = settled + 1 end)
		state.stdout("exact\nERGOPTI_HTTP_STATUS:200\n"); state.complete()
		helpers.assert_eq(observed, 1)
		helpers.assert_true(accepted_inside)
		helpers.assert_eq(physically_settled_inside, false)
		helpers.assert_eq(listeners_inside, 0)
		helpers.assert_eq(settled, 1)
		helpers.assert_eq(delivered, 0)
		helpers.assert_true(operation:is_settled())
	end)

	helpers.it("private-routing: selected proxy preserves environment bypass and stays outside argv", function()
		local client, state = fresh_client()
		local private = "http://owner:secret@127.0.0.1:8765"
		local selection = { mode = "selected", proxy = private, bypass = "environment" }
		local operation = client.dispatch_owned("https://example.invalid/", {}, nil, {
			owner = "selected", method = "GET", buffered = true, timeout_ms = 500, proxy_selection = selection,
		}, nil, function() end)
		helpers.assert_true(operation.started)
		helpers.assert_true(state.config:find('proxy = "' .. private .. '"', 1, true) ~= nil)
		helpers.assert_true(state.config:find("noproxy", 1, true) == nil)
		helpers.assert_true(table.concat(state.options.args, "\n"):find("secret", 1, true) == nil)
		selection.proxy = "http://mutated.invalid/"
		helpers.assert_true(state.config:find("mutated", 1, true) == nil)
	end)

	helpers.it("private-routing: explicit DIRECT disables inherited proxy use", function()
		local client, state = fresh_client()
		local operation = client.dispatch_owned("http://127.0.0.1/", {}, nil, {
			owner = "direct", method = "GET", buffered = true, timeout_ms = 500, proxy_selection = { mode = "direct" },
		}, nil, function() end)
		helpers.assert_true(operation.started)
		helpers.assert_true(state.config:find('proxy = ""', 1, true) ~= nil)
		helpers.assert_true(state.config:find('noproxy = "*"', 1, true) ~= nil)
	end)

	for _, metrics in ipairs({ "000:1", "000:0", "000:?", "MALFORMED" }) do
		helpers.it("private-metrics: only actual complete proxy receipts qualify connect failure (" .. metrics .. ")", function()
			local client, state = private_client()
			local observed, result = nil, nil
			client.dispatch_owned("https://example.invalid/", {}, nil, {
				owner = "metrics", method = "GET", buffered = true, timeout_ms = 500,
				proxy_selection = { mode = "selected", proxy = "http://proxy.invalid:80", bypass = "environment" },
				proxy_metrics_available = true, on_native_terminal = function(value) observed = value end,
				curl_executable = "/usr/bin/curl",
				curl_executable_identity = EXECUTABLE_IDENTITY,
			}, nil, function(value) result = value end)
			-- Delivered one byte at a time, as a slow pipe would.
			local stderr = "PRIVATE credential suffix\nERGOPTI_PROXY_STATUS:" .. metrics .. "\n"
			for index = 1, #stderr do state.stderr(stderr:sub(index, index)) end
			state.stdout("\nERGOPTI_HTTP_STATUS:000\n"); state.complete(7)
			helpers.assert_eq(result.error, "curl exited with code 7")
			helpers.assert_eq(result.failure_receipt.curl_exit, 7)
			helpers.assert_eq(observed.failure_receipt.curl_exit, 7)
			if metrics == "000:1" then
				helpers.assert_eq(result.proxy_used, true)
				helpers.assert_eq(result.failure_receipt.failure_provenance, "verified")
			elseif metrics == "000:0" then
				helpers.assert_eq(result.proxy_used, false)
				helpers.assert_eq(result.failure_receipt.failure_provenance, "unavailable")
			else
				helpers.assert_nil(result.proxy_used)
				helpers.assert_eq(result.failure_receipt.failure_provenance, "unavailable")
			end
		end)
	end

	helpers.it("private-metrics: unpinned capability hint cannot request or publish proxy-used", function()
		local client, state = fresh_client()
		local result
		client.dispatch_owned("https://example.invalid/", {}, nil, {
			owner = "unpinned", method = "GET", buffered = true, timeout_ms = 500,
			proxy_selection = { mode = "selected", proxy = "http://proxy.invalid:80", bypass = "environment" },
			proxy_metrics_available = true,
		}, nil, function(value) result = value end)
		helpers.assert_eq(state.command, "curl")
		helpers.assert_true(table.concat(state.options.args, "\n"):find("%{proxy_used}", 1, true) == nil)
		state.stderr("\nERGOPTI_PROXY_STATUS:000:1\n")
		state.stdout("\nERGOPTI_HTTP_STATUS:000\n"); state.complete(7)
		helpers.assert_nil(result.proxy_used)
		helpers.assert_eq(result.failure_receipt.failure_provenance, "unavailable")
	end)

	helpers.it("private-executable: pinned curl path is the actual admitted spawn target", function()
		local client, state = private_client()
		local options = { owner = "pinned", method = "GET", buffered = true, timeout_ms = 500,
			curl_executable = "/opt/owned/curl", proxy_metrics_available = true,
			curl_executable_identity = EXECUTABLE_IDENTITY,
			proxy_selection = { mode = "selected", proxy = "http://proxy.invalid:80", bypass = "environment" } }
		helpers.assert_true(client.preflight("https://example.invalid/", {}, nil, options))
		helpers.assert_eq(#state.stat_calls, 0, "preflight must stay free of native file observations")
		local operation = client.dispatch_owned("https://example.invalid/", {}, nil, options, nil, function() end)
		helpers.assert_true(operation.started)
		helpers.assert_eq(state.command, "/opt/owned/curl")
		helpers.assert_eq(#state.stat_calls, 1)
		helpers.assert_eq(state.stat_calls[1], "/opt/owned/curl")
		helpers.assert_true(table.concat(state.options.args, "\n"):find("%{proxy_used}", 1, true) ~= nil)
	end)

	for _, stat_case in ipairs({ "missing", "throw", "changed", "error-ack", "status-ack" }) do
		helpers.it("private-executable: " .. stat_case .. " identity disables only the new native feature", function()
			local client, state = private_client({ stat_case = stat_case })
			local operation = client.dispatch_owned("https://example.invalid/", {}, nil, {
				owner = "identity", method = "GET", buffered = true, timeout_ms = 500,
				curl_executable = "/opt/owned/curl", curl_executable_identity = EXECUTABLE_IDENTITY,
				proxy_metrics_available = true, proxy_selection = { mode = "selected", proxy = "http://proxy.invalid:80", bypass = "environment" },
			}, nil, function() end)
			helpers.assert_true(operation.started)
			helpers.assert_eq(state.command, "/opt/owned/curl")
			helpers.assert_eq(#state.stat_calls, 1)
			helpers.assert_true(table.concat(state.options.args, "\n"):find("%{proxy_used}", 1, true) == nil)
		end)
	end

	for _, malformed in ipairs({ {}, { device = 42, inode = 123, size = 456,
		mtime_sec = 100, mtime_nsec = 1000000000, ctime_sec = 300, ctime_nsec = 400 } }) do
		helpers.it("private-executable: malformed identity cannot admit a native metric", function()
			local client, state = private_client()
			local operation = client.dispatch_owned("https://example.invalid/", {}, nil, {
				owner = "malformed-identity", method = "GET", buffered = true, timeout_ms = 500,
				curl_executable = "/opt/owned/curl", curl_executable_identity = malformed,
				proxy_metrics_available = true, proxy_selection = { mode = "selected", proxy = "http://proxy.invalid:80", bypass = "environment" },
			}, nil, function() end)
			helpers.assert_true(operation.started)
			helpers.assert_eq(#state.stat_calls, 0)
			helpers.assert_true(table.concat(state.options.args, "\n"):find("%{proxy_used}", 1, true) == nil)
		end)
	end

	helpers.it("private-metrics: ordinary HTTP407 cannot assert a CONNECT authentication target", function()
		local client, state = fresh_client()
		local result
		client.dispatch_owned("http://example.invalid/", {}, nil, {
			owner = "http407", method = "GET", buffered = true, timeout_ms = 500,
			proxy_selection = { mode = "selected", proxy = "http://proxy.invalid:80", bypass = "environment" },
		}, nil, function(value) result = value end)
		state.stderr("\nERGOPTI_PROXY_STATUS:000:?\n")
		state.stdout("rejected\nERGOPTI_HTTP_STATUS:407\n"); state.complete(22)
		helpers.assert_eq(result.failure_receipt.stage, "http")
		helpers.assert_eq(result.failure_receipt.proxy_connect_status, 0)
		helpers.assert_nil(result.failure_receipt.response_source)
		helpers.assert_eq(result.error_body, "rejected")
	end)
end)




helpers.describe("sole native core exact identity composition", function()
	helpers.it("pure preflight validates exact metadata without descriptors or native handles", function()
		local client, state = exact_core_client()
		helpers.assert_true(client.preflight("https://corporate.invalid/", {}, nil, exact_options()))
		helpers.assert_eq(#state.fd_state.opens, 0)
		helpers.assert_eq(#state.handles, 0)
		helpers.assert_eq(#state.requests, 0)
	end)
	helpers.it("new native feature requires an independently equal exact uint64 descriptor at actual composition", function()
		local client, state = exact_core_client({ defer_close = true })
		local operation = client.dispatch_owned("https://corporate.invalid/", {}, nil, exact_options(), nil, function() end)
		helpers.assert_true(operation.started)
		helpers.assert_eq(state.command, "/independent/bin/curl")
		helpers.assert_eq(#state.fd_state.opens, 2)
		helpers.assert_eq(#state.fd_state.closes, 2)
		helpers.assert_true(native_write_out(state):find("%{proxy_used}", 1, true) ~= nil)
		operation:request_cancel(); state.exit(0); state.ack_closes()
		helpers.assert_true(operation:is_settled())
	end)
	helpers.it("a literal adjacent high inode never compares equal or requests proxy_used", function()
		local client, state = exact_core_client()
		local operation = client.dispatch_owned("https://corporate.invalid/", {}, nil,
			exact_options("exact-adjacent", "9223372036855093010"), nil, function() end)
		helpers.assert_true(operation.started)
		helpers.assert_eq(native_write_out(state):find("%{proxy_used}", 1, true), nil)
		helpers.assert_true(native_write_out(state):find("%{http_connect}:?", 1, true) ~= nil)
		operation:request_cancel(); state.exit(0)
		helpers.assert_true(operation:is_settled())
	end)
	for _, config in ipairs({ { missing_constants = true }, { missing_port = "fs_open" },
		{ fail_method = "fs_fstat", fail_shape = "status" }, { fail_method = "fs_read", fail_shape = "error" },
		{ no_eof = true } }) do
		local fixed = config
		helpers.it("ordinary pinned curl remains usable when exact observation is unavailable with all descriptors retired", function()
			local client, state = exact_core_client({ identity = fixed })
			local operation = client.dispatch_owned("https://corporate.invalid/", {}, nil, exact_options(), nil, function() end)
			helpers.assert_true(operation.started)
			helpers.assert_eq(native_write_out(state):find("%{proxy_used}", 1, true), nil)
			helpers.assert_eq(#state.fd_state.opens, #state.fd_state.closes)
			operation:request_cancel(); state.exit(0)
			helpers.assert_true(operation:is_settled())
		end)
	end
	helpers.it("mixed private formats refuse before owner replacement or native acquisition", function()
		local client, state = exact_core_client()
		local options = exact_options()
		options.curl_executable_identity = { device = 11, inode = 123, size = 71,
			mtime_sec = 123, mtime_nsec = 456, ctime_sec = 789, ctime_nsec = 12 }
		local allowed, message = client.preflight("https://corporate.invalid/", {}, nil, options)
		helpers.assert_eq(allowed, false)
		helpers.assert_eq(message, "native curl exact identity is invalid")
		helpers.assert_eq(#state.handles, 0)
		helpers.assert_eq(#state.fd_state.opens, 0)
	end)
	helpers.it("constructor refusal resets construction fencing and retires every already-armed native handle", function()
		local client, state = exact_core_client({ defer_close = true, constructor_throw = true })
		local options, terminals, receipt = exact_options("exact-constructor"), 0, nil
		options.on_native_terminal = function(value) terminals = terminals + 1; receipt = value end
		local operation = client.dispatch_owned("https://corporate.invalid/", {}, nil, options, nil, function() end)
		helpers.assert_eq(operation.started, false)
		helpers.assert_eq(operation:is_settled(), false)
		helpers.assert_eq(terminals, 1)
		helpers.assert_eq(receipt.error, "curl exact identity observation failed")
		helpers.assert_eq(#state.fd_state.opens, 0)
		helpers.assert_eq(#state.requests, 0)
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		local successor = client.get_owned("http://127.0.0.1/", {}, { owner = "exact-constructor" }, function() end)
		helpers.assert_true(successor.started)
		successor:request_cancel(); state.exit(0); state.ack_closes()
		helpers.assert_true(successor:is_settled())
		helpers.assert_eq(terminals, 1)
	end)
	helpers.it("retirement refusal retains the same owner and never retries a removed bare descriptor", function()
		local client, state = exact_core_client({ defer_close = true,
			identity = { fail_method = "fs_close", fail_shape = "status" } })
		local terminals, result = 0, nil
		local options = exact_options("uncertain-exact")
		options.on_native_terminal = function(value) terminals = terminals + 1; result = value end
		local operation = client.dispatch_owned("https://corporate.invalid/", {}, nil, options, nil, function() end)
		helpers.assert_eq(operation.started, false)
		helpers.assert_eq(operation:is_settled(), false)
		helpers.assert_true(client.isActive("uncertain-exact"))
		helpers.assert_eq(terminals, 1)
		helpers.assert_eq(result.error, "curl exact identity retirement unavailable")
		helpers.assert_eq(#state.requests, 0)
		state.ack_closes()
		local closes = #state.fd_state.closes
		helpers.assert_eq(operation:cancel(), false)
		helpers.assert_eq(client.cancel("uncertain-exact"), false)
		helpers.assert_eq(#state.fd_state.closes, closes)
		local refused
		local successor = client.get_owned("http://127.0.0.1/", {}, { owner = "uncertain-exact" }, function(value) refused = value end)
		helpers.assert_eq(successor.started, false)
		helpers.assert_true(successor:is_settled())
		helpers.assert_eq(refused.error, "previous request cleanup pending")
		helpers.assert_eq(#state.requests, 0)
		helpers.assert_eq(terminals, 1)
	end)
	helpers.it("filesystem cancellation reentry sees a registered native owner and cannot resurrect curl", function()
		local client, state, accepted, refused, hook_calls
		hook_calls = 0
		client, state = exact_core_client({ defer_close = true, identity = { hook = function(method)
			if method == "fs_fstat" then
				hook_calls = hook_calls + 1
				accepted = client.cancel("exact-reentry")
				local child = client.get_owned("http://127.0.0.1/", {}, { owner = "exact-reentry" }, function(value) refused = value end)
				if child.started then hook_calls = hook_calls + 100 end
			end
		end } })
		local terminals = 0
		local options = exact_options("exact-reentry")
		options.on_native_terminal = function() terminals = terminals + 1 end
		local operation = client.dispatch_owned("https://corporate.invalid/", {}, nil, options, nil, function() end)
		helpers.assert_eq(operation.started, false)
		helpers.assert_eq(accepted, false, "Native cancel returns physical settlement while construction remains retained")
		helpers.assert_eq(refused.error, "previous request cleanup pending")
		helpers.assert_eq(hook_calls, 1)
		helpers.assert_eq(#state.requests, 0)
		helpers.assert_eq(#state.fd_state.opens, 1)
		helpers.assert_eq(#state.fd_state.closes, 1)
		helpers.assert_eq(terminals, 1)
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
	end)
end)




helpers.describe("http_client: independent owned detached-group absence", function()
	helpers.it("owned-group: leader exit, both EOFs and stream/process ACKs leave a live descendant pending", function()
		local client, state, operation, calls = retired_leader_with_live_descendant()
		complete_owned_leader(state)
		helpers.assert_eq(operation:is_settled(), false, "leader exit is not detached-group absence")
		helpers.assert_eq(calls(), 0)
		for _, handle in ipairs(state.handles) do
			if handle.kind ~= "timer" then helpers.assert_true(handle.closing, "every other native close is admitted") end
		end
		assert_successor_blocked(client, state)
		helpers.assert_eq(state.timer.closing, false)
		helpers.assert_eq(state.timer.timeout_ms, 50)
		helpers.assert_eq(state.timer.repeat_ms, 50)
		helpers.assert_eq(#state.handles, 5, "cleanup reuses the acquired request timer")
		helpers.assert_true(nonzero_signals(state) >= 2)
	end)

	helpers.it("owned-group: accepted TERM and KILL retain debt until native ESRCH and monitor close ACK", function()
		local _, state, operation, calls = retired_leader_with_live_descendant()
		complete_owned_leader(state)
		state.timer.callback()
		helpers.assert_eq(operation:is_settled(), false, "signal acceptance cannot settle live descendants")
		helpers.assert_eq(calls(), 0)
		state.groups[4321] = false
		state.timer.callback()
		helpers.assert_eq(operation:is_settled(), false, "the cleanup monitor still owns its close callback")
		helpers.assert_true(state.timer.closing)
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(calls(), 1)
	end)

	for _, mode in ipairs({ "throw", "false", "nil", "text-only", "unknown-code" }) do
		helpers.it("owned-group: " .. mode .. " probe refusal is not a native absence receipt", function()
			local client, state, operation, calls = retired_leader_with_live_descendant()
			state.probe_mode = mode
			complete_owned_leader(state)
			helpers.assert_eq(operation:is_settled(), false)
			helpers.assert_eq(calls(), 0)
			helpers.assert_eq(nonzero_signals(state), 0, "an unadmitted group probe cannot authorize cleanup signals")
			assert_successor_blocked(client, state)
			state.probe_mode = nil
			state.groups[4321] = false
			state.timer.callback()
			state.ack_closes()
			helpers.assert_true(operation:is_settled())
		end)
	end

	helpers.it("owned-group: termination refusal and later signal acceptance both preserve descendant debt", function()
		local client, state, operation, calls = retired_leader_with_live_descendant({ kill_failure = true })
		complete_owned_leader(state)
		helpers.assert_eq(operation:is_settled(), false)
		state.timer.callback()
		assert_successor_blocked(client, state)
		state.allow_kills = true
		state.timer.callback()
		helpers.assert_eq(operation:is_settled(), false)
		helpers.assert_eq(calls(), 0)
		state.groups[4321] = false
		state.timer.callback()
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
	end)

	helpers.it("owned-group: a refused cleanup monitor stays owned and manual retry arms the same handle", function()
		local client, state, operation, calls = retired_leader_with_live_descendant()
		state.monitor_refused = true
		complete_owned_leader(state)
		helpers.assert_eq(operation:is_settled(), false)
		helpers.assert_eq(calls(), 0)
		assert_successor_blocked(client, state)
		state.monitor_refused = false
		helpers.assert_eq(operation:cancel(), false)
		helpers.assert_eq(#state.handles, 5)
		helpers.assert_eq(state.timer.repeat_ms, 50)
		state.groups[4321] = false
		state.timer.callback()
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(calls(), 0, "cancel intent suppresses the pending response")
	end)

	helpers.it("owned-group: refused monitor close rearms its referenced handle and waits for its own ACK", function()
		local client, state, operation, calls = retired_leader_with_live_descendant()
		complete_owned_leader(state)
		state.monitor_close_refused = true
		state.groups[4321] = false
		state.timer.callback()
		helpers.assert_eq(operation:is_settled(), false)
		helpers.assert_eq(calls(), 0)
		helpers.assert_eq(state.timer.stopped, false, "refused close must retain progress on the same timer")
		assert_successor_blocked(client, state)
		state.monitor_close_refused = false
		state.timer.callback()
		helpers.assert_eq(operation:is_settled(), false)
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(calls(), 1)
	end)

	helpers.it("owned-group: native group absence still waits for the exact leader exit receipt", function()
		local _, state, operation, calls = retired_leader_with_live_descendant()
		helpers.assert_eq(operation:cancel(), false)
		state.ack_closes()
		state.groups[4321] = false
		state.timer.callback()
		helpers.assert_eq(operation:is_settled(), false)
		local signals = #state.kills
		state.timer.callback()
		helpers.assert_eq(#state.kills, signals, "acknowledged absence forbids later signals on a reused PGID")
		state.exit()
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(calls(), 0)
	end)

	helpers.it("owned-group: stale old monitor and close callbacks cannot signal or settle a new owner", function()
		local client, state, operation, calls = retired_leader_with_live_descendant()
		complete_owned_leader(state)
		local old_monitor = state.timer.callback
		state.groups[4321] = false
		old_monitor()
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		local old_closes = {}
		for _, receipt in ipairs(state.closes) do old_closes[#old_closes + 1] = receipt.callback end
		local successor = client.get_owned("http://127.0.0.1:9000/models", {},
			{ owner = "group-receipt" }, function() end)
		helpers.assert_true(successor.started)
		local signals = #state.kills
		old_monitor()
		for _, callback in ipairs(old_closes) do callback() end
		helpers.assert_eq(#state.kills, signals)
		helpers.assert_eq(successor:is_settled(), false)
		helpers.assert_true(client.isActive("group-receipt"))
		helpers.assert_eq(calls(), 1)
		state.groups[4322] = false
		state.complete_request(2, '[]\nERGOPTI_HTTP_STATUS:200\n')
		state.ack_closes()
		helpers.assert_true(successor:is_settled())
	end)

	helpers.it("owned-group: already absent completed groups need no retirement signals", function()
		local client, state = fresh_client({ defer_close = true })
		local operation = client.get_owned("http://127.0.0.1:9000/models", {}, {}, function() end)
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n')
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(nonzero_signals(state), 0)
		helpers.assert_true(#state.probes > 0)
	end)

	helpers.it("owned-group: exceptional legacy body cleanup retains its existing boolean ABI and no group monitor", function()
		local config = { descendants_alive = true, defer_close = true }
		local client, state = fresh_client(config)
		local result
		helpers.assert_true(client.post("http://127.0.0.1:9000/models", {}, "{}", function(value) result = value end))
		config.close_failure = true -- Refuse terminal cleanup only after successful admission.
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n')
		helpers.assert_eq(result, nil)
		state.allow_closes = true
		helpers.assert_eq(client.cancel(), false)
		state.ack_closes()
		helpers.assert_true(client.cancel())
		helpers.assert_eq(#state.probes, 0, "_body_cleanup is the retained historical internal operation")
		for _, receipt in ipairs(state.timer_starts) do helpers.assert_eq(receipt.repeat_ms, 0) end
	end)
end)

