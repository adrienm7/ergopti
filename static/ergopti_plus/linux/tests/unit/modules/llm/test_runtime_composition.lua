--- tests/unit/modules/llm/test_runtime_composition.lua

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
local function eq(a,b)assert(a==b,'expected '..tostring(b)..' got '..tostring(a))end
local function test(name, body) helpers.it(name .. " (ollama-runtime)", body) end
local function fixture()
	local w={authorized=true,ancestry=true,left=100,env={'PATH=/usr/bin','OLLAMA_HOST=https://remote:443'},op={token='exact native operation'}}
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
		install_phase=phase,process=process,http=http,owned_timer=timer,timings=timings,environment=function()return w.env end})
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

end
local called, detail = pcall(run_registered)
for _, name in ipairs(names) do package.loaded[name] = previous[name] end
if not called then error(detail, 0) end
