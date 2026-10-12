--- tests/unit/modules/llm/test_local_server_discovery.lua

--- Catalogue discovery uses actual private source ownership and retained native GETs.
local helpers = require("tests.helpers")
local Json = require("json")
local function isolated(body)
	local names = { "modules.llm.local_servers", "modules.llm.api_entries", "modules.llm.api_remote",
		"adapters.http_client", "ui.menu.local_server_rows", "ui.menu.llm_backend_rows" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
	local path = os.tmpname(); os.remove(path)
	local calls = {}
	package.loaded["adapters.http_client"] = { get_owned = function(url, headers, options, callback)
		local call = { url = url, headers = headers, options = options, callback = callback, cancelled = 0, listeners = {} }
		local operation = { started = true }
		function operation:is_settled() return call.settled == true end
		function operation:on_settled(fn) if call.settled then fn() else call.listeners[#call.listeners+1] = fn end; return true end
		function operation:cancel() call.cancelled = call.cancelled + 1; return call.settled == true end
		call.operation = operation
		function call.finish(response)
			call.settled = true
			if call.cancelled == 0 then callback(response) end
			local listeners=call.listeners; call.listeners={}
			for _,fn in ipairs(listeners) do fn() end
		end
		calls[#calls+1] = call
		if calls.before_return then calls.before_return(call) end
		return operation
	end }
	local entries = require("modules.llm.api_entries")
	entries._set_path_for_test(path)
	entries._set_private_create_for_test(function(stage, text)
		local out=assert(io.open(stage,"wb")); out:write(text); out:close(); return true
	end)
	local servers = require("modules.llm.local_servers")
	local ok, err = pcall(body, servers, entries, calls, path)
	servers.shutdown()
	os.remove(path); os.remove(path..".tmp"); os.remove(path..".corrupt")
	for _,name in ipairs(names) do package.loaded[name]=previous[name] end
	if not ok then error(err,0) end
end
local function models(...)
	local data={};for _,id in ipairs({...}) do data[#data+1]={id=id} end
	return {ok=true,status=200,body=Json.encode({data=Json.array(data)})}
end
local function find(rows,label)
	for _,row in ipairs(rows) do
		if row.label==label then return row end
		if row.items then local found=find(row.items,label); if found then return found end end
	end
end
helpers.describe("Linux local server discovery ownership", function()
	helpers.it("probes four catalogue URLs under independent native owners with optional credentials", function()
		isolated(function(servers,entries,calls)
			assert(entries.add({provider="lmstudio",label="Local",model="old",token=" private ",base_url="http://localhost:4321/v1"}))
			local published=0
			helpers.assert_true(servers.rescan(function() return true end,function() published=published+1 end))
			helpers.assert_eq(#calls,4)
			helpers.assert_eq(calls[1].url,"http://localhost:8000/v1/models")
			helpers.assert_eq(calls[2].url,"http://localhost:4321/v1/models")
			helpers.assert_eq(calls[3].url,"http://localhost:8080/v1/models")
			helpers.assert_eq(calls[4].url,"http://localhost:1337/v1/models")
			for index,id in ipairs({"omlx","lmstudio","llamacpp","jan"}) do
				helpers.assert_eq(calls[index].options.owner,"llm_local_server:"..id)
				helpers.assert_eq(calls[index].options.follow_redirects,false)
			end
			helpers.assert_nil(calls[1].headers.Authorization)
			helpers.assert_eq(calls[2].headers.Authorization,"Bearer  private ")
			for index=1,3 do calls[index].finish(models("model")); helpers.assert_eq(published,0) end
			calls[4].finish({ok=false,status=401,body=""})
			helpers.assert_eq(published,1)
			helpers.assert_eq(servers.result("jan").status,"needs_key")
			helpers.assert_eq(table.concat(servers.detected(),","),"omlx,lmstudio,llamacpp,jan")
		end)
	end)
	helpers.it("logical cancellation cannot replace a GET until exact native exit and close settlement", function()
		isolated(function(servers,_,calls)
			servers.rescan(function() return true end)
			local first=calls[1]
			helpers.assert_eq(servers.cancel(),false)
			helpers.assert_eq(servers.is_sweeping(),false)
			helpers.assert_eq(servers.is_stale(),true)
			servers.rescan(function() return true end)
			helpers.assert_eq(#calls,4,"accepted cancellation and inactive logical sweep do not acknowledge handles")
			first.callback(models("stale"))
			helpers.assert_nil(servers.result("omlx"))
			first.finish(models("stale"))
			helpers.assert_eq(#calls,5,"only this exact retired provider may acquire its successor")
			helpers.assert_eq(calls[5].options.owner,"llm_local_server:omlx")
			for index=2,4 do calls[index].finish(models("stale")) end
			helpers.assert_eq(#calls,8)
			for index=5,8 do calls[index].finish(models("current")) end
			helpers.assert_eq(servers.result("omlx").models[1],"current")
		end)
	end)
	helpers.it("held model and private-source changes fence acquisition and publication", function()
		isolated(function(servers,entries,calls,path)
			servers.rescan(function() return true end)
			for _,call in ipairs(calls) do call.finish(models("first","second")) end
			local receipt=servers.capture("lmstudio")
			helpers.assert_true(servers.is_current(receipt,"first"))
			servers.rescan(function() return true end)
			for index=5,8 do calls[index].finish(models("first","second")) end
			helpers.assert_true(servers.is_current(receipt,"second"),"unchanged cache refresh does not invalidate visible rows")
			local out=assert(io.open(path,"wb"));out:write('{"version":2,"entries":[]}');out:close()
			helpers.assert_eq(servers.is_current(receipt,"first"),false)
			helpers.assert_nil(servers.apply(receipt,{model="first"},function() return true end))
			helpers.assert_eq(servers.rescan(function() return true end),false)
			helpers.assert_eq(#calls,8)
			helpers.assert_nil(entries.active())
		end)
	end)
	helpers.it("models rows are usable with master OFF and expose JSON ACK/backend refusal separately", function()
		isolated(function(servers,entries,calls)
			local allowed, backend, setters, changes=true,"ollama",0,0
			local llm={get_backend=function() return backend end,get_current_model=function() return "ollama-model" end,
				can_configure_local_servers=function() return allowed end,
				set_backend=function() setters=setters+1;allowed=false;return false end}
			local dialogs={prompt=function() return nil end,error=function() end}
			local context={is_paused=function() return false end}
			local BackendRows=require("ui.menu.llm_backend_rows")
			local function build() return BackendRows.rows(llm,dialogs,function() changes=changes+1 end,function() return {} end,context) end
			build()
			helpers.assert_eq(#calls,4,"actual backend provider starts catalogue probes")
			for _,call in ipairs(calls) do call.finish(models("local-choice")) end
			local rows=build()
			local row=find(rows,"local-choice")
			helpers.assert_true(row~=nil and type(row.action)=="function")
			local outcome=row.action()
			helpers.assert_eq(outcome.saved,true)
			helpers.assert_eq(outcome.selected,false)
			helpers.assert_eq(setters,1)
			helpers.assert_eq(backend,"ollama")
			helpers.assert_eq(entries.active().model,"local-choice")
			helpers.assert_true(changes>=1)
		end)
	end)
	helpers.it("a scope acquired during a blocking address prompt refuses publication and any backend setter", function()
		isolated(function(servers,entries,calls)
			local allowed,setters=true,0
			local llm={get_backend=function() return "ollama" end,can_configure_local_servers=function() return allowed end,
				set_backend=function() setters=setters+1;return true end}
			local dialogs={prompt=function() allowed=false;return "http://localhost:9876/v1" end,error=function() end}
			local Rows=require("ui.menu.local_server_rows")
			local rows=Rows.rows(llm,dialogs,function() end,{is_paused=function() return false end})
			local address=find(rows,require("infra.i18n").get("menu.llm.local_servers.other_address"))
			helpers.assert_true(address~=nil)
			local result=address.items[1].action()
			helpers.assert_eq(result,false)
			helpers.assert_eq(servers.target("omlx").base_url,"http://localhost:8000/v1")
			helpers.assert_nil(entries.active())
			helpers.assert_eq(setters,0)
			helpers.assert_eq(#calls,4)
		end)
	end)
end)


helpers.describe("local selection terminal acknowledgement", function()
	helpers.it("a scope acquired after JSON ACK leaves a saved model without acquiring the backend setter", function()
		isolated(function(servers,entries,calls,path)
			local allowed,setters=true,0
			local llm={get_backend=function() return "ollama" end,can_configure_local_servers=function() return allowed end,
				set_backend=function() setters=setters+1;return true end}
			local Rows=require("ui.menu.local_server_rows")
			local function build() return Rows.rows(llm,{prompt=function() return nil end,error=function() end},function() end,
				{is_paused=function() return false end}) end
			build();for _,call in ipairs(calls) do call.finish(models("owned-model")) end
			local row=find(build(),"owned-model")
			local rename=os.rename
			os.rename=function(from,to)
				local ok,err=rename(from,to)
				if to==path and ok==true then allowed=false end
				return ok,err
			end
			local ok,result=pcall(row.action)
			os.rename=rename
			if not ok then error(result,0) end
			helpers.assert_eq(result.saved,true)
			helpers.assert_eq(result.selected,false)
			helpers.assert_eq(setters,0,"late admission refusal occurs before the real setter")
			helpers.assert_eq(entries.active().model,"owned-model")
			local reader=assert(io.open(path,"rb")); local bytes=reader:read("*a"); reader:close()
			local raw=Json.decode_lossless(bytes)
			helpers.assert_eq(raw.active_id,entries.active().id,"the acknowledged JSON is not fictitiously compensated")
		end)
	end)
	helpers.it("late native refusal and bad JSON cannot publish models or retry through another owner", function()
		isolated(function(servers,_,calls)
			servers.rescan(function() return true end)
			calls[1].finish({ok=false,status=0,body="",error="timeout"})
			calls[2].finish({ok=true,status=200,body='{"data":[{}]}'})
			calls[3].finish({ok=true,status=302,body='{"data":[{"id":"foreign"}]}'})
			calls[4].finish(models())
			helpers.assert_eq(servers.result("omlx").status,"down")
			helpers.assert_eq(servers.result("lmstudio").status,"down")
			helpers.assert_eq(servers.result("llamacpp").status,"down")
			helpers.assert_eq(servers.result("jan").status,"up")
			helpers.assert_eq(#servers.result("jan").models,0)
			helpers.assert_eq(#calls,4)
		end)
	end)
end)


helpers.describe("local discovery constructor and terminal source fences", function()
	helpers.it("a reentrant sweep cannot replace a native GET still constructing or continue the older dispatch loop", function()
		isolated(function(servers,_,calls)
			local reentered=false
			calls.before_return=function()
				if not reentered then reentered=true; servers.rescan(function() return true end) end
			end
			servers.rescan(function() return true end)
			helpers.assert_eq(#calls,4,"one old constructing request and three current independent owners")
			helpers.assert_eq(calls[1].cancelled,1)
			calls[1].finish(models("obsolete"))
			helpers.assert_eq(#calls,5,"the exact same-provider successor waits for physical retirement")
			for index=2,5 do calls[index].finish(models("fresh")) end
			helpers.assert_eq(servers.result("omlx").models[1],"fresh")
		end)
	end)
	helpers.it("private disk drift after native acquisition refuses every old positive response", function()
		isolated(function(servers,_,calls,path)
			local published=0
			servers.rescan(function() return true end,function() published=published+1 end)
			local writer=assert(io.open(path,"wb"));writer:write('{"version":2,"entries":[]}');writer:close()
			for _,call in ipairs(calls) do call.finish(models("foreign-old-model")) end
			helpers.assert_eq(published,1,"the finished joint negative verdict remains observable")
			helpers.assert_eq(#servers.detected(),0)
			for _,id in ipairs(servers.order()) do helpers.assert_eq(servers.result(id).status,"down") end
		end)
	end)
end)

helpers.describe("Configured generic loopback discovery (local-configured-affinity)", function()
	for _, provider in ipairs({ "openai", "openai_compat" }) do
		helpers.it("probes and persists the originating " .. provider .. " row (local-configured-affinity)", function()
			isolated(function(servers, entries, calls, path)
				local entry = assert(entries.add({ provider = provider, label = "Personal label", model = "before",
					token = "inert-token", base_url = "http://127.0.0.1:8000/v1/" }))
				helpers.assert_eq(servers.target("omlx").entry_id, entry.id)
				helpers.assert_true(servers.rescan(function() return true end))
				helpers.assert_eq(calls[1].url, "http://127.0.0.1:8000/v1/models")
				helpers.assert_eq(calls[1].headers.Authorization, "Bearer inert-token")
				helpers.assert_nil(calls[2].headers.Authorization, "a configured credential never crosses catalogue origins")
				calls[1].finish({ ok = true, status = 200, body = '{"object":"list","data":[{"id":"mlx-community/Qwen3-8B-4bit","object":"model","owned_by":"omlx"}]}' })
				for index = 2, 4 do calls[index].finish({ ok = false, status = 0, body = "" }) end
				local receipt = servers.capture("omlx")
				local saved = assert(servers.apply(receipt, { model = "mlx-community/Qwen3-8B-4bit" }, function() return true end))
				helpers.assert_true(saved.saved); helpers.assert_eq(saved.entry.id, entry.id)
				helpers.assert_eq(saved.entry.provider, provider); helpers.assert_eq(saved.entry.label, "Personal label")
				helpers.assert_eq(#entries.list(), 1)
				local file = assert(io.open(path, "rb")); local raw = assert(Json.decode(file:read("*a"))); file:close()
				helpers.assert_eq(raw.entries[1].provider, provider); helpers.assert_eq(raw.entries[1].id, entry.id)
				helpers.assert_eq(raw.entries[1].model, "mlx-community/Qwen3-8B-4bit")
			end)
		end)
	end
end)

helpers.describe("Configured explicit loopback discovery views (local-configured-view)", function()
	for _, provider in ipairs({ "openai", "openai_compat" }) do
		helpers.it("discovers a nondefault " .. provider .. " address without rebranding its identity (local-configured-view)", function()
			isolated(function(servers, entries, calls, path)
				local entry = assert(entries.add({provider=provider,label="Personal generic",model="before",token="",
					base_url="http://127.0.0.1:54321/v1"}))
				local id="configured:"..entry.id
				helpers.assert_true(servers.rescan(function() return true end))
				helpers.assert_eq(#calls,5,"the explicit configured loopback source is appended after the four declared defaults")
				helpers.assert_eq(table.concat(servers.order(),","),"omlx,lmstudio,llamacpp,jan,"..id)
				helpers.assert_eq(calls[5].url,"http://127.0.0.1:54321/v1/models")
				helpers.assert_nil(calls[5].headers.Authorization)
				for index=1,4 do calls[index].finish({ok=false,status=0,body=""}) end
				calls[5].finish({ok=true,status=200,body='{"object":"list","data":[{"id":"mlx-community/Qwen3-8B-4bit","object":"model","owned_by":"omlx"}]}'})
				helpers.assert_eq(servers.result(id).models[1],"mlx-community/Qwen3-8B-4bit")
				helpers.assert_eq(servers.result("omlx").status,"down","generic models metadata does not establish a catalogue identity")
				local saved=assert(servers.apply(servers.capture(id),{model="mlx-community/Qwen3-8B-4bit"},function() return true end))
				helpers.assert_true(saved.saved); helpers.assert_eq(saved.entry.provider,provider)
				helpers.assert_eq(saved.entry.id,entry.id); helpers.assert_eq(saved.entry.label,"Personal generic")
				helpers.assert_eq(#entries.list(),1)
				local reader=assert(io.open(path,"rb"));local raw=assert(Json.decode_lossless(reader:read("*a")));reader:close()
				helpers.assert_eq(raw.entries[1].provider,provider);helpers.assert_eq(raw.entries[1].id,entry.id)
			end)
		end)
	end
end)

helpers.describe("Configured discovery view custody (local-configured-view)", function()
	helpers.it("retains removed configured native owners until exact physical retirement (local-configured-view)", function()
		isolated(function(servers,entries,calls)
			local entry=assert(entries.add({provider="openai",label="Personal",model="before",token="secret",
				base_url="http://localhost:54321/v1"}))
			local id="configured:"..entry.id
			servers.rescan(function() return true end)
			helpers.assert_eq(#calls,5);helpers.assert_eq(calls[5].headers.Authorization,"Bearer secret")
			local receipt=servers.capture(id)
			helpers.assert_true(entries.remove(entry.id))
			servers.rescan(function() return true end)
			helpers.assert_eq(#servers.order(),4)
			helpers.assert_eq(calls[5].cancelled,1,"removed source does not lose its original physical debt")
			helpers.assert_eq(servers.is_current(receipt),false)
			helpers.assert_nil(servers.apply(receipt,{model="late"},function() return true end))
			calls[5].callback(models("obsolete"))
			helpers.assert_nil(servers.result(id))
			for index=1,4 do calls[index].finish(models("old")) end
			helpers.assert_eq(#calls,9,"only the four retained catalogue owners can reacquire")
			for index=6,9 do calls[index].finish(models("fresh")) end
			helpers.assert_eq(servers.result("omlx").models[1],"fresh")
			helpers.assert_eq(servers.cancel(),false,"the removed configured owner still carries close debt")
			calls[5].finish(models("obsolete"))
			helpers.assert_true(servers.cancel())
		end)
	end)
	helpers.it("preserves foreign private fields and row positions through configured selection (local-configured-view)", function()
		isolated(function(servers,entries,calls,path)
			local writer=assert(io.open(path,"wb"))
			writer:write('{"version":1,"foreign":{"enabled":false},"entries":[{"id":"foreign","provider":"future","token":"foreign-key","label":"Foreign","model":"untouched","base_url":"https://example.invalid/v1","custom":[1,2]},{"id":"personal","provider":"openai_compat","label":"My local","model":"before","token":"","base_url":"http://[::1]:54321/v1","custom":{"null":null,"flag":false}}]}');writer:close()
			entries._set_path_for_test(path)
			servers.rescan(function() return true end)
			helpers.assert_eq(#calls,5)
			for index=1,4 do calls[index].finish({ok=false,status=0,body=""}) end
			calls[5].finish(models("mlx-community/Qwen3-8B-4bit"))
			local saved=assert(servers.apply(servers.capture("configured:personal"),{model="mlx-community/Qwen3-8B-4bit"},function() return true end))
			helpers.assert_eq(saved.entry.id,"personal");helpers.assert_eq(saved.entry.provider,"openai_compat")
			local reader=assert(io.open(path,"rb"));local raw=assert(Json.decode_lossless(reader:read("*a")));reader:close()
			helpers.assert_eq(raw.foreign.enabled,false);helpers.assert_eq(raw.entries[1].id,"foreign")
			helpers.assert_eq(raw.entries[1].custom[2],2);helpers.assert_eq(raw.entries[2].id,"personal")
			helpers.assert_eq(raw.entries[2].custom.flag,false);helpers.assert_true(Json.is_null(raw.entries[2].custom.null))
			entries._set_path_for_test(path)
			helpers.assert_eq(entries.active().model,"mlx-community/Qwen3-8B-4bit")
		end)
	end)
	helpers.it("authentication, malformed bodies, pause and changed configured identities refuse models (local-configured-view)", function()
		isolated(function(servers,entries,calls)
			local first=assert(entries.add({provider="openai",label="First",model="before",token="",base_url="http://127.0.0.1:54321/v1"}))
			local second=assert(entries.add({provider="openai_compat",label="Second",model="before",token="key",base_url="http://localhost:54322/v1"}))
			servers.rescan(function() return true end)
			helpers.assert_eq(#calls,6)
			for index=1,4 do calls[index].finish({ok=false,status=0,body=""}) end
			calls[5].finish({ok=false,status=401,body='{"error":"key required"}'})
			calls[6].finish({ok=true,status=200,body='{"data":{}}'})
			helpers.assert_eq(servers.result("configured:"..first.id).status,"needs_key")
			helpers.assert_eq(servers.result("configured:"..second.id).status,"down")
			local receipt=servers.capture("configured:"..first.id)
			helpers.assert_nil(servers.apply(receipt,{token="new"},function() return false end))
			helpers.assert_eq(entries.get(first.id).token,"")
			servers.rescan(function() return true end)
			helpers.assert_true(entries.remove(first.id))
			for index=7,12 do calls[index].finish(models("obsolete")) end
			helpers.assert_nil(servers.apply(receipt,{model="obsolete"},function() return true end))
			helpers.assert_nil(entries.get(first.id))
		end)
	end)
end)

helpers.describe("Configured native menu publication (local-configured-view)", function()
	for _, provider in ipairs({ "openai", "openai_compat" }) do
		helpers.it("selects a checked originating "..provider.." menu row and fences held callbacks (local-configured-view)",function()
			isolated(function(servers,entries,calls)
				local entry=assert(entries.add({provider=provider,label="Personal",model="before",token="",
					base_url="http://127.0.0.1:54321/v1"}))
				local backend,writes="ollama",0
				local llm={get_backend=function() return backend end,can_configure_local_servers=function() return true end,
					set_backend=function(value,admit) if not admit() then return false end;backend=value;writes=writes+1;return true end}
				local Rows=require("ui.menu.local_server_rows")
				local context={is_paused=function() return false end}
				local function build() return Rows.rows(llm,{prompt=function() return nil end,error=function() end},function() end,context) end
				build()
				for index=1,4 do calls[index].finish({ok=false,status=0,body=""}) end
				calls[5].finish(models("opaque/local-model"))
				local held=find(build(),"opaque/local-model")
				helpers.assert_true(held and type(held.action)=="function")
				local outcome=held.action()
				helpers.assert_true(outcome.saved);helpers.assert_true(outcome.selected)
				helpers.assert_eq(backend,"api");helpers.assert_eq(writes,1)
				helpers.assert_eq(entries.active().id,entry.id);helpers.assert_eq(entries.active().provider,provider)
				for index=6,9 do calls[index].finish({ok=false,status=0,body=""}) end
				calls[10].finish(models("opaque/local-model"))
				local current=find(build(),"opaque/local-model")
				helpers.assert_true(current.checked)
				helpers.assert_eq(held.action(),false,"old source receipt cannot repeat a committed selection")
				servers.cancel()
				helpers.assert_eq(current.action(),false,"explicit cancellation fences displayed configured choices")
				helpers.assert_eq(writes,1)
			end)
		end)
	end
	helpers.it("moves an edited configured address into its canonical view while retaining the same source row (local-configured-view)",function()
		isolated(function(servers,entries,calls)
			local entry=assert(entries.add({provider="openai",label="Personal",model="before",token="",
				base_url="http://127.0.0.1:54321/v1"}))
			servers.rescan(function() return true end)
			for _,call in ipairs(calls) do call.finish(models("model")) end
			local id="configured:"..entry.id
			local saved=assert(servers.apply(servers.capture(id),{base_url="http://localhost:8000/v1"},function() return true end))
			helpers.assert_eq(saved.entry.id,entry.id);helpers.assert_eq(saved.entry.provider,"openai")
			helpers.assert_eq(#servers.order(),4);helpers.assert_eq(servers.target("omlx").entry_id,entry.id)
			helpers.assert_nil(servers.target(id));helpers.assert_eq(#entries.list(),1)
		end)
	end)
end)

helpers.describe("Native discovery infrastructure receipts (local-probe-unavailable)",function()
	for _, failure in ipairs({"throw","unsupported","dead_start","observation_false","observation_throw"}) do
		helpers.it("reports native "..failure.." as unavailable while retaining cleanup ownership (local-probe-unavailable)",function()
			isolated(function(servers,_,calls)
				local http=package.loaded["adapters.http_client"]
				local original=http.get_owned
				http.get_owned=function(url,headers,options,callback)
					if failure=="throw" then error("actual native construction refused") end
					if failure=="unsupported" then return {} end
					local operation=original(url,headers,options,callback)
					if failure=="dead_start" then
						operation.started=false
						callback({ok=false,status=0,body="",error="native admission refused"})
					elseif failure=="observation_false" then operation.on_settled=function() return false end
					elseif failure=="observation_throw" then operation.on_settled=function() error("native settlement registration failed") end end
					return operation
				end
				helpers.assert_true(servers.rescan(function() return true end))
				helpers.assert_eq(servers.is_sweeping(),false)
				helpers.assert_eq(servers.result("omlx").status,"unavailable")
				helpers.assert_eq(#servers.detected(),0)
				local rows=require("ui.menu.local_server_rows").rows({get_backend=function() return "ollama" end,
					can_configure_local_servers=function() return true end}, {},function() end,{is_paused=function() return false end})
				local failed=find(rows,require("infra.i18n").get("healthcheck.status.failed"))
				helpers.assert_true(failed and failed.disabled,"actual menu exposes infrastructure failure")
				helpers.assert_eq(#rows,5,"one failure row replaces the no-server summary")
				local none=require("infra.i18n").get("menu.llm.local_servers.none"):gsub("{1}","oMLX, LM Studio, llama.cpp / LocalAI, Jan")
				helpers.assert_nil(find(rows,none),"infrastructure refusal cannot become a no-server claim")
				helpers.assert_eq(servers.cancel(),false,"no flag acknowledges still retained native debt")
				if failure~="throw" and failure~="unsupported" then
					for _,call in ipairs(calls) do call.finish(models("obsolete")) end
					helpers.assert_true(servers.cancel(),"actual settlement, including polling after observer refusal, retires exact owners")
				end
			end)
		end)
	end
	helpers.it("keeps ordinary connection refusal, malformed JSON and HTTP authentication distinct (local-probe-unavailable)",function()
		isolated(function(servers,_,calls)
			servers.rescan(function() return true end)
			calls[1].finish({ok=false,status=0,body="",error="connection refused"})
			calls[2].finish({ok=true,status=200,body='{"error":"constructor failure","probe_error":true,"data":{}}'})
			calls[3].finish({ok=false,status=401,body='{"error":"key required","probe_error":true}'})
			calls[4].finish({ok=true,status=200,body='{"data":[{"id":"valid-model"}],"probe_error":true}'})
			helpers.assert_eq(servers.result("omlx").status,"down")
			helpers.assert_eq(servers.result("lmstudio").status,"down")
			helpers.assert_eq(servers.result("llamacpp").status,"needs_key")
			helpers.assert_eq(servers.result("jan").status,"up")
			helpers.assert_eq(servers.result("jan").models[1],"valid-model","foreign body flags never become native receipts")
		end)
	end)
end)

helpers.describe("Native synchronous discovery ownership (local-probe-unavailable)",function()
	helpers.it("acknowledges a zero-resource dead-start refusal without replaying its body (local-probe-unavailable)",function()
		isolated(function(servers)
			package.loaded["adapters.http_client"].get_owned=function(_,_,_,callback)
				local operation={started=false}
				function operation:is_settled() return true end
				function operation:cancel() return true end
				function operation:on_settled(listener) listener();return true end
				callback(models("never-acquired"))
				return operation
			end
			servers.rescan(function() return true end)
			helpers.assert_eq(servers.result("omlx").status,"unavailable")
			helpers.assert_eq(#servers.detected(),0)
			helpers.assert_true(servers.cancel(),"actual settled receipt acknowledges no native resources")
		end)
	end)
	helpers.it("preserves a synchronously completed valid response before retirement observation (local-probe-unavailable)",function()
		isolated(function(servers,_,calls)
			calls.before_return=function(call) call.finish(models("synchronous-model")) end
			servers.rescan(function() return true end)
			helpers.assert_eq(servers.is_sweeping(),false)
			helpers.assert_eq(servers.result("omlx").status,"up")
			helpers.assert_eq(servers.result("omlx").models[1],"synchronous-model")
			helpers.assert_true(servers.cancel())
		end)
	end)
	helpers.it("keeps a native dead-start after admission loss as a refused stale source (local-probe-unavailable)",function()
		isolated(function(servers,_,calls)
			local allowed=true
			calls.before_return=function(call)
				allowed=false;call.operation.started=false
				call.callback({ok=false,status=0,body="",error="dispatch refused"})
			end
			servers.rescan(function() return allowed end)
			helpers.assert_eq(servers.result("omlx").status,"down","lost scope cannot publish even a native infrastructure verdict")
			helpers.assert_eq(#calls,1,"lost scope fences later acquisitions")
			calls[1].finish(models("obsolete"))
			helpers.assert_true(servers.cancel())
		end)
	end)
end)

helpers.describe("Native empty models presentation (local-empty-models)",function()
	helpers.it("keeps literal empty OpenAI lists reachable with disabled native no-models rows (local-empty-models)",function()
		isolated(function(servers,entries,calls)
			local entry=assert(entries.add({provider="openai_compat",label="Personal",model="before",token="",
				base_url="http://127.0.0.1:54321/v1"}))
			local setters=0
			local llm={get_backend=function() return "ollama" end,can_configure_local_servers=function() return true end,
				set_backend=function() setters=setters+1;return true end}
			local Rows=require("ui.menu.local_server_rows")
			local function build() return Rows.rows(llm,{},function() end,{is_paused=function() return false end}) end
			build()
			for _,call in ipairs(calls) do call.finish({ok=true,status=200,body='{"object":"list","data":[]}'}) end
			helpers.assert_eq(#servers.detected(),5)
			for _,id in ipairs(servers.order()) do
				helpers.assert_eq(servers.result(id).status,"up");helpers.assert_eq(#servers.result(id).models,0)
				helpers.assert_nil(servers.apply(servers.capture(id),{model="invented"},function() return true end))
			end
			local count=0
			local label=require("infra.i18n").get("menu.llm.local_servers.no_models")
			for _,row in ipairs(build()) do
				for _,child in ipairs(row.items or {}) do
					if child.label==label then
						count=count+1;helpers.assert_true(child.disabled);helpers.assert_nil(child.action)
					end
				end
			end
			helpers.assert_eq(count,5);helpers.assert_eq(setters,0)
			helpers.assert_eq(entries.get(entry.id).model,"before")
		end)
	end)
	for _,control in ipairs({
		{label="object instead of array",status=200,body='{"object":"list","data":{}}'},
		{label="array root",status=200,body='[{"object":"list","data":[]}]'},
		{label="HTTP 404",status=404,body='{"object":"list","data":[]}'},
	}) do
		helpers.it("keeps "..control.label.." down without reporting infrastructure failure (local-empty-models)",function()
			isolated(function(servers,_,calls)
				servers.rescan(function() return true end)
				for _,call in ipairs(calls) do call.finish({ok=control.status==200,status=control.status,body=control.body}) end
				for _,id in ipairs(servers.order()) do helpers.assert_eq(servers.result(id).status,"down") end
				helpers.assert_eq(#servers.detected(),0)
				local rows=require("ui.menu.local_server_rows").rows({get_backend=function() return "ollama" end,
					can_configure_local_servers=function() return true end},{},function() end,{is_paused=function() return false end})
				helpers.assert_nil(find(rows,require("infra.i18n").get("healthcheck.status.failed")))
			end)
		end)
	end
end)
