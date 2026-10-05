--- tests/unit/modules/llm/test_runtime_repair.lua

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
local Repair = helpers.load_module("llm.runtime_repair")
local function eq(actual, expected, detail)
	assert(actual==expected, (detail or 'value') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end
local function test(name, body) helpers.it(name .. " (ollama-runtime)", body) end

local function op(world, kind, done)
	local result={started=kind=='service' or kind=='master' or kind=='retry', closed=false, listeners={}, cancelled=false, done=done, kind=kind}
	function result:is_settled() return self.closed end
	function result:is_current() return not self.closed and not self.cancelled and self.authorized() end
	function result:is_running()
		local admitted=self.kind=='service' and not self.exited and not self.closed and not self.cancelled and self.authorized()
		if world.observe_running then world.returned_running=true end
		return admitted
	end
	function result:on_settled(fn) if self.closed then fn() else self.listeners[#self.listeners+1]=fn end; return true end
	function result:close()
		self.closed=true
		local listeners=self.listeners; self.listeners={}
		for _,fn in ipairs(listeners) do fn() end
	end
	function result:cancel()
		self.cancelled=true
		if not world.hold[kind] then self:close() end
		return self.closed
	end
	function result:answer(value, close)
		if self.done then self.done(value) end
		if close~=false then self:close() end
	end
	world.ops[kind]=world.ops[kind] or {}; table.insert(world.ops[kind],result)
	return result
end
local function world(options)
	local w={now=0,source=true,app_source=true,runtime_source=true,installed=true,hold={},ops={},published=0,completed=0}
	for key,value in pairs(options or {}) do w[key]=value end
	w.snapshot={origin='http://127.0.0.1:11434'}
	w.runtime={current=function() if w.on_runtime then w.on_runtime() end;return w.runtime_source end, executable=function() return '/private/ollama/bin/ollama' end}
	w.proof={}
	local p={}
	function p.current() if w.on_current then w.on_current() end; return w.source end
	function p.now_ms() return w.now end
	function p.after(ms, done)
		local kind=ms==100 and #((w.ops.master) or {})==0 and 'master' or 'retry'
		local timer=op(w,kind,done); timer.ms=ms
		return timer
	end
	function p.resolve()
		if w.on_resolve then w.on_resolve() end
		return w.installed and {status='installed',runtime=w.runtime} or {status='missing'}
	end
	function p.install(snapshot,budget,authorized,done)
		w.install_budget=budget; w.install_authorized=authorized
		if w.throw_install then error('unknown construction') end
		local install=op(w,'install',done)
		if w.sync_install then w.installed=true; install:answer({ok=true}) end
		return install
	end
	function p.start_service(binary,args,options,done)
		w.binary,w.args,w.service_options=binary,args,options
		if w.on_start then w.on_start() end
		local serve=op(w,'service',done); serve.authorized=options.authorized
		if w.sync_service_exit then serve:answer({ok=false}) end
		return serve
	end
	function p.probe(url,budget,authorized,done)
		w.url,w.probe_budget,w.probe_authorized=url,budget,authorized
		if w.throw_probe then error('unknown dispatch') end
		local probe=op(w,'probe',done)
		if w.sync_probe then probe:answer(w.receipt or {ok=true,status=200,body='{"version":"0.24.0"}'}) end
		return probe
	end
	function p.compensate()
		w.compensation_calls=(w.compensation_calls or 0)+1
		if w.compensation_refused then return false end
		w.source=true;return true
	end
	function p.publish(snapshot,accept)
		w.published=w.published+1
		if w.before_write then w.before_write() end
		if w.saved_without_proof then return true end
		w.source=false -- Existing writer owns this transition.
		w.accepted=accept(w.bad_proof and {} or w.proof)
		if w.after_write then w.after_write() end
		return not w.writer_false and w.accepted
	end
	function p.app_capture(proof)
		if w.on_capture then w.on_capture() end
		if proof~=w.proof then return nil end
		return w.proof
	end
	function p.app_current(source)
		if w.on_app_current then w.on_app_current() end
		return w.app_source and source==w.proof
	end
	w.ports=p
	w.controller=Repair.new(p,{bootstrap_timeout_ms=100,poll_ms=10})
	function w:start(action,consent)
		self.request=self.controller:start(self.snapshot,action or 'start',consent~=false,function(result)
			self.completed=self.completed+1; self.result=result
		end)
		return self.request
	end
	function w:last(kind) return self.ops[kind] and self.ops[kind][#self.ops[kind]] end
	function w:ready() self:last('probe'):answer({ok=true,status=200,body='{"version":"0.24.0"}'}) end
	return w
end

for _,origin in ipairs({'https://127.0.0.1:11434','http://example.com:11434','http://localhost:11434',
	'http://127.0.0.1:011434','http://127.0.0.1:0','http://127.0.0.1:65536','http://127.0.0.1:11434/',
	'http://user@127.0.0.1:11434','http://127.0.0.1:11434?x=1'}) do
	test('origin refuses '..origin,function() eq(Repair.loopback_origin(origin),nil) end)
end
test('IPv6 canonical loopback accepted',function() eq(Repair.loopback_origin('http://[::1]:11434'),'http://[::1]:11434') end)
test('start consent required before any resource',function() local w=world();local r=w:start('start',false);eq(r:is_settled(),true);eq(w:last('master'),nil);eq(w:last('service'),nil) end)
test('start missing binary does not install',function() local w=world({installed=false});local r=w:start();eq(w:last('install'),nil);eq(r.result.ok,false);eq(r:is_settled(),true) end)
test('binary download requires explicit consent',function() local w=world({installed=false});w:start('download',false);eq(w:last('install'),nil) end)
test('binary download does not install model',function()
	local w=world({installed=false});local r=w:start('download');eq(w:last('service'),nil)
	w.installed=true;w:last('install'):answer({ok=true});w:ready()
	eq(r.result.ok,true);eq(r.result.installed,true);eq(r.result.model_installed,false)
end)
test('managed start keeps exact serve options',function()
	local w=world();w:start();eq(w.binary,'/private/ollama/bin/ollama');eq(w.args[1],'serve');eq(#w.args,1)
	eq(w.service_options.timeout_ms,false);eq(w.service_options.host,'127.0.0.1:11434');eq(w.url,'http://127.0.0.1:11434/api/version')
end)
test('fresh typed receipt promotes service only after writer acknowledgment',function()
	local w=world();local r=w:start();eq(w.published,0);w:ready()
	eq(w.published,1);eq(w.accepted,true);eq(r.result.ok,true);eq(r:is_settled(),true)
	eq(w.controller:app_status(),'running');eq(w:last('service').cancelled,false);eq(w.completed,1)
end)
test('cancel retired ticket preserves acknowledged app service',function()
	local w=world();local r=w:start();w:ready();eq(r:cancel(),true);eq(w:last('service').cancelled,false)
	w.now=200;eq(w:last('service'):is_current(),true);eq(w.controller:app_status(),'running')
end)
test('explicit app stop retains exact process close debt',function()
	local w=world();w:start();w:ready();w.hold.service=true;eq(w.controller:stop_app(),false)
	eq(w.controller:app_status(),'retiring');eq(w.controller:has_debt(),true)
	w:last('service'):close();eq(w.controller:app_status(),'absent');eq(w.controller:has_debt(),false)
end)
test('app source retirement cancels only owned service',function()
	local w=world();w:start();w:ready();w.app_source=false
	eq(w.controller:app_status(),'absent');eq(w:last('service').cancelled,true)
end)
test('master timer physical debt blocks writer',function()
	local w=world();w.hold.master=true;local r=w:start();w:ready();eq(w.published,0);eq(r:is_settled(),false)
	w.hold.master=false;w:last('master'):close();eq(w.published,1);eq(r.result.ok,true)
end)
test('HTTP callback is not a close acknowledgment',function()
	local w=world();local r=w:start();w:last('probe'):answer({ok=true,status=200,body='{"version":"0.24.0"}'},false)
	eq(w.published,0);eq(r:is_settled(),false);w:last('probe'):close();eq(w.published,1)
end)
test('generic status200 is not version readiness',function()
	local w=world();w:start();w:last('probe'):answer({ok=true,status=200,body='{"alive":true}'})
	eq(w.published,0);eq(w:last('retry').ms,10)
end)
test('unreachable startup retries fresh version probe after owned timer close',function()
	local w=world();w:start();w:last('probe'):answer({ok=false,status=0});local timer=w:last('retry')
	eq(#w.ops.probe,1);w.now=10;timer:answer(true,false);eq(#w.ops.probe,1);timer:close();eq(#w.ops.probe,2)
	w:ready();eq(w.completed,1)
end)
test('readiness retry uses remaining master budget',function()
	local w=world();w:start();w.now=95;w:last('probe'):answer({ok=false});eq(w:last('retry').ms,5)
end)
test('expiry cancels provisional process and exact HTTP',function()
	local w=world();local r=w:start();w:last('master'):answer(true)
	eq(w:last('service').cancelled,true);eq(w:last('probe').cancelled,true);eq(w.published,0);eq(r:is_settled(),true)
end)
test('source drift before HTTP publication refuses writer',function()
	local w=world();local r=w:start();w.source=false;w:ready();eq(w.published,0);eq(r.result.ok,false);eq(w.completed,0)
end)
test('runtime identity drift before HTTP publication refuses writer',function()
	local w=world();local r=w:start();w.runtime_source=false;w:ready();eq(w.published,0);eq(r.result.ok,false)
end)
test('cancellation cleanup debt bars successor ownership',function()
	local w=world();w.hold.probe=true;local r=w:start();eq(r:cancel(),false)
	local successor=w.controller:start(w.snapshot,'start',true);eq(successor.result.error,'runtime_owner_busy')
	w:last('probe'):close();eq(r:is_settled(),true);eq(w.completed,0)
end)
test('unknown HTTP constructor retains debt instead of empty acknowledgment',function()
	local w=world({throw_probe=true});local r=w:start();r:cancel();eq(r:is_settled(),false);eq(w.controller:has_debt(),true);eq(w.published,0)
end)
test('unknown installer constructor retains exact ownership barrier',function()
	local w=world({installed=false,throw_install=true});local r=w:start('download');eq(r:is_settled(),false);eq(w:last('service'),nil)
end)
test('synchronous installer and probe retain exact returned capabilities',function()
	local w=world({installed=false,sync_install=true,sync_probe=true});local r=w:start('download')
	eq(r.result.ok,true);eq(w.completed,1);eq(w.controller:app_status(),'running')
end)
test('synchronous service exit cannot fabricate readiness',function()
	local w=world({sync_service_exit=true});local r=w:start();eq(r.result.ok,false);eq(w.published,0);eq(w:last('probe'),nil)
end)
test('provisional service exit immediately retires in-flight HTTP',function()
	local w=world();local r=w:start();w:last('service'):answer({ok=false});eq(w:last('probe').cancelled,true);eq(r.result.ok,false);eq(w.published,0)
end)
test('plain saved boolean cannot transfer app ownership',function()
	local w=world({saved_without_proof=true});local r=w:start();w:ready();eq(r.result.ok,false);eq(w.controller:app_status(),'absent');eq(w:last('service').cancelled,true)
end)
test('foreign writer proof cannot transfer ownership',function()
	local w=world({bad_proof=true});local r=w:start();w:ready();eq(w.accepted,false);eq(r.result.ok,false);eq(w.controller:app_status(),'absent')
end)
test('writer false after acknowledgment cancels provisional handoff',function()
	local w=world({writer_false=true});local r=w:start();w:ready();eq(r.result.ok,false);eq(w:last('service').cancelled,true);eq(w.controller:app_status(),'absent')
end)
test('pause during acknowledged write refuses handoff',function()
	local w=world();local r=w:start();w.after_write=function()w.app_source=false end;w:ready()
	eq(r.result.ok,false);eq(w:last('service').cancelled,true);eq(w.controller:app_status(),'absent')
end)
test('cancel during acknowledgment cannot publish ready',function()
	local w=world();local r=w:start();w.on_capture=function()r:cancel() end;w:ready()
	eq(r.result.ok,false);eq(w.controller:app_status(),'absent');eq(w.completed,0)
end)
test('timeout during writer cannot gain app lifetime',function()
	local w=world();local r=w:start();w.after_write=function()w.now=100 end;w:ready()
	eq(r.result.ok,false);eq(w.controller:app_status(),'absent')
end)
test('admission callback cannot overwrite reserved repair owner',function()
	local w=world();local nested
	w.on_current=function()w.on_current=nil;nested=w.controller:start(w.snapshot,'start',true) end
	w:start();eq(nested.result.error,'runtime_owner_busy');eq(#w.ops.service,1)
end)
test('mutable port table cannot replace acknowledged writer authority',function()
	local w=world();w.ports.publish=function()error('foreign writer')end;local r=w:start();w:ready();eq(r.result.ok,true)
end)
test('late duplicate probe callback cannot republish',function()
	local w=world();local r=w:start();local probe=w:last('probe');w:ready();probe:answer({ok=true,status=200,body='{"version":"fake"}'})
	eq(w.published,1);eq(w.completed,1);eq(r.result.ok,true)
end)
test('installer completion waits actual native cleanup',function()
	local w=world({installed=false});w:start('download');w.installed=true;w:last('install'):answer({ok=true},false)
	eq(w:last('service'),nil);w:last('install'):close();eq(#w.ops.service,1)
end)
test('app lifecycle ignores enable ticket but requires runtime identity',function()
	local w=world();w:start();w:ready();w.runtime_source=false;eq(w.controller:app_status(),'absent');eq(w:last('service').cancelled,true)
end)
test('snapshot origin drift inside source callback cannot start remote service',function()
	local w=world();w.on_resolve=function()w.snapshot.origin='https://other.example:443'end;local r=w:start()
	eq(w:last('service'),nil);eq(r.result.ok,false)
end)
test('early retry callback cannot spin fresh HTTP acquisitions',function()
	local w=world();local r=w:start();w:last('probe'):answer({ok=false});w:last('retry'):answer(true)
	eq(#w.ops.probe,1);eq(r.result.ok,false);eq(w.published,0)
end)
test('settlement observer stopping app suppresses stale success callback',function()
	local w=world();local r=w:start();r:on_settled(function()w.controller:stop_app()end);w:ready()
	eq(r.result.ok,true);eq(w.completed,0);eq(w.controller:app_status(),'absent')
end)
test('app source callback may stop exact app during status observation',function()
	local w=world();w:start();w:ready()
	w.on_app_current=function()w.on_app_current=nil;w.controller:stop_app()end
	eq(w.controller:app_status(),'absent');eq(w.controller:has_debt(),false)
end)
test('old app physical settlement cannot clear acknowledged successor',function()
	local w=world();w:start();w:ready();local old=w:last('service')
	local next_request,next_service
	old:on_settled(function()
		w.source=true
		next_request=w:start();next_service=w:last('service');w:ready()
	end)
	eq(w.controller:stop_app(),true)
	assert(next_service~=nil and next_service~=old,'successor must acquire distinct service')
	assert(next_request and next_request.result,'successor must publish a result')
	eq(next_request.result.ok,true)
	eq(w.controller:app_status(),'running');eq(w:last('service').cancelled,false)
end)
test('known native exit with pending close cannot borrow external version readiness',function()
	local w=world();w.hold.service=true;local r=w:start();w:last('service').exited=true;w:ready()
	eq(w.published,0);eq(r.result.ok,false);eq(r:is_settled(),false)
	w:last('service'):close();eq(r:is_settled(),true)
end)
test('logical current alone cannot report app running after native exit',function()
	local w=world();w:start();w:ready();w.hold.service=true;w:last('service').exited=true
	eq(w.controller:app_status(),'retiring');eq(w.controller:has_debt(),true)
	w:last('service'):close();eq(w.controller:app_status(),'absent')
end)
test('logical refusal notification never releases physical cleanup debt',function()
	local w=world();w.hold.service=true;local r=w:start();local verdict
	r:on_result(function(result)verdict=result end)
	w:last('service').exited=true;w:ready()
	assert(verdict and verdict.ok==false,'logical error verdict must be observable before physical cleanup')
	eq(r:is_settled(),false);eq(w.controller:has_debt(),true)
	w:last('service'):close();eq(r:is_settled(),true)
end)
test('busy request has a bound logical verdict observer without ambient callbacks',function()
	local w=world();w:start();local busy=w.controller:start(w.snapshot,'start',true)
	local verdict;eq(busy:on_result(function(result)verdict=result end),true)
	assert(verdict and verdict.error=='runtime_owner_busy','busy receipt must retain its own verdict')
	eq(busy:is_settled(),true)
end)
test('final observed running proof has no later source callback before promotion',function()
	local w=world();local r=w:start()
	w.after_write=function()w.observe_running=true;w.returned_running=false end
	w.on_runtime=function()
		if w.returned_running and r.result==nil then
			w.native_exit_observed_before_promotion=true;w:last('service').exited=true
		end
	end
	w:ready()
	eq(w.native_exit_observed_before_promotion,nil)
	eq(r.result.ok,true);eq(w.completed,1)
end)

end
local called, detail = pcall(run_registered)
for _, name in ipairs(names) do package.loaded[name] = previous[name] end
if not called then error(detail, 0) end
