--- tests/unit/modules/llm/runtime/test_runtime_composition.lua

--- ==============================================================================
--- MODULE: Registered Ollama Runtime Regression Cases
--- DESCRIPTION:
--- Preserves independent controlled receipts through the normal Linux helpers.
--- Actual filesystem/process/serve/UI acceptance remains a separate gate.
--- ==============================================================================

local helpers = require("tests.helpers")
local names = {"llm.bootstrap_budget", "llm.runtime_repair", "modules.llm.runtime_source", "modules.llm.owned_timer", "modules.llm.runtime_composition", "infra.logger", "logger.shim", "infra.i18n", "llm.profile_selector", "infra.llm_bridge", "infra.manifest_reader", "infra.config_paths", "config_outdated", "toml_codec.writer", "infra.llm_preferences", "modules.llm.profiles"}
local previous = {}
for _, name in ipairs(names) do previous[name] = package.loaded[name] end
local function run_registered()
-- This suite tests native wiring contracts; the actual shared controller has its
-- own independent causal suite. Capture only the ports sent to that owner.
package.loaded['llm.runtime_repair']={new=function(ports,policy)return{ports=ports,policy=policy}end}
local Compose = helpers.load_module("modules.llm.runtime_composition")
local ManagedEnvironment = helpers.load_module("modules.llm.managed_ollama_environment")
local function eq(a,b)assert(a==b,'expected '..tostring(b)..' got '..tostring(a))end
local function test(name, body) helpers.it(name .. " (ollama-runtime)", body) end
local function fixture(extra)
	local w={authorized=true,ancestry=true,left=100,env={'PATH=/usr/bin','OLLAMA_HOST=https://remote:443','OLLAMA_NO_CLOUD=0'},op={token='exact native operation'}}
	local source={current=function()return w.authorized end,publish=function()end,app_capture=function()end,app_current=function()end,compensate=function()return true end}
	local resolver={plan=function()return{asset=w.asset}end,current=function()return w.ancestry end}
	w.asset={name='independent-pinned-fixture'};w.descriptor={};w.file_owner={}
	local installed={capture=function()return{status='installed',runtime=w.descriptor}end}
	local phase={start=function(ports,opts,done)w.phase_ports,w.phase_options=ports,opts;return w.op end}
	local process={start=function()end,start_service=function(binary,args,options,done)w.service={binary=binary,args=args,opts=options};return w.op end}
	local http={get_owned=function(url,headers,options,done)w.http={url=url,headers=headers,opts=options,done=done};return w.op end}
	local admission={new=function(r,f,authorized,consent)w.admission={r=r,f=f,authorized=authorized,consent=consent};return w.file_owner end}
	local timer={after=function()end,now_ms=function()return 0 end}
	local timings={ms=function(section,key)
		return assert(({['llm:dependency_bootstrap_timeout_ms']=100,['llm:local_server_probe_timeout_ms']=25,['ui:ollama_deps_poll_ms']=10})[section..':'..key])
	end}
	w.factory={}
	w.controller=Compose.new({source=source,resolver=resolver,installed=installed,file_factory=w.factory,admission=admission,
		install_phase=phase,process=process,http=http,owned_timer=timer,timings=timings,environment=function()return w.env end,
		serve_environment=w.serve_environment or ManagedEnvironment.load(),network=extra and extra.network})
	w.budget={remaining_ms=function()return w.left end}
	w.authorizer=function()if w.on_authorized then w.on_authorized()end;return w.authorized end
	w.options={authorized=w.authorizer,owner='originating-service',host='127.0.0.1:12345'}
	return w
end
test('canonical timings forwarded without new independent master duration',function()local w=fixture();eq(w.controller.policy.bootstrap_timeout_ms,100);eq(w.controller.policy.poll_ms,10)end)
test('installed resolution fences ancestry and source',function()local w=fixture();eq(w.controller.ports.resolve({}).runtime,w.descriptor);w.ancestry=false;eq(w.controller.ports.resolve({}).status,'unavailable')end)
test('binary installation consumes exact phase/file owners and budget',function()
	local w=fixture();eq(w.controller.ports.install({},w.budget,w.authorizer,function()end),w.op)
	eq(w.phase_options.asset,w.asset);eq(w.phase_options.explicit_consent,true);eq(w.phase_options.budget,w.budget)
	eq(w.phase_ports.files,w.file_owner);eq(w.phase_options.timeout_ms,100);eq(w.phase_options.helper_timeout_ms,100)
	eq(w.admission.consent,true);eq(w.admission.f,w.factory)
end)
test('stale installation admission dispatches no phase',function()local w=fixture();w.authorized=false;local o=w.controller.ports.install({},w.budget,w.authorizer,function()end);eq(o:is_settled(),true);eq(w.phase_options,nil)end)
test('owned serve explicit no-deadline port keeps configured loopback host',function()
	local w=fixture();eq(w.controller.ports.start_service('/managed/ollama',{'serve'},w.options,function()end),w.op)
	eq(w.service.opts.timeout_ms,false);eq(w.service.opts.authorized,w.authorizer);eq(w.service.opts.capture_tail,true)
	local hosts,paths=0,0
	for _,entry in ipairs(w.service.opts.env)do if entry:match('^OLLAMA_HOST=')then hosts=hosts+1;eq(entry,'OLLAMA_HOST=127.0.0.1:12345')end;if entry=='PATH=/usr/bin'then paths=paths+1 end end
	eq(hosts,1);eq(paths,1);eq(w.env[2],'OLLAMA_HOST=https://remote:443')
end)
-- The literal is the product decision (local models only): the owned daemon
-- never contacts ollama.com, whatever the inherited environment says.
test('owned serve applies the shared OLLAMA_NO_CLOUD declaration over inherited values',function()
	local w=fixture();w.controller.ports.start_service('/managed/ollama',{'serve'},w.options,function()end)
	local rows={}
	for _,entry in ipairs(w.service.opts.env)do if entry:match('^OLLAMA_NO_CLOUD=')then rows[#rows+1]=entry end end
	eq(#rows,1);eq(rows[1],'OLLAMA_NO_CLOUD=1');eq(w.env[3],'OLLAMA_NO_CLOUD=0')
end)
test('composition refuses a missing or invalid serve environment',function()
	for _,rows in ipairs({{},{'lower=1'},{'OLLAMA_HOST=0.0.0.0:1'},{false}})do
		local ok=pcall(function()local w={serve_environment=rows};Compose.new({source={current=function()return true end,publish=function()end,app_capture=function()end,app_current=function()end},
			resolver={plan=function()end,current=function()end},installed={capture=function()end},file_factory={},admission={new=function()end},
			install_phase={start=function()end},process={start_service=function()end},http={get_owned=function()end},
			owned_timer={after=function()end,now_ms=function()return 0 end},timings={ms=function()return 1 end},
			environment=function()return{}end,serve_environment=w.serve_environment})end)
		eq(ok,false)
	end
end)
test('shared serve environment declaration decodes and refuses owner-held names',function()
	local rows=assert(ManagedEnvironment.load());eq(rows[1],'OLLAMA_NO_CLOUD=1')
	for _,data in ipairs({'{"schema_version":1,"serve_environment":{}}','{"schema_version":2,"serve_environment":{"OLLAMA_NO_CLOUD":"1"}}',
		'{"schema_version":1,"serve_environment":{"OLLAMA_MODELS":"/tmp"}}','{"schema_version":1,"serve_environment":{"OLLAMA_NO_CLOUD":1}}',
		'{"schema_version":1,"serve_environment":{"OLLAMA_NO_CLOUD":"1"},"extra":true}','not json'})do
		eq(ManagedEnvironment.decode(data),nil)
	end
end)
test('source canceled during environment capture dispatches no process',function()
	local w=fixture();local n=0;w.on_authorized=function()n=n+1;if n==2 then w.authorized=false end end
	w.controller.ports.start_service('/managed/ollama',{'serve'},w.options,function()end);eq(w.service,nil)
end)
test('fresh readiness shares exact HTTP cleanup capability and authorizer',function()
	local w=fixture();eq(w.controller.ports.probe('http://127.0.0.1:12345/api/version',w.budget,w.authorizer,function()end),w.op)
	eq(w.http.opts.timeout_ms,25);eq(w.http.opts.follow_redirects,false);eq(w.http.opts.authorized,w.authorizer)
end)
test('readiness timeout clamps actual remaining budget',function()local w=fixture();w.left=9;w.controller.ports.probe('http://127.0.0.1:12345/api/version',w.budget,w.authorizer,function()end);eq(w.http.opts.timeout_ms,9)end)
test('source callback consuming final budget cannot borrow earlier timeout',function()
	local w=fixture();w.on_authorized=function()w.left=0 end
	local o=w.controller.ports.probe('http://127.0.0.1:12345/api/version',w.budget,w.authorizer,function()end)
	eq(w.http,nil);eq(o:is_settled(),true)
end)
test('stale logical HTTP response does not publish callback or erase capability',function()
	local w=fixture();local count=0;local o=w.controller.ports.probe('http://127.0.0.1:12345/api/version',w.budget,w.authorizer,function()count=count+1 end)
	w.authorized=false;w.http.done({ok=true});eq(count,0);eq(o,w.op)
end)

local function network()return{policy={route=function()return{mode='system',environment_exclusions={}}end,environment_names=function()return{}end,
	selection=function()return nil end},lookup=function()end,timeout_ms=7,origins={'https://registry.ollama.ai'}}end
test('without a network dependency the composition has no proxy stage',function()local w=fixture();eq(w.controller.ports.network,nil)end)
test('a network dependency adds the proxy stage and refuses an incomplete one',function()
	local w=fixture({network=network()});eq(type(w.controller.ports.network),'function')
	eq(pcall(fixture,{network={policy={}}}),false)
end)
test('the selected proxy reaches the owned daemon and replaces only that variable',function()
	local w=fixture({network=network()});w.env={'PATH=/usr/bin','HTTPS_PROXY=','https_proxy=keep'}
	w.options.environment={'HTTPS_PROXY=http://proxy.corp.example:3128'}
	w.controller.ports.start_service('/managed/ollama',{'serve'},w.options,function()end)
	local proxies={}
	for _,entry in ipairs(w.service.opts.env)do if entry:lower():match('^https_proxy=')then proxies[#proxies+1]=entry end end
	eq(#proxies,2);eq(proxies[1],'https_proxy=keep');eq(proxies[2],'HTTPS_PROXY=http://proxy.corp.example:3128')
end)
test('an exported proxy reaches the daemon untouched when the stage selected none',function()
	local w=fixture({network=network()});w.env={'PATH=/usr/bin','HTTPS_PROXY=http://mine:1'};w.options.environment={}
	w.controller.ports.start_service('/managed/ollama',{'serve'},w.options,function()end)
	local seen=false
	for _,entry in ipairs(w.service.opts.env)do if entry=='HTTPS_PROXY=http://mine:1'then seen=true end end
	eq(seen,true)
end)
test('the bypass rows of the route plan replace the inherited bypass copies',function()
	local w=fixture({network=network()});w.env={'PATH=/usr/bin','no_proxy=intranet','NO_PROXY=intranet','http_proxy=keep'}
	w.options.environment={'HTTPS_PROXY=http://proxy.corp.example:3128','NO_PROXY=intranet,blob.example','no_proxy=intranet,blob.example'}
	w.controller.ports.start_service('/managed/ollama',{'serve'},w.options,function()end)
	local bypass,kept={},false
	for _,entry in ipairs(w.service.opts.env)do
		if entry:lower():match('^no_proxy=')then bypass[#bypass+1]=entry end
		if entry=='http_proxy=keep'then kept=true end
	end
	eq(#bypass,2);eq(bypass[1],'NO_PROXY=intranet,blob.example');eq(bypass[2],'no_proxy=intranet,blob.example');eq(kept,true)
end)
test('a network dependency without the origin inventory is refused',function()
	local incomplete=network();incomplete.origins=nil
	eq(pcall(fixture,{network=incomplete}),false)
end)
test('proxy rows naming another variable or carrying a newline dispatch no process',function()
	for _,row in ipairs({'OLLAMA_HOST=0.0.0.0:1','ALL_PROXY=socks5://x:1','HTTPS_PROXY=a\nB=c',42})do
		local w=fixture({network=network()});w.options.environment={row}
		local o=w.controller.ports.start_service('/managed/ollama',{'serve'},w.options,function()end)
		eq(w.service,nil);eq(o:is_settled(),true)
	end
end)

end
local called, detail = pcall(run_registered)
for _, name in ipairs(names) do package.loaded[name] = previous[name] end
if not called then error(detail, 0) end
