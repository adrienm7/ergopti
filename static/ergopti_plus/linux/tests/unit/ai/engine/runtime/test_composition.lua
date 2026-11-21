--- tests/unit/ai/engine/runtime/test_composition.lua

--- ==============================================================================
--- MODULE: Registered Ollama Runtime Regression Cases
--- DESCRIPTION:
--- Preserves independent controlled receipts through the normal Linux helpers.
--- Actual filesystem/process/serve/UI acceptance remains a separate gate.
--- ==============================================================================

local helpers = require("tests.helpers")
local names = {"ai.engine.bootstrap.budget", "ai.engine.local_servers.runtime_repair", "ai.engine.local_servers.runtime_source", "ai.engine.local_servers.owned_timer", "ai.engine.local_servers.runtime_composition", "infra.logger", "core.logger.engine.shim", "core.i18n.engine.i18n", "ai.engine.settings.profile_selector", "ai.engine.bridge", "menu.engine.manifest_reader", "settings.engine.paths", "settings.engine.migration.outdated", "core.text.engine.toml_codec.writer", "ai.engine.preferences", "ai.engine.settings.profiles"}
local previous = {}
for _, name in ipairs(names) do previous[name] = package.loaded[name] end
local function run_registered()
-- This suite tests native wiring contracts; the actual shared controller has its
-- own independent causal suite. Capture only the ports sent to that owner.
package.loaded['ai.engine.local_servers.runtime_repair']={new=function(ports,policy)return{ports=ports,policy=policy}end}
local Compose = helpers.load_module("ai.engine.local_servers.runtime_composition")
local ManagedEnvironment = helpers.load_module("ai.engine.ollama.managed_ollama_environment")
local Seal = helpers.load_module("ai.engine.ollama.runtime_seal")
local SHA = string.rep('c', 64)
local RELEASE = '/data/runtimes/ollama/0.40.6-linux-amd64-' .. SHA
local function eq(a,b)assert(a==b,'expected '..tostring(b)..' got '..tostring(a))end
local function test(name, body) helpers.it(name .. " (ollama-runtime)", body) end
local function fixture(extra)
	local w={authorized=true,ancestry=true,left=100,env={'PATH=/usr/bin','OLLAMA_HOST=https://remote:443','OLLAMA_NO_CLOUD=0'},op={token='exact native operation'}}
	local source={current=function()return w.authorized end,publish=function()end,app_capture=function()end,app_current=function()end,compensate=function()return true end}
	local resolver={plan=function()return{asset=w.asset,parent=RELEASE,directory=RELEASE..'/ollama',
		runtime='/data/runtimes/ollama',uid=1000}end,current=function()return w.ancestry end}
	w.asset={name='independent-pinned-fixture',version='0.40.6',sha256=SHA,bytes=40}
	w.parent=RELEASE;w.free=1000;w.margin=60
	w.files={RELEASE..'/ollama/bin/ollama',RELEASE..'/ollama/lib/ollama/libggml.so'}
	w.descriptor={files=function()return w.files end};w.file_owner={}
	w.listening={};w.owner_ok=true;w.removed={};w.finite={}
	local listeners={listening=function(port)w.listened=port;return w.listening end,
		owned=function(port,pid)w.owned_port,w.owned_pid=port,pid;if w.owner_ok then return true end;return false,'listener_foreign' end}
	local seal={NAME=Seal.NAME,command=Seal.command,digests=Seal.digests,encode=Seal.encode,matches=Seal.matches,
		read=function(path)w.seal_read=path;return w.seal_text,w.seal_missing end,
		write=function(path,text)w.sealed={path=path,text=text};return w.write_ok~=false end}
	local retention={stale=function(plan)w.stale_plan=plan;return w.stale or {} end,
		remove=function(paths,process,timeout,label)w.removed[#w.removed+1]={paths=paths,label=label,timeout=timeout};return nil end}
	local installed={capture=function()return{status='installed',runtime=w.descriptor}end}
	local phase={start=function(ports,opts,done)w.phase_ports,w.phase_options=ports,opts;return w.op end}
	local process={start=function(program,args,options,done)w.finite[#w.finite+1]={program=program,args=args,opts=options,done=done};return w.op end,start_service=function(binary,args,options,done)w.service={binary=binary,args=args,opts=options};return w.op end}
	local http={get_owned=function(url,headers,options,done)w.http={url=url,headers=headers,opts=options,done=done};return w.op end}
	local admission={new=function(r,f,authorized,consent)w.admission={r=r,f=f,authorized=authorized,consent=consent};return w.file_owner end}
	local timer={after=function()end,now_ms=function()return 0 end}
	local timings={ms=function(section,key)
		return assert(({['llm:dependency_bootstrap_timeout_ms']=100,['llm:local_server_probe_timeout_ms']=25,['ui:ollama_deps_poll_ms']=10})[section..':'..key])
	end,count=function(section,key)
		assert(section=='limits' and key=='ollama_install_free_space_margin_bytes','the margin comes from the registry')
		return w.margin
	end}
	local free_space={free_bytes=function(path)w.free_path=path;if w.on_free then w.on_free()end;return w.free,w.free_reason end}
	w.factory={}
	w.controller=Compose.new({source=source,resolver=resolver,installed=installed,file_factory=w.factory,admission=admission,
		install_phase=phase,process=process,http=http,owned_timer=timer,timings=timings,free_space=free_space,environment=function()return w.env end,
		serve_environment=w.serve_environment or ManagedEnvironment.load(),network=extra and extra.network,
		listeners=listeners,seal=seal,retention=retention})
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
-- OLL-04: the pinned archive and the registry margin must fit before the download.
test('an install volume without room for the archive and its margin dispatches no phase (ollama-install-free-space)',function()
	local w=fixture();w.free=99
	local result;local o=w.controller.ports.install({},w.budget,w.authorizer,function(r)result=r end)
	eq(o:is_settled(),true);eq(w.phase_options,nil);eq(w.admission,nil);eq(w.free_path,w.parent)
	eq(result.ok,false);eq(result.error,'install_disk_full free=99 required=100')
end)
test('room for the archive and its margin installs (ollama-install-free-space)',function()
	local w=fixture();w.free=100
	eq(w.controller.ports.install({},w.budget,w.authorizer,function()end),w.op);eq(w.free_path,w.parent)
end)
test('an unreadable install volume refuses the install (ollama-install-free-space)',function()
	local w=fixture();w.free,w.free_reason=nil,'native_statfs_refused'
	local result;w.controller.ports.install({},w.budget,w.authorizer,function(r)result=r end)
	eq(w.phase_options,nil);eq(result.error,'install_free_space_unavailable native_statfs_refused')
end)
test('a source withdrawn while the volume is read dispatches no phase (ollama-install-free-space)',function()
	local w=fixture();w.on_free=function()w.authorized=false end
	local result;w.controller.ports.install({},w.budget,w.authorizer,function(r)result=r end)
	eq(w.phase_options,nil);eq(w.admission,nil);eq(result.error,'runtime_source_changed')
end)
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
			owned_timer={after=function()end,now_ms=function()return 0 end},timings={ms=function()return 1 end,count=function()return 1 end},
			free_space={free_bytes=function()return 1 end},environment=function()return{}end,serve_environment=w.serve_environment,
			listeners={listening=function()end,owned=function()end},seal=Seal,retention={stale=function()end,remove=function()end}})end)
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

-- OLL-13: Linux took any GET /api/version answer on the owned port as its
-- daemon's readiness; Windows refuses a listener already there and admits only
-- its child's socket with the pinned version.
local function hashes(w,digests)
	local out={}
	for index,path in ipairs(w.files)do out[#out+1]=(digests and digests[index] or string.rep(tostring(index),64))..'  '..path..'\0' end
	return {ok=true,exit_code=0,stdout=table.concat(out)}
end
local function ready(w)
	w.op.pid=function()return 4242 end
	w.controller.ports.start_service('/managed/ollama',{'serve'},w.options,function()end)
	local result
	w.controller.ports.probe('http://127.0.0.1:12345/api/version',w.budget,w.authorizer,function(value)result=value end)
	return function(answer)w.http.done(answer);return result end
end
test('(oll-13) a server already listening on the owned port is refused before the daemon starts',function()
	local w=fixture();w.listening={['1234']=true};local result
	local o=w.controller.ports.start_service('/managed/ollama',{'serve'},w.options,function(r)result=r end)
	eq(w.service,nil);eq(o:is_settled(),true);eq(result.error,'runtime_port_occupied');eq(w.listened,12345)
end)
test('(oll-13) an unreadable socket table refuses the start instead of guessing',function()
	local w=fixture();w.listening=nil;local result
	w.controller.ports.start_service('/managed/ollama',{'serve'},w.options,function(r)result=r end)
	eq(w.service,nil);eq(result.error,'runtime_listener_unreadable')
end)
test('(oll-13) a version answer from a socket the daemon does not hold is not readiness',function()
	local w=fixture();w.owner_ok=false
	local result=ready(w)({ok=true,status=200,body='{"version":"0.40.6"}'})
	eq(result.ok,false);eq(result.error,'runtime_listener_foreign');eq(w.owned_port,12345);eq(w.owned_pid,4242)
	eq(#w.removed,0,'nothing is retired on a foreign answer')
end)
test('(oll-13) the owned daemon answering another version is stopped',function()
	local w=fixture();local cancelled=0;w.op.cancel=function()cancelled=cancelled+1 end
	local result=ready(w)({ok=true,status=200,body='{"version":"0.24.0"}'})
	eq(result.ok,false);eq(result.error,'runtime_version_mismatch');eq(cancelled,1)
end)
test('(oll-13) the owned daemon answering the pinned version is ready',function()
	local w=fixture();local answer={ok=true,status=200,body='{"version":"0.40.6"}'}
	eq(ready(w)(answer),answer)
end)
-- OLL-07: an update installed beside the earlier release and nothing removed it.
test('(oll-07) a verified, serving pinned release retires the earlier release folders',function()
	local w=fixture();w.stale={'/data/runtimes/ollama/0.24.0-linux-amd64-'..string.rep('d',64)}
	ready(w)({ok=true,status=200,body='{"version":"0.40.6"}'})
	eq(#w.removed,1);eq(w.removed[1].paths[1],w.stale[1]);eq(w.removed[1].timeout,100)
	eq(w.stale_plan.parent,RELEASE)
end)
test('(oll-07) no answer of the pinned daemon retires nothing',function()
	local w=fixture();w.stale={'/data/runtimes/ollama/0.24.0-linux-amd64-'..string.rep('d',64)}
	ready(w)({ok=false,status=0})
	eq(#w.removed,0);eq(w.stale_plan,nil)
end)
-- OLL-08: Linux reused an installed tree on its metadata alone.
test('(oll-08) a fresh install seals every file of the tree beside it',function()
	local w=fixture();local verdict
	eq(w.controller.ports.verify(w.descriptor,w.budget,w.authorizer,true,function(r)verdict=r end),w.op)
	eq(w.seal_read,nil,'a fresh tree is sealed, not read');eq(w.finite[1].program,'sha256sum')
	eq(w.finite[1].args[3],w.files[1]);eq(w.finite[1].opts.timeout_ms,100)
	w.finite[1].done(hashes(w))
	eq(verdict.ok,true);eq(w.sealed.path,RELEASE..'/'..Seal.NAME)
	eq(Seal.matches(w.sealed.text,RELEASE..'/ollama',assert(Seal.digests(hashes(w),w.files)),SHA),true)
end)
test('(oll-08) a reused tree is re-hashed and admitted only when it matches its seal',function()
	local w=fixture();w.seal_text=Seal.encode(RELEASE..'/ollama',assert(Seal.digests(hashes(w),w.files)),SHA)
	local verdict;w.controller.ports.verify(w.descriptor,w.budget,w.authorizer,false,function(r)verdict=r end)
	eq(w.seal_read,RELEASE..'/'..Seal.NAME);w.finite[1].done(hashes(w))
	eq(verdict.ok,true);eq(#w.removed,0);eq(w.sealed,nil)
end)
test('(oll-08) a reused tree whose bytes changed is refused and removed for a new download',function()
	local w=fixture();w.seal_text=Seal.encode(RELEASE..'/ollama',assert(Seal.digests(hashes(w),w.files)),SHA)
	local verdict;w.controller.ports.verify(w.descriptor,w.budget,w.authorizer,false,function(r)verdict=r end)
	w.finite[1].done(hashes(w,{string.rep('e',64),string.rep('2',64)}))
	eq(verdict.ok,false);eq(verdict.error,'runtime_seal_mismatch');eq(w.removed[1].paths[1],RELEASE)
end)
test('(oll-08) a seal of another archive is refused',function()
	local w=fixture();w.seal_text=Seal.encode(RELEASE..'/ollama',assert(Seal.digests(hashes(w),w.files)),string.rep('f',64))
	local verdict;w.controller.ports.verify(w.descriptor,w.budget,w.authorizer,false,function(r)verdict=r end)
	w.finite[1].done(hashes(w));eq(verdict.error,'runtime_seal_foreign')
end)
test('(oll-08) an unsealed tree is refused without hashing and removed',function()
	local w=fixture();w.seal_missing='runtime_seal_missing';local verdict
	local o=w.controller.ports.verify(w.descriptor,w.budget,w.authorizer,false,function(r)verdict=r end)
	eq(o:is_settled(),true);eq(#w.finite,0);eq(verdict.error,'runtime_seal_missing');eq(w.removed[1].paths[1],RELEASE)
end)
test('(oll-08) a failed hash is reported and removes nothing',function()
	local w=fixture();w.seal_text='{}';local verdict
	w.controller.ports.verify(w.descriptor,w.budget,w.authorizer,false,function(r)verdict=r end)
	w.finite[1].done({ok=false,exit_code=1,stdout=''})
	eq(verdict.error,'runtime_seal_hash_failed');eq(#w.removed,0)
end)

local function relay_policy()
	local file=assert(io.open(assert(require('core.fs.engine.paths').shared('core/network/data/proxy_auth_relay.json')),'rb'))
	local bytes=file:read('*a');assert(file:close())
	return assert(require('core.network.engine.proxy_auth_relay_core').new(require('core.text.engine.json').decode(bytes)))
end
local function network(relay_executable)return{policy={route=function()return{mode='system',environment_exclusions={}}end,environment_names=function()return{}end,
	selection=function()return nil end},lookup=function()end,timeout_ms=7,origins={'https://registry.ollama.ai'},
	relay={policy=relay_policy(),probe=function()end,timeout_ms=9,executable=function()return relay_executable end,
		timings=function()return{dial_ms=11,handshake_ms=12,idle_ms=13,probe_ms=14}end},
	probe=function()end,relay_address=function()end,probe_timeout_ms=3}end
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
-- docs/design/proxy-auth-relay.md: the relay serves the daemon for its lifetime.
test('(proxy-auth-relay) a proxy that demands a sign-in starts the daemon under the relay',function()
	local w=fixture({network=network('/opt/ergopti/bin/ergopti-proxy-relay')})
	w.options.environment={'HTTPS_PROXY=http://proxy.corp.example:3128'}
	w.options.relay={upstream='http://proxy.corp.example:3128',scheme='negotiate'}
	w.controller.ports.start_service('/managed/ollama',{'serve'},w.options,function()end)
	eq(w.service.binary,'/opt/ergopti/bin/ergopti-proxy-relay')
	eq(table.concat(w.service.args,' '),'run --upstream http://proxy.corp.example:3128 --variable HTTPS_PROXY'
		..' --dial-timeout-ms 11 --handshake-timeout-ms 12 --idle-timeout-ms 13 -- /managed/ollama serve')
	eq(w.service.opts.timeout_ms,false)
end)
test('(proxy-auth-relay) a refused sign-in bypasses a relay the daemon would inherit, keeping its loopback bind',function()
	local w=fixture({network=network('/opt/ergopti/bin/ergopti-proxy-relay')})
	w.env={'PATH=/usr/bin','HTTPS_PROXY=http://mine:1','NO_PROXY=intranet'}
	w.options.environment={'NO_PROXY=*','no_proxy=*'}
	w.controller.ports.start_service('/managed/ollama',{'serve'},w.options,function()end)
	eq(w.service.binary,'/managed/ollama')
	local rows={}
	for _,entry in ipairs(w.service.opts.env)do rows[entry]=true end
	eq(rows['NO_PROXY=*'],true);eq(rows['no_proxy=*'],true);eq(rows['NO_PROXY=intranet'],nil)
	eq(rows['OLLAMA_HOST='..w.options.host],true)
end)
test('(proxy-auth-relay) a relay that is not installed refuses the start by name',function()
	local w=fixture({network=network(nil)})
	w.options.relay={upstream='http://proxy.corp.example:3128',scheme='ntlm'}
	local result
	local o=w.controller.ports.start_service('/managed/ollama',{'serve'},w.options,function(r)result=r end)
	eq(w.service,nil);eq(o:is_settled(),true);eq(result.error,'runtime_proxy_relay_unavailable')
end)
test('(proxy-auth-relay) a network dependency without the relay binding is refused',function()
	local incomplete=network('/x');incomplete.relay=nil
	eq(pcall(fixture,{network=incomplete}),false)
end)
test('a network dependency without the origin inventory is refused',function()
	local incomplete=network();incomplete.origins=nil
	eq(pcall(fixture,{network=incomplete}),false)
	local unprobed=network();unprobed.probe=nil
	eq(pcall(fixture,{network=unprobed}),false)
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
