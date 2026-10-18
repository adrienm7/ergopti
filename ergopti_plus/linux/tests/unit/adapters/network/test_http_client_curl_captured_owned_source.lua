--- tests/unit/adapters/network/test_http_client_curl_captured_owned_source.lua

--- ==============================================================================
--- MODULE: Asynchronous HTTP Process Ownership
--- DESCRIPTION:
--- Drives the Linux HttpClient through a controllable libuv double. The tests
--- prove dispatch returns before output, timeout and cancel kill the detached
--- process group, and exactly one terminal callback survives late events.
--- ==============================================================================

package.loaded["tests.support.adapters.network.http_client_curl_fixture"] = nil
local Fixture = require("tests.support.adapters.network.http_client_curl_fixture")
local helpers, fresh_client, native_write_out, authorizer_client, redirect_engine_client, redirect_options, GOOD_REDIRECT =
	Fixture.helpers, Fixture.fresh_client, Fixture.native_write_out, Fixture.authorizer_client, Fixture.redirect_engine_client, Fixture.redirect_options, Fixture.GOOD_REDIRECT




helpers.describe("http_client: captured owned source capability", function()
	for _, invalid in ipairs({ false, true, "callable", {} }) do
		helpers.it("owned-authorizer: wrong capability type " .. type(invalid) .. " refuses without allocation or response", function()
			local client, state = fresh_client()
			local responses = 0
			local operation = client.get_owned("http://127.0.0.1:9000/models", {},
				{ authorized = invalid }, function() responses = responses + 1 end)
			helpers.assert_eq(operation.started, false)
			helpers.assert_true(operation:is_settled(), "a wrong typed capability acquires no physical work")
			helpers.assert_eq(#state.handles, 0)
			helpers.assert_eq(#state.requests, 0)
			helpers.assert_eq(responses, 0)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "number", "string", "throw" }) do
		helpers.it("owned-authorizer: initial " .. mode .. " is a settled noncallback refusal", function()
			local client, state = fresh_client()
			local responses, calls = 0, 0
			local operation = client.get_owned("http://127.0.0.1:9000/models", {}, { owner = "source", authorized = function()
				calls = calls + 1
				if mode == "throw" then error("synthetic authorizer exception") end
				if mode == "false" then return false elseif mode == "number" then return 1 elseif mode == "string" then return "true" end
			end }, function() responses = responses + 1 end)
			helpers.assert_eq(operation.started, false)
			helpers.assert_true(operation:is_settled())
			helpers.assert_eq(#state.requests, 0)
			helpers.assert_eq(#state.handles, 0)
			helpers.assert_eq(responses, 0)
			helpers.assert_eq(calls, 1)
			local successor = client.get_owned("http://127.0.0.1:9000/models", {}, { owner = "source" }, function() end)
			helpers.assert_true(successor.started, "no nonexistent cleanup debt can retain the source owner")
			state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n')
		end)
	end

	helpers.it("owned-authorizer: reserves before initial capability reentry and never calls a blocked successor capability", function()
		local client, state = fresh_client()
		local nested, nested_calls, nested_responses, entered = nil, 0, 0, false
		local operation = client.get_owned("http://127.0.0.1:9000/models", {}, { owner = "source", authorized = function()
			if not entered then
				entered = true
				nested = client.get_owned("http://127.0.0.1:9000/models", {}, { owner = "source", authorized = function()
					nested_calls = nested_calls + 1; return true
				end }, function() nested_responses = nested_responses + 1 end)
			end
			return true
		end }, function() end)
		helpers.assert_true(operation.started)
		helpers.assert_eq(nested.started, false)
		helpers.assert_true(nested:is_settled())
		helpers.assert_eq(nested_calls, 0)
		helpers.assert_eq(nested_responses, 0, "a blocked authorized successor cannot publish a rejection receipt")
		helpers.assert_eq(#state.requests, 1)
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n')
	end)

	helpers.it("owned-authorizer: captures the originating function once despite caller option replacement", function()
		local client, state = fresh_client()
		local calls, replacement_calls, responses = 0, 0, 0
		local options = { owner = "source" }
		options.authorized = function()
			calls = calls + 1
			options.authorized = function() replacement_calls = replacement_calls + 1; return false end
			return true
		end
		local operation = client.get_owned("http://127.0.0.1:9000/models", {}, options, function() responses = responses + 1 end)
		helpers.assert_true(operation.started)
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n')
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(calls, 3, "initial, last dispatch and physically settled delivery use the original capability")
		helpers.assert_eq(replacement_calls, 0)
		helpers.assert_eq(responses, 1)
	end)

	helpers.it("owned-authorizer: credential construction withdrawal refuses before spawn and waits for allocated ACKs", function()
		local client, state = fresh_client({ defer_close = true })
		local current, responses, constructions = true, 0, 0
		local header = setmetatable({}, { __tostring = function()
			constructions = constructions + 1; current = false; return "SyntheticCredential"
		end })
		local operation = client.get_owned("http://127.0.0.1:9000/models", { Authorization = header },
			{ owner = "source", authorized = function() return current end }, function() responses = responses + 1 end)
		helpers.assert_eq(#state.requests, 0, "the last credential callback can withdraw physical dispatch")
		helpers.assert_eq(constructions, 1)
		helpers.assert_eq(operation.started, false)
		helpers.assert_eq(operation:is_settled(), false)
		local successor = client.get_owned("http://127.0.0.1:9000/models", {}, { owner = "source" }, function() end)
		helpers.assert_eq(successor.started, false)
		helpers.assert_eq(#state.handles, 4)
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(responses, 0)
	end)

	helpers.it("owned-authorizer: native setup withdrawal is checked after timer admission before spawn", function()
		local current = true
		local client, state = authorizer_client({ defer_close = true }, function(fake)
			local start = fake.timer_start
			fake.timer_start = function(...)
				local accepted = start(...); current = false; return accepted
			end
		end)
		local responses = 0
		local operation = client.get_owned("http://127.0.0.1:9000/models", {},
			{ owner = "source", authorized = function() return current end }, function() responses = responses + 1 end)
		helpers.assert_eq(#state.requests, 0)
		helpers.assert_eq(operation.started, false)
		helpers.assert_eq(operation:is_settled(), false)
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(responses, 0)
	end)

	for _, mode in ipairs({ "false", "throw" }) do
		helpers.it("owned-authorizer: last dispatch " .. mode .. " suppresses callback without discarding refused-close debt", function()
			local client, state = fresh_client({ defer_close = true, close_failure = true })
			local calls, responses = 0, 0
			local operation = client.get_owned("http://127.0.0.1:9000/models", {}, { owner = "source", authorized = function()
				calls = calls + 1
				if calls == 1 then return true end
				if mode == "throw" then error("last admission revoked") end
				return false
			end }, function() responses = responses + 1 end)
			helpers.assert_eq(#state.requests, 0)
			helpers.assert_eq(operation.started, false)
			helpers.assert_eq(operation:is_settled(), false)
			state.allow_closes = true
			operation:cancel()
			state.ack_closes()
			helpers.assert_true(operation:is_settled())
			helpers.assert_eq(responses, 0)
		end)
	end

	helpers.it("owned-authorizer: late source withdrawal suppresses response after exact native close acknowledgments", function()
		local client, state = fresh_client({ defer_close = true })
		local current, responses, settled = true, 0, 0
		local operation = client.get_owned("http://127.0.0.1:9000/models", {},
			{ owner = "source", authorized = function() return current end }, function() responses = responses + 1 end)
		operation:on_settled(function() settled = settled + 1 end)
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n')
		helpers.assert_eq(operation:is_settled(), false)
		current = false
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(responses, 0)
		helpers.assert_eq(settled, 1)
		current = true
		state.ack_closes(); state.exit(0)
		helpers.assert_eq(responses, 0, "a restored predicate cannot resurrect an already withdrawn delivery")
	end)

	helpers.it("owned-authorizer: descendant and refused close debts remain independent of revoked source", function()
		local client, state = fresh_client({ defer_close = true, descendants_alive = true })
		local current, responses = true, 0
		local operation = client.get_owned("http://127.0.0.1:9000/models", {},
			{ owner = "source", authorized = function() return current end }, function() responses = responses + 1 end)
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n'); state.ack_closes()
		current = false
		helpers.assert_eq(operation:is_settled(), false)
		local successor = client.get_owned("http://127.0.0.1:9000/models", {}, { owner = "source" }, function() end)
		helpers.assert_eq(successor.started, false)
		state.groups[4321] = false
		state.timer.callback()
		helpers.assert_eq(operation:is_settled(), false, "native absence does not acknowledge the referenced monitor close")
		state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(responses, 0)
	end)

	helpers.it("owned-authorizer: delivery reentry cannot start a successor before the predicate returns", function()
		local client, state = fresh_client({ defer_close = true })
		local calls, nested, responses = 0, nil, 0
		local operation = client.get_owned("http://127.0.0.1:9000/models", {}, { owner = "source", authorized = function()
			calls = calls + 1
			if calls == 3 then nested = client.get_owned("http://127.0.0.1:9000/models", {}, { owner = "source" }, function() end) end
			return true
		end }, function() responses = responses + 1 end)
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n'); state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(nested.started, false)
		helpers.assert_true(nested:is_settled())
		helpers.assert_eq(#state.requests, 1)
		helpers.assert_eq(responses, 1)
	end)

	helpers.it("owned-authorizer: cancelling inside final capability cannot recurse or publish after cancel intent", function()
		local client, state = fresh_client({ defer_close = true })
		local calls, responses, operation, nested_cancel = 0, 0, nil, nil
		operation = client.get_owned("http://127.0.0.1:9000/models", {}, { owner = "source", authorized = function()
			calls = calls + 1
			if calls == 3 then nested_cancel = operation:cancel() end
			return true
		end }, function() responses = responses + 1 end)
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n'); state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(calls, 3)
		helpers.assert_eq(nested_cancel, false, "foreign authorization remains in flight until it returns")
		helpers.assert_eq(responses, 0)
	end)

	helpers.it("owned-authorizer: cancelled requests never invoke a final capability or deliver a late result", function()
		local client, state = fresh_client({ defer_close = true })
		local calls, responses = 0, 0
		local operation = client.get_owned("http://127.0.0.1:9000/models", {}, { owner = "source", authorized = function()
			calls = calls + 1; return true
		end }, function() responses = responses + 1 end)
		operation:cancel()
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n'); state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(calls, 2)
		helpers.assert_eq(responses, 0)
	end)

	helpers.it("owned-authorizer: metadata exception after reservation releases only its own source owner", function()
		local client, state = fresh_client()
		local responses, response = 0, nil
		local policy = require("infra.http_redirect_policy")
		local original_policy = policy.allows_native_follow
		policy.allows_native_follow = function() error("synthetic metadata policy exception") end
		local called, operation = pcall(client.get_owned, "http://127.0.0.1:9000/models", {},
			{ owner = "source", follow_redirects = true, authorized = function() return true end }, function(value)
				responses = responses + 1; response = value
			end)
		policy.allows_native_follow = original_policy
		helpers.assert_true(called, "metadata exceptions must retire the exact reserved operation rather than escape")
		helpers.assert_eq(operation.started, false)
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(#state.requests, 0)
		helpers.assert_eq(responses, 1)
		helpers.assert_type(response, "table")
		helpers.assert_eq(response.ok, false)
	end)

	helpers.it("owned-authorizer: throwing final capability settles physical debt without publishing", function()
		local client, state = fresh_client({ defer_close = true })
		local calls, responses = 0, 0
		local operation = client.get_owned("http://127.0.0.1:9000/models", {}, { owner = "source", authorized = function()
			calls = calls + 1
			if calls == 3 then error("source capability withdrawn at final acknowledgment") end
			return true
		end }, function() responses = responses + 1 end)
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n'); state.ack_closes()
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(calls, 3)
		helpers.assert_eq(responses, 0)
	end)

	helpers.it("owned-authorizer: late old callbacks cannot consult old source or affect an admitted successor", function()
		local client, state = fresh_client({ defer_close = true })
		local current, old_calls, old_responses, new_responses = true, 0, 0, 0
		local old = client.get_owned("http://127.0.0.1:9000/models", {}, { owner = "source", authorized = function()
			old_calls = old_calls + 1; return current
		end }, function() old_responses = old_responses + 1 end)
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n'); current = false; state.ack_closes()
		helpers.assert_true(old:is_settled())
		helpers.assert_eq(old_responses, 0)
		local calls, kills = old_calls, #state.kills
		local successor = client.get_owned("http://127.0.0.1:9000/models", {},
			{ owner = "source", authorized = function() return true end }, function() new_responses = new_responses + 1 end)
		helpers.assert_true(successor.started)
		state.complete_request(1, 'stale\nERGOPTI_HTTP_STATUS:200\n'); state.ack_closes()
		helpers.assert_eq(old_calls, calls)
		helpers.assert_eq(#state.kills, kills)
		helpers.assert_eq(successor:is_settled(), false)
		helpers.assert_eq(new_responses, 0)
		state.complete_request(2, '[]\nERGOPTI_HTTP_STATUS:200\n'); state.ack_closes()
		helpers.assert_true(successor:is_settled())
		helpers.assert_eq(new_responses, 1)
	end)

	helpers.it("owned-authorizer: legacy boolean GET ignores the optional owned-only capability", function()
		local client, state = fresh_client()
		local calls, responses = 0, 0
		helpers.assert_true(client.get("http://127.0.0.1:9000/models", {}, { authorized = function()
			calls = calls + 1; return false
		end }, function() responses = responses + 1 end))
		state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n')
		helpers.assert_eq(calls, 0)
		helpers.assert_eq(responses, 1)
	end)
end)




--- Independent additive owned streaming POST admission/retirement controls.
helpers.describe("http_client: owned streaming POST", function()
	for _, invalid in ipairs({false,true,"callable",{}}) do
		helpers.it("owned-post: malformed capability " .. type(invalid) .. " owns no resources",function()
			local client,state=fresh_client();local chunks,results=0,0
			local op=client.post_stream_owned("http://127.0.0.1:9000/pull",{},"{}",{authorized=invalid},function()chunks=chunks+1 end,function()results=results+1 end)
			helpers.assert_eq(op.started,false);helpers.assert_true(op:is_settled());helpers.assert_eq(#state.handles,0);helpers.assert_eq(#state.requests,0);helpers.assert_eq(chunks,0);helpers.assert_eq(results,0)
		end)
	end
	for _,mode in ipairs({"false","nil","number","string","throw"}) do
		helpers.it("owned-post: initial " .. mode .. " admission precedes body/header allocation",function()
			local client,state=fresh_client();local constructions,results=0,0
			local header=setmetatable({},{__tostring=function()constructions=constructions+1;return "credential" end})
			local op=client.post_stream_owned("http://127.0.0.1:9000/pull",{Authorization=header},"{}",{authorized=function()
				if mode=="throw" then error("independent refusal") end
				if mode=="false" then return false elseif mode=="number" then return 1 elseif mode=="string" then return "true" end
			end},function()end,function()results=results+1 end)
			helpers.assert_eq(op.started,false);helpers.assert_true(op:is_settled());helpers.assert_eq(#state.handles,0);helpers.assert_eq(#state.descriptors,0);helpers.assert_eq(constructions,0);helpers.assert_eq(results,0)
		end)
	end
	helpers.it("owned-post: reservation prevents same-owner authorizer reentry and sends exact private body",function()
		local client,state=fresh_client();local entered,nested,nested_calls=false,nil,0
		local body='@literal\n{"escaped":"\\u0000"}'
		local op=client.post_stream_owned("http://127.0.0.1:9000/pull",{},body,{owner="post",buffered=true,authorized=function()
			if not entered then entered=true;nested=client.post_stream_owned("http://127.0.0.1:9000/pull",{},"nested",{owner="post",authorized=function()nested_calls=nested_calls+1;return true end},function()end,function()end) end;return true
		end},function()end,function()end)
		helpers.assert_true(op.started);helpers.assert_eq(nested.started,false);helpers.assert_true(nested:is_settled());helpers.assert_eq(nested_calls,0);helpers.assert_eq(#state.requests,1);helpers.assert_eq(state.body,body)
		helpers.assert_true(state.config:find('data-binary = "@/dev/fd/3"',1,true)~=nil);helpers.assert_eq(state.config:find(body,1,true),nil)
		helpers.assert_true(table.concat(state.options.args," "):find("%{stderr}",1,true)~=nil,"caller buffered option cannot alter owned streaming protocol")
		state.stderr("\nERGOPTI_HTTP_STATUS:200\n");state.complete();helpers.assert_true(op:is_settled())
	end)
	helpers.it("owned-post: original source capability remains captured through option replacement and chunks",function()
		local client,state=fresh_client();local calls,replacement_calls,chunk,result=0,0,nil,nil;local options={owner="post"}
		options.authorized=function()calls=calls+1;options.authorized=function()replacement_calls=replacement_calls+1;return false end;return true end
		local op=client.post_stream_owned("http://127.0.0.1:9000/pull",{},"{}",options,function(value)chunk=value end,function(value)result=value end)
		state.stdout("{\"status\":\"success\"}\n");state.stderr("\nERGOPTI_HTTP_STATUS:200\n");state.complete()
		helpers.assert_true(op:is_settled());helpers.assert_eq(calls,4);helpers.assert_eq(replacement_calls,0);helpers.assert_eq(chunk,'{"status":"success"}\n');helpers.assert_true(result and result.ok);helpers.assert_eq(result.status,200)
	end)
	helpers.it("owned-post: final credential revocation retains every acquired body handle ACK",function()
		local client,state=fresh_client({defer_close=true});local current,results=true,0
		local header=setmetatable({},{__tostring=function()current=false;return "credential" end})
		local op=client.post_stream_owned("http://127.0.0.1:9000/pull",{Authorization=header},"{}",{owner="post",authorized=function()return current end},function()end,function()results=results+1 end)
		helpers.assert_eq(op.started,false);helpers.assert_eq(#state.requests,0);helpers.assert_eq(#state.handles,6);helpers.assert_eq(#state.descriptors,2);helpers.assert_eq(op:is_settled(),false)
		local successor=client.post_stream_owned("http://127.0.0.1:9000/pull",{},"{}",{owner="post"},function()end,function()end);helpers.assert_eq(successor.started,false)
		state.ack_closes();helpers.assert_true(op:is_settled());helpers.assert_eq(results,0)
	end)
	helpers.it("owned-post: revoked chunks never dispatch and leader exit cannot retire descendants or monitor",function()
		local client,state=fresh_client({defer_close=true,descendants_alive=true});local current,chunks,results,settled=true,0,0,0
		local op=client.post_stream_owned("http://127.0.0.1:9000/pull",{},"{}",{owner="post",authorized=function()return current end},function()chunks=chunks+1 end,function()results=results+1 end);op:on_settled(function()settled=settled+1 end)
		current=false;state.stdout("stale");helpers.assert_eq(chunks,0);helpers.assert_eq(op:is_settled(),false)
		state.exit();state.ack_closes();helpers.assert_eq(op:is_settled(),false);helpers.assert_eq(settled,0)
		local successor=client.post_stream_owned("http://127.0.0.1:9000/pull",{},"{}",{owner="post"},function()end,function()end);helpers.assert_eq(successor.started,false)
		state.groups[4321]=false;state.timer.callback();helpers.assert_eq(op:is_settled(),false);state.ack_closes();helpers.assert_true(op:is_settled());helpers.assert_eq(settled,1);helpers.assert_eq(results,0)
	end)
	helpers.it("owned-post: raw body FD close refusal cannot masquerade as complete admission failure",function()
		local client,state=fresh_client({defer_close=true,body_attach_failure=true,raw_close_receipt="false"});local result
		local op=client.post_stream_owned("http://127.0.0.1:9000/pull",{},"{}",{owner="post"},function()end,function(value)result=value end)
		helpers.assert_eq(op.started,false);helpers.assert_eq(op:is_settled(),false);helpers.assert_eq(#state.descriptors,2);helpers.assert_eq(#state.requests,0);helpers.assert_eq(result,nil)
		state.ack_closes();helpers.assert_eq(op:is_settled(),false);state.allow_closes=true;op:cancel();state.ack_closes();helpers.assert_true(op:is_settled());helpers.assert_eq(result,nil)
	end)
	helpers.it("owned-post: response source fence happens after every physical close ACK",function()
		local client,state=fresh_client({defer_close=true});local current,result,settled=true,nil,0
		local op=client.post_stream_owned("http://127.0.0.1:9000/pull",{},"{}",{authorized=function()return current end},function()end,function(value)result=value end);op:on_settled(function()settled=settled+1 end)
		state.stderr("\nERGOPTI_HTTP_STATUS:200\n");state.complete();helpers.assert_eq(op:is_settled(),false);helpers.assert_eq(result,nil);current=false;state.ack_closes();helpers.assert_true(op:is_settled());helpers.assert_eq(result,nil);helpers.assert_eq(settled,1)
	end)
end)




helpers.describe("http_client: synchronous owned publication",function()
 helpers.it("owned-post: eager revoked chunk cannot republish its terminal logical owner",function()
  local calls,chunks,result=0,0,nil
  local client,state=authorizer_client({defer_close=true},function(fake,state)
   local native_close=fake.close
   fake.close=function(handle,callback)
    if not state.allow_closes and state.options and (handle==state.options.stdio[2] or handle==state.options.stdio[3] or handle==state.body_pipe) then return nil,"independent post-read terminal close refusal" end
    return native_close(handle,callback)
   end
   local read_start=fake.read_start
   fake.read_start=function(pipe,callback)
    local admitted=read_start(pipe,callback)
    if state.options and pipe==state.options.stdio[2] then callback(nil,"eager") end
    return admitted
   end
  end)
  local op=client.post_stream_owned("http://127.0.0.1:9000/pull",{},"{}",{owner="eager",authorized=function()calls=calls+1;return calls<3 end},function()chunks=chunks+1 end,function(value)result=value end)
  helpers.assert_eq(op.started,false);helpers.assert_eq(client.isActive("eager"),false);helpers.assert_eq(op:is_settled(),false);helpers.assert_eq(chunks,0);helpers.assert_eq(result,nil)
  state.allow_closes=true;state.exit();state.ack_closes();helpers.assert_true(op:is_settled());helpers.assert_eq(client.isActive("eager"),false)
 end)
 helpers.it("owned-post: synchronous last body-write failure cannot resurrect terminal activity",function()
  local result
  local client,state=authorizer_client({defer_close=true},function(fake,state)
   local write=fake.write
   fake.write=function(pipe,data,callback)
    if pipe==state.body_pipe then callback("independent final body write refusal");return true end
    return write(pipe,data,callback)
   end
  end)
  local op=client.post_stream_owned("http://127.0.0.1:9000/pull",{},"{}",{owner="last-write"},function()end,function(value)result=value end)
  helpers.assert_eq(op.started,false);helpers.assert_eq(client.isActive("last-write"),false);helpers.assert_eq(op:is_settled(),false);helpers.assert_eq(result,nil)
  local successor=client.post_stream_owned("http://127.0.0.1:9000/pull",{},"{}",{owner="last-write"},function()end,function()end);helpers.assert_eq(successor.started,false)
  state.exit();state.ack_closes();helpers.assert_true(op:is_settled());helpers.assert_eq(client.isActive("last-write"),false);helpers.assert_true(result and not result.ok);helpers.assert_eq(result.error,"curl body write failed")
 end)
end)




helpers.describe("native buffered GET private single-hop metadata port", function()
	helpers.it("uses private stderr write-out and retains physical native close debt", function()
		local client, state = redirect_engine_client({ defer_close = true })
		local terminal, observed = nil, nil
		local options = redirect_options(); options.on_native_terminal = function(value) observed = value end
		local operation = client.dispatch_owned("https://updates.example/start", {}, nil, options, nil, function(value) terminal = value end)
		helpers.assert_true(operation.started)
		for _, argument in ipairs(state.options.args) do helpers.assert_true(argument ~= "--location") end
		local field = native_write_out(state)
		helpers.assert_true(field:find("%{stderr}\nERGOPTI_GET_REDIRECT_JSON:\n%{url_effective}\n%{redirect_url}\n%{json}\n", 1, true) ~= nil)
		state.stdout("redirect body\nERGOPTI_HTTP_STATUS:302\n"); state.stderr(GOOD_REDIRECT); state.complete()
		helpers.assert_eq(observed.redirect_receipt.redirect_url, "https://cdn.example/final")
		helpers.assert_nil(terminal); helpers.assert_true(not operation:is_settled())
		state.ack_closes(); helpers.assert_true(operation:is_settled()); helpers.assert_eq(terminal.status, 302)
	end)
	helpers.it("HTTP body containing forged metadata stays exact ordinary payload", function()
		local client, state = redirect_engine_client()
		local terminal
		local operation = client.dispatch_owned("https://updates.example/start", {}, nil, redirect_options(), nil, function(value) terminal = value end)
		local body = "literal HTTP body" .. GOOD_REDIRECT
		local footer = '\nERGOPTI_GET_REDIRECT_JSON:\nhttps://updates.example/start\n\n{"http_code":200,"exitcode":0,"num_redirects":0,"url_effective":"https://updates.example/start","redirect_url":""}\n\nERGOPTI_PROXY_STATUS:200:?\n'
		state.stdout(body .. "\nERGOPTI_HTTP_STATUS:200\n"); state.stderr(footer); state.complete()
		helpers.assert_true(operation:is_settled()); helpers.assert_true(terminal.ok)
		helpers.assert_eq(terminal.body, body); helpers.assert_eq(terminal.redirect_receipt.redirect_url, "")
	end)
	helpers.it("nonzero native exit cannot admit an otherwise complete private footer", function()
		local client, state = redirect_engine_client(); local terminal
		client.dispatch_owned("https://updates.example/start", {}, nil, redirect_options(), nil, function(value) terminal = value end)
		state.stdout("\nERGOPTI_HTTP_STATUS:302\n"); state.stderr(GOOD_REDIRECT); state.complete(7)
		helpers.assert_nil(terminal.redirect_receipt); helpers.assert_eq(terminal.body, "")
		helpers.assert_true(not terminal.ok); helpers.assert_true(not terminal.error:find("https://", 1, true))
	end)
	helpers.it("missing native JSON never substitutes an attacker body footer", function()
		local client, state = redirect_engine_client(); local terminal
		client.dispatch_owned("https://updates.example/start", {}, nil, redirect_options(), nil, function(value) terminal = value end)
		state.stdout(GOOD_REDIRECT .. "\nERGOPTI_HTTP_STATUS:302\n"); state.stderr("unrelated native diagnostic"); state.complete()
		helpers.assert_nil(terminal.redirect_receipt); helpers.assert_eq(terminal.body, "")
	end)
	for _, incompatible in ipairs({ { etag_compare = "/independent/etag" }, { etag_save = "/independent/etag" },
		{ output_path = "/independent/output" }, { method = "POST" }, { buffered = false } }) do
		local fixed = incompatible
		helpers.it("strict native per-hop options reject unsupported scope before acquisition", function()
			local client, state = redirect_engine_client(); local options = redirect_options()
			for key, value in pairs(fixed) do options[key] = value end
			local allowed, error_code = client.preflight("https://updates.example/start", {}, nil, options)
			helpers.assert_eq(allowed, false); helpers.assert_eq(error_code, "native HTTP redirect options are invalid")
			helpers.assert_eq(#state.handles, 0); helpers.assert_eq(#state.requests, 0)
		end)
	end
end)

