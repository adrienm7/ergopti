--- tests/unit/adapters/network/test_http_client_curl_file_digest_asynchronous.lua

--- ==============================================================================
--- MODULE: Asynchronous HTTP Process Ownership
--- DESCRIPTION:
--- Drives the Linux HttpClient through a controllable libuv double. The tests
--- prove dispatch returns before output, timeout and cancel kill the detached
--- process group, and exactly one terminal callback survives late events.
--- ==============================================================================

package.loaded["tests.support.adapters.network.http_client_curl_fixture"] = nil
local Fixture = require("tests.support.adapters.network.http_client_curl_fixture")
local helpers, fresh_client, fresh_digest =
	Fixture.helpers, Fixture.fresh_client, Fixture.fresh_digest




helpers.describe("file_digest: asynchronous sha256sum ownership", function()
	local native_ok = pcall(require, "luv")
	local ffi_ok = pcall(require, "ffi")
	if native_ok and ffi_ok and package.config:sub(1, 1) == "/" then
		helpers.it("linux-digest-allocation: actual partial handles retire before refusal returns", function()
			local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
			local fixture = helpers.driver_root() .. "/tests/fixtures/native_file_digest_allocations.lua"
			local result = os.execute(quote(assert(arg[-1])) .. " " .. quote(fixture))
			helpers.assert_true(result == true or result == 0, "native digest allocation fixture must pass")
		end)
		helpers.it("linux-digest-replacement: rejected paths preserve an actual native incumbent", function()
			local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
			local fixture = helpers.driver_root() .. "/tests/fixtures/native_file_digest_replacement.lua"
			local result = os.execute(quote(assert(arg[-1])) .. " " .. quote(fixture))
			helpers.assert_true(result == true or result == 0, "native digest replacement fixture must pass")
		end)
		helpers.it("linux-digest-owner: actual updater cancellation preserves another native digest", function()
			local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
			local fixture = helpers.driver_root() .. "/tests/fixtures/native_file_digest_owners.lua"
			local result = os.execute(quote(assert(arg[-1])) .. " " .. quote(fixture))
			helpers.assert_true(result == true or result == 0, "native digest owner fixture must pass")
		end)
	end

	for _, mode in ipairs({ "raised", "nil" }) do
		for slot = 1, 3 do
			helpers.it("linux-digest-allocation: " .. mode .. " constructor at " .. slot .. " releases prior handles", function()
				local options = {}
				options[mode == "raised" and "allocation_failure_at" or "allocation_nil_at"] = slot
				local digest, state = fresh_digest(options)
				local value, failure, callbacks = nil, nil, 0
				helpers.assert_eq(digest.sha256("/tmp/allocation.part", { owner = "allocation-unit" }, function(hash, err)
					value, failure, callbacks = hash, err, callbacks + 1
				end), false)
				helpers.assert_nil(value)
				helpers.assert_eq(failure, "libuv handle allocation failed")
				helpers.assert_eq(callbacks, 1)
				helpers.assert_eq(#state.requests, 0)
				helpers.assert_nil(state.command)
				helpers.assert_true(not digest.isActive("allocation-unit"))
				helpers.assert_eq(#state.handles, slot - 1)
				for _, handle in ipairs(state.handles) do helpers.assert_true(handle.closing, "partial allocation must close") end
				helpers.assert_true(digest.cancel("allocation-unit"))
				helpers.assert_eq(callbacks, 1, "cancelling a refused owner cannot publish another callback")
			end)
		end
	end

	for _, length in ipairs({ 957, 958, 1106, 3500 }) do
		helpers.it("linux-digest-path-budget: hashes a " .. length .. "-byte path", function()
			local digest, state = fresh_digest()
			local path = "/" .. string.rep("p", length - 1)
			local value, err, callbacks = nil, nil, 0
			local expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
			helpers.assert_true(digest.sha256(path, {}, function(result, failure)
				value, err, callbacks = result, failure, callbacks + 1
			end))
			local receipt = expected .. " *" .. path .. "\0"
			-- Exercise accumulated chunks, not only a single oversized read.
			for index = 1, #receipt, 113 do state.stdout(receipt:sub(index, index + 112)) end
			state.complete_request(1, nil, 0)
			helpers.assert_eq(value, expected)
			helpers.assert_eq(err, nil)
			helpers.assert_eq(callbacks, 1)
			helpers.assert_true(not digest.isActive())
			for _, handle in ipairs(state.handles) do helpers.assert_true(handle.closing) end
		end)
	end

	for _, stream in ipairs({ "stdout", "stderr" }) do
		helpers.it("linux-digest-path-budget: bounds excess " .. stream .. " on long paths", function()
			local digest, state = fresh_digest()
			local path = "/" .. string.rep("p", 1105)
			local value, err, callbacks = nil, nil, 0
			helpers.assert_true(digest.sha256(path, {}, function(result, failure)
				value, err, callbacks = result, failure, callbacks + 1
			end))
			local limit = stream == "stdout" and 1024 + #path or 1024
			state[stream](string.rep("x", limit + 1))
			state.complete_request(1, nil, 0)
			helpers.assert_eq(value, nil)
			helpers.assert_eq(err, "sha256sum output exceeds limit")
			helpers.assert_eq(callbacks, 1, "late exit must not publish a second receipt")
			helpers.assert_true(not digest.isActive())
			helpers.assert_eq(state.kills[1].pid, -4321)
			for _, handle in ipairs(state.handles) do helpers.assert_true(handle.closing) end
		end)
	end

	helpers.it("hashes a literal absolute path without a shell", function()
		local digest, state = fresh_digest()
		local value = nil
		local err = nil
		local path = "/tmp/release $HOME 'literal'.part"
		local dispatched = digest.sha256(path, { timeout_ms = 250 }, function(result, failure)
			value = result
			err = failure
		end)
		helpers.assert_true(dispatched and digest.isActive())
		helpers.assert_eq(state.command, "sha256sum")
		helpers.assert_eq(state.options.args[4], path,
			"the file path must remain one literal argv entry")
		helpers.assert_eq(value, nil, "hashing must return before the file has been consumed")
		local expected = string.rep("a1", 32)
		state.complete_request(1, expected .. " *" .. path .. "\0", 0)
		helpers.assert_eq(err, nil)
		helpers.assert_eq(value, expected)
		helpers.assert_true(not digest.isActive())
	end)

	helpers.it("rejects malformed digest output instead of trusting it", function()
		local digest, state = fresh_digest()
		local result_error = nil
		digest.sha256("/tmp/release.part", {}, function(_, err) result_error = err end)
		state.complete_request(1, "not-a-digest */tmp/release.part\0", 0)
		helpers.assert_eq(result_error, "invalid sha256sum output")
	end)

	helpers.it("times out and kills the digest process group", function()
		local digest, state = fresh_digest()
		local result_error = nil
		digest.sha256("/tmp/release.part", { timeout_ms = 25 },
			function(_, err) result_error = err end)
		state.timer.callback()
		helpers.assert_eq(result_error, "timeout")
		helpers.assert_eq(state.kills[1].pid, -4321)
		helpers.assert_true(not digest.isActive())
	end)
end)




helpers.describe("http_client: unavailable async runtime", function()
	helpers.it("fails explicitly without ever calling io.popen", function()
		local previous_luv = package.loaded["luv"]
		local previous_preload = package.preload["luv"]
		local previous_client = package.loaded["adapters.curl_http_client"]
		local previous_popen = io.popen
		package.loaded["luv"] = nil
		package.preload["luv"] = function() error("missing luv") end
		package.loaded["adapters.curl_http_client"] = nil
		io.popen = function() error("a synchronous fallback must never run") end
		local client = require("adapters.curl_http_client")
		local result = nil
		client.post("http://127.0.0.1:11434/api/chat", {}, "", function(value) result = value end)
		io.popen = previous_popen
		package.preload["luv"] = previous_preload
		package.loaded["luv"] = previous_luv
		package.loaded["adapters.curl_http_client"] = previous_client
		helpers.assert_eq(result.error, "asynchronous HTTP unavailable")
	end)
end)




helpers.describe("http_client: cancellation receipt boundary", function()
	helpers.it("legacy HTTP cancellation is only signal acceptance before native exit and close ACKs", function()
		local client, state = fresh_client({ defer_close = true })
		client.get("http://127.0.0.1:9000/v1/models", {}, { owner = "local-api" }, function() end)
		local exited = false
		local original_exit = state.exit_callback
		state.exit_callback = function(...)
			exited = true
			original_exit(...)
		end
		helpers.assert_true(client.cancel("local-api"))
		helpers.assert_eq(client.isActive("local-api"), false)
		helpers.assert_eq(exited, false, "logical cancellation does not acknowledge native process exit")
		helpers.assert_eq(state.process.closing, false, "the native process handle remains owned until exit")
		state.exit(0)
		helpers.assert_true(exited)
		helpers.assert_true(state.process.closing)
	end)
end)




helpers.describe("http_client: retained GET settlement", function()
	for _, refusal in ipairs({ "false", "error", "throw" }) do
		for _, synchronous in ipairs({ false, true }) do
			helpers.it("owned-close-admission: refused " .. refusal .. " callback (sync=" .. tostring(synchronous) .. ")", function()
				local client, state = fresh_client({
					refused_close_callback = refusal, refused_close_sync = synchronous, defer_close = true,
				})
				local terminals, settlements = 0, 0
				local operation = client.get_owned("http://127.0.0.1:9000/v1/models", {},
					{ owner = "local-api" }, function() terminals = terminals + 1 end)
				operation:on_settled(function() settlements = settlements + 1 end)
				state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n')
				for _, callback in ipairs(state.refused_closes) do callback() end
				helpers.assert_eq(operation:is_settled(), false, "a refused close callback cannot release its handle")
				helpers.assert_eq(terminals, 0)
				helpers.assert_eq(settlements, 0)
				local successor = client.get_owned("http://127.0.0.1:9000/v1/models", {},
					{ owner = "local-api" }, function() end)
				helpers.assert_eq(successor.started, false, "the exact owner retains unacknowledged resources")
				state.allow_closes = true
				helpers.assert_eq(operation:cancel(), false)
				for _, callback in ipairs(state.refused_closes) do callback() end
				helpers.assert_eq(operation:is_settled(), false, "an old attempt cannot acknowledge its accepted successor")
				state.ack_closes()
				helpers.assert_true(operation:is_settled())
				helpers.assert_eq(settlements, 1)
				helpers.assert_eq(terminals, 0, "cancellation suppresses the retained success")
				state.ack_closes()
				helpers.assert_eq(settlements, 1)
			end)
		end
	end

	helpers.it("owned-close-admission: accepted synchronous callbacks settle exactly once", function()
		local client, state = fresh_client()
		local terminals, settlements = 0, 0
		local operation = client.get_owned("http://127.0.0.1:9000/v1/models", {},
			{ owner = "local-api" }, function() terminals = terminals + 1 end)
		operation:on_settled(function() settlements = settlements + 1 end)
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n')
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(terminals, 1)
		helpers.assert_eq(settlements, 1)
		state.ack_closes()
		helpers.assert_eq(terminals, 1)
		helpers.assert_eq(settlements, 1)
	end)

	helpers.it("owned GET waits for actual exit and every native close acknowledgment", function()
		local client, state = fresh_client({ defer_close = true })
		local terminals, settled, result = 0, 0, nil
		local operation = client.get_owned("http://127.0.0.1:9000/v1/models", {},
			{ owner = "local-api", timeout_ms = 1500 }, function(value)
				terminals = terminals + 1; result = value
			end)
		helpers.assert_true(operation.started)
		helpers.assert_eq(operation:is_settled(), false)
		helpers.assert_true(operation:on_settled(function() settled = settled + 1 end))
		state.stdout('{"data":[]}\nERGOPTI_HTTP_STATUS:200\n')
		state.stdout(nil); state.stderr(nil)
		state.ack_closes()
		helpers.assert_eq(terminals, 0, "EOF and pipe closure do not acknowledge process exit")
		helpers.assert_eq(operation:is_settled(), false)
		state.exit(0)
		helpers.assert_eq(terminals, 0, "process exit does not acknowledge pending close callbacks")
		state.ack_closes()
		helpers.assert_eq(operation:is_settled(), true)
		helpers.assert_eq(settled, 1)
		helpers.assert_eq(terminals, 1)
		helpers.assert_eq(result.status, 200)
		helpers.assert_eq(result.body, '{"data":[]}')
	end)

	helpers.it("owned GET retries refused close and never reports it as settlement", function()
		local client, state = fresh_client({ close_failure = true, defer_close = true })
		local receipt
		local operation = client.get_owned("http://127.0.0.1:9000/v1/models", {},
			{ owner = "local-api" }, function(value) receipt = value end)
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n')
		helpers.assert_eq(receipt, nil)
		helpers.assert_eq(operation:is_settled(), false)
		state.allow_closes = true
		helpers.assert_eq(operation:cancel(), false)
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(receipt, nil, "cancelling a cleanup retry suppresses its pending success")
	end)

	helpers.it("owned GET failed spawn settles only after its allocated handles close", function()
		local client, state = fresh_client({ spawn_failure = true, defer_close = true })
		local failures = 0
		local operation = client.get_owned("http://127.0.0.1:9000/v1/models", {},
			{ owner = "local-api" }, function() failures = failures + 1 end)
		helpers.assert_eq(operation.started, false)
		helpers.assert_eq(operation:is_settled(), false)
		helpers.assert_eq(failures, 0)
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(failures, 1)
	end)
end)




helpers.describe("http_client: owned GET refusal boundaries", function()
	helpers.it("owned GET captures partial allocations before a later constructor throws", function()
		local client, state = fresh_client({ allocation_failure_at = 2, defer_close = true })
		local receipt
		local operation = client.get_owned("http://127.0.0.1:9000/v1/models", {},
			{ owner = "local-api" }, function(value) receipt = value end)
		helpers.assert_eq(operation.started, false)
		helpers.assert_eq(operation:is_settled(), false)
		helpers.assert_eq(#state.handles, 1)
		helpers.assert_eq(receipt, nil)
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(receipt.error, "libuv handle allocation failed")
	end)

	helpers.it("owned GET timeout retains refused termination debt and retries the exact process", function()
		local client, state = fresh_client({ kill_failure = true, defer_close = true })
		local terminals = 0
		local operation = client.get_owned("http://127.0.0.1:9000/v1/models", {},
			{ owner = "local-api" }, function() terminals = terminals + 1 end)
		state.timer.callback()
		state.ack_closes()
		helpers.assert_eq(client.isActive("local-api"), false)
		helpers.assert_eq(operation:is_settled(), false)
		helpers.assert_eq(terminals, 0)
		helpers.assert_eq(operation:cancel(), false)
		state.allow_kills = true
		helpers.assert_eq(operation:cancel(), false)
		helpers.assert_eq(state.kills[#state.kills].pid, -4321)
		state.exit(0)
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(terminals, 0, "cancel intent must suppress the pending timeout receipt")
	end)

	helpers.it("owned GET refuses an incomplete 200 and preserves genuine HTTP auth failure", function()
		for _, case in ipairs({
			{ status = 200, code = 18, error = "curl exited with code 18" },
			{ status = 401, code = 22, error = "HTTP 401" },
		}) do
			local client, state = fresh_client({ defer_close = true })
			local result
			local operation = client.get_owned("http://127.0.0.1:9000/v1/models", {},
				{ owner = "local-api" }, function(value) result = value end)
			state.complete_request(1, '{"data":[]}\nERGOPTI_HTTP_STATUS:' .. case.status .. '\n', case.code)
			state.ack_closes()
			helpers.assert_true(operation:is_settled())
			helpers.assert_eq(result.ok, false)
			helpers.assert_eq(result.status, case.status)
			helpers.assert_eq(result.error, case.error)
		end
	end)

	helpers.it("owned GET timer activation refusal waits for allocated native handle closure", function()
		local client, state = fresh_client({ timer_failure = true, defer_close = true })
		local receipt
		local operation = client.get_owned("http://127.0.0.1:9000/v1/models", {},
			{ owner = "local-api" }, function(value) receipt = value end)
		helpers.assert_eq(operation.started, false)
		helpers.assert_eq(operation:is_settled(), false)
		helpers.assert_eq(#state.requests, 0)
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(receipt.error, "timeout activation failed")
	end)
end)




helpers.describe("http_client: owned GET construction boundary", function()
	helpers.it("owned GET request construction refusal retains already allocated native handles", function()
		local client, state = fresh_client({ defer_close = true })
		local receipt
		local hostile_header = setmetatable({}, { __tostring = function() error("private header must not appear") end })
		local operation = client.get_owned("http://127.0.0.1:9000/v1/models", { Authorization = hostile_header },
			{ owner = "local-api" }, function(value) receipt = value end)
		helpers.assert_eq(operation.started, false)
		helpers.assert_eq(operation:is_settled(), false)
		helpers.assert_eq(#state.requests, 0)
		helpers.assert_eq(receipt, nil)
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(receipt.error, "curl request construction failed")
	end)
end)




helpers.describe("http_client: request body pipe refusal boundaries", function()
	for _, case in ipairs({
		{ name = "handle allocation", options = { allocation_failure_at = 5 }, descriptors = 0 },
		{ name = "anonymous pipe allocation", options = { body_pipe_failure = true }, descriptors = 0 },
		{ name = "pipe attachment", options = { body_attach_failure = true }, descriptors = 2 },
		{ name = "spawn", options = { spawn_failure = true }, descriptors = 2 },
	}) do
		helpers.it("linux-http-body-pipe: simulated " .. case.name .. " refusal retires every admitted resource", function()
			local client, state = fresh_client(case.options)
			local result, callbacks = nil, 0
			helpers.assert_eq(client.post("http://127.0.0.1:9000/", {}, '{"text":"literal"}', function(value)
				result, callbacks = value, callbacks + 1
			end), false)
			helpers.assert_true(result and result.ok == false and result.status == 0)
			helpers.assert_eq(callbacks, 1)
			helpers.assert_eq(#state.requests, 0)
			helpers.assert_eq(#state.descriptor_closes, case.descriptors)
			for _, handle in ipairs(state.handles) do helpers.assert_true(handle.closing, "an admitted native handle was lost") end
		end)
	end

	for _, asynchronous in ipairs({ false, true }) do
		helpers.it("linux-http-body-pipe: simulated " .. (asynchronous and "asynchronous" or "immediate") .. " write refusal fences late receipts", function()
			local client, state = fresh_client({ body_write_failure = not asynchronous, defer_body_write = asynchronous })
			local result, callbacks = nil, 0
			local dispatched = client.post("http://127.0.0.1:9000/", {}, '{"text":"literal"}', function(value)
				result, callbacks = value, callbacks + 1
			end)
			helpers.assert_eq(dispatched, asynchronous)
			if asynchronous then state.body_written("EPIPE") end
			helpers.assert_true(result and result.ok == false and result.error == "curl body write failed")
			helpers.assert_eq(callbacks, 1)
			helpers.assert_eq(#state.kills, 2)
			helpers.assert_eq(#state.descriptor_closes, 2)
			state.complete_request(1, "abc\nERGOPTI_HTTP_STATUS:200\n")
			helpers.assert_eq(callbacks, 1)
			for _, handle in ipairs(state.handles) do helpers.assert_true(handle.closing) end
		end)
	end

	for _, cancelled in ipairs({ false, true }) do
		helpers.it("linux-http-body-pipe: " .. (cancelled and "cancellation" or "deadline") .. " closes a pending writer without affecting its successor", function()
			local client, state = fresh_client({ defer_body_write = true })
			local callbacks, result, successor = 0, nil, nil
			helpers.assert_true(client.post("http://127.0.0.1:9000/", {}, '{"text":"literal"}', function(value)
				result, callbacks = value, callbacks + 1
			end, { owner = "body-owner" }))
			local completed_write, writer = state.body_written, state.body_pipe
			helpers.assert_true(not writer.closing)
			if cancelled then helpers.assert_true(client.cancel("body-owner")) else state.timer.callback() end
			helpers.assert_true(writer.closing)
			helpers.assert_eq(callbacks, cancelled and 0 or 1)
			if not cancelled then helpers.assert_eq(result.error, "timeout") end
			helpers.assert_eq(#state.descriptor_closes, 2)
			helpers.assert_true(client.get("http://127.0.0.1:9000/fresh", {}, { owner = "body-owner" },
				function(value) successor = value end))
			completed_write("EPIPE")
			helpers.assert_true(client.isActive("body-owner"), "a stale body write retired its new owner")
			state.complete_request(1, "old\nERGOPTI_HTTP_STATUS:200\n")
			state.complete_request(2, "abc\nERGOPTI_HTTP_STATUS:200\n")
			helpers.assert_true(successor and successor.ok and successor.body == "abc")
			helpers.assert_eq(callbacks, cancelled and 0 or 1)
		end)
	end

	for _, method in ipairs({ "post", "postStream" }) do
		helpers.it("linux-http-body-pipe: " .. method .. " retains literal NUL refusal before replacing a valid owner", function()
			local client, state = fresh_client()
			local good, bad = nil, nil
			helpers.assert_true(client.get("http://127.0.0.1:9000/held", {}, { owner = "kept" }, function(value) good = value end))
			local handles = #state.handles
			local complete = function(value) bad = value end
			local dispatched
			if method == "post" then dispatched = client.post("http://127.0.0.1:9000/", {}, "before\0after", complete, { owner = "kept" })
			else dispatched = client.postStream("http://127.0.0.1:9000/", {}, "before\0after", { owner = "kept" }, function() end, complete) end
			helpers.assert_eq(dispatched, false)
			helpers.assert_true(bad and bad.ok == false and bad.status == 0)
			helpers.assert_eq(#state.handles, handles)
			helpers.assert_eq(#state.requests, 1)
			helpers.assert_eq(#state.kills, 0)
			helpers.assert_true(client.isActive("kept"))
			state.complete_request(1, "abc\nERGOPTI_HTTP_STATUS:200\n")
			helpers.assert_true(good and good.ok and good.body == "abc")
		end)
	end
end)




helpers.describe("http_client: exceptional body cleanup ownership", function()
	for _, receipt in ipairs({ "nil", "false", "throw" }) do
		for _, raw in ipairs({ false, true }) do
			helpers.it("linux-http-body-cleanup: simulated " .. receipt .. (raw and " raw rollback" or " reader handle") .. " refusal retains and retries its exact owner", function()
				local options = { defer_close = true }
				if raw then options.body_attach_failure = true; options.raw_close_receipt = receipt
				else options.body_handle_close_receipt = receipt end
				local client, state = fresh_client(options)
				local callbacks, blocked = 0, nil
				helpers.assert_eq(client.post("http://127.0.0.1:9000/", {}, "{}", function() callbacks = callbacks + 1 end, { owner = "body-debt" }), false)
				state.ack_closes()
				helpers.assert_eq(callbacks, 0)
				local candidate = client.get_owned("http://127.0.0.1:9000/", {}, { owner = "body-debt" }, function(value) blocked = value end)
				helpers.assert_eq(candidate.started, false)
				helpers.assert_eq(blocked.error, "previous request cleanup pending")
				helpers.assert_eq(client.cancel("body-debt"), false)
				state.allow_closes = true
				if not raw then state.exit(0) end
				client.cancel("body-debt")
				state.ack_closes()
				helpers.assert_true(client.cancel("body-debt"))
				helpers.assert_eq(callbacks, 0)
				for _, fd in ipairs(state.descriptors) do helpers.assert_nil(state.identities[fd]) end
				for _, handle in ipairs(state.handles) do helpers.assert_true(handle.closing) end
			end)
		end
		for _, reused in ipairs({ false, true }) do
			helpers.it("linux-http-body-cleanup: simulated " .. receipt .. " after retirement " .. (reused and "preserves reused descriptor" or "avoids EBADF retry"), function()
				local client, state = fresh_client({ body_attach_failure = true, raw_close_receipt = receipt,
					close_after_retirement = true, reuse_descriptor = reused })
				local callbacks = 0
				helpers.assert_eq(client.post("http://127.0.0.1:9000/", {}, "{}", function() callbacks = callbacks + 1 end, { owner = "retired-body" }), false)
				helpers.assert_eq(callbacks, 0)
				helpers.assert_true(client.cancel("retired-body"))
				helpers.assert_eq(#state.descriptor_closes, 2, "a retired or reused numeric descriptor must never be closed twice")
				for _, fd in ipairs(state.descriptors) do
					if reused then helpers.assert_eq(state.identities[fd].ino, 99) else helpers.assert_nil(state.identities[fd]) end
				end
				helpers.assert_eq(callbacks, 0)
			end)
		end
	end

	helpers.it("linux-http-body-cleanup: simulated body partial allocation with close refusal keeps captured handles fenced", function()
		local client, state = fresh_client({ allocation_failure_at = 2, close_failure = true, defer_close = true })
		local callbacks, blocked = 0, nil
		helpers.assert_eq(client.post("http://127.0.0.1:9000/", {}, "{}", function() callbacks = callbacks + 1 end, { owner = "body-allocation" }), false)
		helpers.assert_eq(#state.handles, 1)
		helpers.assert_eq(callbacks, 0)
		local candidate = client.get_owned("http://127.0.0.1:9000/", {}, { owner = "body-allocation" }, function(value) blocked = value end)
		helpers.assert_eq(candidate.started, false)
		helpers.assert_eq(blocked.error, "previous request cleanup pending")
		state.allow_closes = true
		helpers.assert_eq(client.cancel("body-allocation"), false)
		state.ack_closes()
		helpers.assert_true(client.cancel("body-allocation"))
		helpers.assert_eq(callbacks, 0)
	end)

	helpers.it("linux-http-body-cleanup: native exit event retries simulated reader close refusal before publishing", function()
		local client, state = fresh_client({ body_handle_close_receipt = "nil", defer_close = true })
		local callbacks, result = 0, nil
		helpers.assert_eq(client.post("http://127.0.0.1:9000/", {}, "{}", function(value) result, callbacks = value, callbacks + 1 end), false)
		state.ack_closes()
		helpers.assert_eq(callbacks, 0)
		state.allow_closes = true
		state.exit(0)
		helpers.assert_eq(callbacks, 0)
		state.ack_closes()
		helpers.assert_eq(callbacks, 1)
		helpers.assert_eq(result.error, "curl body pipe retirement failed")
		state.exit(0); state.ack_closes()
		helpers.assert_eq(callbacks, 1)
	end)
end)




helpers.describe("http_client: native body allocator compatibility", function()
	helpers.it("linux-http-body-cleanup: current luv allocator requests nonblocking native pipe ends", function()
		local allocator = dofile("infra/http_body_pipe.lua")
		local pair = allocator.allocate({ pipe = function(read_flags, write_flags)
			helpers.assert_true(read_flags.nonblock and write_flags.nonblock)
			return { read = 40, write = 41 }
		end })
		helpers.assert_eq(pair.read, 40)
		helpers.assert_eq(pair.write, 41)
	end)

	for _, refused in ipairs({ false, true }) do
		helpers.it("linux-http-body-cleanup: simulated Jammy binding uses pipe2 with atomic native flags " .. (refused and "refusal" or "success"), function()
			local previous = package.loaded["ffi"]
			local calls = 0
			package.loaded["ffi"] = { os = "Linux", cdef = function() end, new = function() return {} end,
				C = { pipe2 = function(descriptors, flags)
					calls = calls + 1
					helpers.assert_eq(flags, 2048 + 524288)
					if refused then return -1 end
					descriptors[0], descriptors[1] = 70, 71
					return 0
				end } }
			local ok, pair, detail = pcall(function() return dofile("infra/http_body_pipe.lua").allocate({}) end)
			package.loaded["ffi"] = previous
			helpers.assert_true(ok)
			helpers.assert_eq(calls, 1)
			if refused then helpers.assert_nil(pair); helpers.assert_eq(detail, "native body pipe allocation refused")
			else helpers.assert_eq(pair.read, 70); helpers.assert_eq(pair.write, 71) end
		end)
	end

	helpers.it("linux-http-body-cleanup: unavailable native allocation refuses without a synthetic pipe", function()
		local previous = package.loaded["ffi"]
		package.loaded["ffi"] = { os = "unavailable" }
		local ok, pair, detail = pcall(function() return dofile("infra/http_body_pipe.lua").allocate({}) end)
		package.loaded["ffi"] = previous
		helpers.assert_true(ok)
		helpers.assert_nil(pair)
		helpers.assert_eq(detail, "native body pipe unavailable")
	end)
end)




helpers.describe("http_client: unknown raw body identity", function()
	helpers.it("linux-http-body-cleanup: simulated missing initial identity never authorizes closing a later descriptor", function()
		local client, state = fresh_client({ body_metadata_failure = true })
		local callbacks, blocked = 0, nil
		helpers.assert_eq(client.post("http://127.0.0.1:9000/", {}, "{}", function() callbacks = callbacks + 1 end, { owner = "unknown-body" }), false)
		helpers.assert_eq(callbacks, 0)
		for _, fd in ipairs(state.descriptors) do state.identities[fd] = { dev = 9, ino = 99, type = "file" } end
		state.allow_metadata = true
		helpers.assert_eq(client.cancel("unknown-body"), false)
		helpers.assert_eq(#state.descriptor_closes, 0)
		for _, fd in ipairs(state.descriptors) do helpers.assert_eq(state.identities[fd].ino, 99) end
		local candidate = client.get_owned("http://127.0.0.1:9000/", {}, { owner = "unknown-body" }, function(value) blocked = value end)
		helpers.assert_eq(candidate.started, false)
		helpers.assert_eq(blocked.error, "previous request cleanup pending")
		for _, fd in ipairs(state.descriptors) do state.identities[fd] = nil end
		helpers.assert_true(client.cancel("unknown-body"), "EBADF still proves retirement without inventing descriptor ownership")
		helpers.assert_eq(callbacks, 0)
	end)
end)

