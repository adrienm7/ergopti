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
