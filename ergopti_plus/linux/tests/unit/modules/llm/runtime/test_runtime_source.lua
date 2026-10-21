--- tests/unit/modules/llm/runtime/test_runtime_source.lua

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
local Source = helpers.load_module("modules.llm.runtime_source")
local w
local function eq(a,b,why)assert(a==b,(why or 'value')..': expected '..tostring(b)..' got '..tostring(a))end
local Writer, fixture_ports
local function test(name, body)
	helpers.it(name .. " (ollama-runtime)", function()
		-- Port ownership belongs to each execution, not module registration:
		-- a runner may collect and replay cases after the module cache restores.
		local loaded = {}; for name, value in pairs(package.loaded) do loaded[name] = value end
		local prior_world, prior_writer = w, Writer
		for name, value in pairs(fixture_ports) do package.loaded[name] = value end
		local ok, detail = xpcall(body, debug.traceback)
		for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
		for name, value in pairs(loaded) do package.loaded[name] = value end
		w, Writer = prior_world, prior_writer
		if not ok then error(detail, 0) end
	end)
end
local logger={}
for _,name in ipairs({'info','warn','debug','error'})do
	logger[name]=function(_,message)if w and w.on_log then w.on_log(message)end end
end
fixture_ports={['logger.shim']=logger,['infra.logger']=logger,
	['infra.i18n']={get=function(k)return k end},['llm.profile_selector']={},['infra.llm_bridge']={}}
for name,value in pairs(fixture_ports)do package.loaded[name]=value end
Writer = helpers.load_module("toml_codec.writer")
local function world()
	Writer = helpers.load_module("toml_codec.writer")
	w={bytes='[llm]\nenabled = false\n[llm.models]\nselected = "ollama"\nollama = "llama3.2:3b"\n',state={
		paused=false,blocked=false,enabled=false,backend='ollama',model='llama3.2:3b',
		origin='http://127.0.0.1:11434',revision=5,app_epoch=2},writes=0}
	local owner=w
	local memory={}
	function memory.read_with_status()
		owner.reads=(owner.reads or 0)+1
		if owner.batch_frame then
			owner.batch_frame.reads=owner.batch_frame.reads+1
			if owner.on_publication_read then owner.on_publication_read(owner.batch_frame)end
		end
		if owner.on_read then owner.on_read(owner.reads)end
		return owner.bytes,'ok'
	end
	function memory.write_if_unchanged(_,content,source)
		if owner.write_refused or source.status~='ok' or source.content~=owner.bytes then return false,'source changed'end
		owner.bytes=content;owner.writes=owner.writes+1;return true
	end
	function memory.write_if_unchanged_admitted(path,content,source,on_error,admission)
		if source.status~='ok' or source.content~=owner.bytes then return false,'source changed'end
		local called,allowed=pcall(admission)
		if not called or allowed~=true then return false,'final admission refused'end
		return memory.write_if_unchanged(path,content,source)
	end
	local routed={}
	function routed.write_refusal(path)return Writer.write_refusal(path)end
	function routed.read_classified(path)return Writer.read_classified(path,memory)end
	function routed.prepare_batch(path,rows,_,expected)return Writer.prepare_batch(path,rows,memory,expected)end
	function routed.batch_write(path,rows,_,expected,on_error,admission)
		local prior=owner.batch_frame
		owner.batch_frame={reads=0,rows=rows}
		local ok,a,b,c=pcall(Writer.batch_write,path,rows,memory,expected,on_error,admission)
		owner.batch_frame=prior
		if not ok then error(a,0)end
		return a,b,c
	end
	local definitions={['llm.models.selected']={path='llm.models.selected',type='enum'},['llm.models.ollama']={path='llm.models.ollama',type='string'},['llm.enabled']={path='llm.enabled',type='boolean'}}
	local manifest={find_entry_by_path=function(path)return definitions[path]end,
		default_for=function(path)return ({['llm.models.selected']='ollama',['llm.models.ollama']='llama3.2:3b',['llm.enabled']=false})[path]end,
		sparse_operation=function(path,value)
			if path=='llm.enabled'then return {section='llm',key='enabled',value=value}end
			if path=='llm.models.selected'then return {section='llm.models',key='selected',value=value}end
			return {section='llm.models',key='ollama',value=value}
		end}
	package.loaded['infra.manifest_reader']=manifest
	package.loaded['infra.config_paths']={config=function()return '/memory/config.toml'end}
	package.loaded['config_outdated']={manifest_value_fits=function()return true end,report=function()end}
	package.loaded['toml_codec.writer']=routed
	local prefs = helpers.load_module("infra.llm_preferences")
	package.loaded['infra.llm_preferences']=prefs
	local profiles = helpers.load_module("modules.llm.profiles")
	owner.preferences,owner.profiles=prefs,profiles
	local engine={state=function()
		local backend=prefs.get('llm.models.selected') or manifest.default_for('llm.models.selected')
		local copy={};for k,v in pairs(owner.state)do copy[k]=v end
		copy.backend=backend;return copy
	end}
	function engine.admit_write(revision,app_epoch,enabled,observe_source)
		if owner.on_native_pause then owner.on_native_pause()end
		local observed=observe_source()
		return observed==true and owner.state.paused==false and owner.state.blocked==false
			and owner.state.revision==revision and owner.state.app_epoch==app_epoch and owner.state.enabled==enabled
	end
	function engine.publish_enabled(revision,app_epoch)
		if owner.on_native_pause then owner.on_native_pause()end
		if owner.publish_refused or owner.state.revision~=revision or owner.state.app_epoch~=app_epoch then return false end
		owner.state.enabled=true
		if owner.after_publish then owner.after_publish()end
		return true
	end
	function engine.restore_disabled(revision,app_epoch)
		if owner.on_native_pause then owner.on_native_pause()end
		if owner.restore_refused or owner.state.revision~=revision or owner.state.app_epoch~=app_epoch then return false end
		owner.state.enabled=false;return true
	end
	owner.source=Source.new({preferences=prefs,profiles=profiles,writer=routed,manifest=manifest,engine=engine,backend_key='llm.models.selected',path='/memory/config.toml'})
	package.loaded['toml_codec.writer']=Writer
	-- Actual Preferences captured its routed Writer at module import.
	function owner:capture()self.handle=self.source.capture();assert(self.handle,'source capture must be admitted');return self.handle end
	function owner:publish()
		self.accept_count=0
		return self.source.publish(self.handle,function(proof)
			self.accept_count=self.accept_count+1;self.proof=proof
			self.application=self.source.app_capture(proof,self.handle,self.runtime,self.handle.origin)
			return self.application~=nil
		end)
	end
	owner.runtime={};return owner
end
test('actual profile/preference/shared writer ACK produces exact private app proof',function()
	local v=world();v:capture();local before=v.preferences.generation();eq(v:publish(),true)
	eq(v.writes,1);eq(v.accept_count,1);eq(v.preferences.generation(),before+2);eq(v.state.enabled,true)
	eq(v.source.app_current(v.application,v.runtime,v.handle.origin),true)
end)
test('exact preview preserves independent unrelated bytes',function()
	local v=world();v.bytes=v.bytes..'# independent preserved comment\n';v:capture();eq(v:publish(),true)
	eq(v.bytes:find('# independent preserved comment',1,true)~=nil,true)
end)
test('source drift before write refuses existing writer',function()
	local v=world();v:capture();v.bytes=v.bytes..'# another source\n';eq(v:publish(),false);eq(v.writes,0)
end)
test('same-byte acknowledged preference write retires old repair ticket',function()
	local v=world();v:capture();eq(v.preferences.set('llm.enabled',false),true);eq(v:publish(),false);eq(v.accept_count,0)
end)
test('native cancel revision before write refuses writer',function()
	local v=world();v:capture();v.state.revision=v.state.revision+1;eq(v:publish(),false);eq(v.writes,0)
end)
test('refused physical preference writer creates no app proof',function()
	local v=world();v:capture();v.write_refused=true;eq(v:publish(),false);eq(v.accept_count,0);eq(v.profiles.is_enabled(),false)
end)
test('same-byte preference write during profile log rejects postwriter proof',function()
	local v=world();v:capture();v.on_log=function(message)
		if message=='LLM enabled.'then v.on_log=nil;v.preferences.set('llm.enabled',true)end
	end
	eq(v:publish(),false);eq(v.accept_count,0);eq(v.profiles.is_enabled(),true)
end)
test('foreign bytes during profile log never gain original candidate authority',function()
	local v=world();v:capture();v.on_log=function(message)if message=='LLM enabled.'then v.on_log=nil;v.bytes=v.bytes..'# foreign\n'end end
	eq(v:publish(),false);eq(v.accept_count,0);eq(v.state.enabled,false)
end)
test('native cancel during profile log rejects successful saved proof',function()
	local v=world();v:capture();v.on_log=function(message)if message=='LLM enabled.'then v.state.revision=v.state.revision+1 end end
	eq(v:publish(),false);eq(v.accept_count,0)
end)
test('paused profile log suppresses app publication',function()
	local v=world();v:capture();v.on_log=function(message)if message=='LLM enabled.'then v.state.paused=true end end
	eq(v:publish(),false);eq(v.accept_count,0)
end)
test('engine refuses active state publication after successful save',function()
	local v=world();v:capture();v.publish_refused=true;eq(v:publish(),false);eq(v.profiles.is_enabled(),true);eq(v.state.enabled,false);eq(v.accept_count,0)
end)
test('engine publication source drift cannot yield app proof',function()
	local v=world();v:capture();v.after_publish=function()v.preferences.set('llm.models.ollama','other:model')end
	eq(v:publish(),false);eq(v.accept_count,0)
end)
test('writer proof cannot be replayed to another runtime',function()
	local v=world();v:capture();eq(v:publish(),true)
	eq(v.source.app_capture(v.proof,v.handle,{},v.handle.origin),nil)
end)
test('foreign writer proof cannot gain app identity',function()
	local v=world();v:capture();eq(v.source.app_capture({},v.handle,v.runtime,v.handle.origin),nil)
end)
test('disable ticket leaves acknowledged app source independent',function()
	local v=world();v:capture();eq(v:publish(),true);eq(v.profiles.disable(),true)
	v.state.enabled=false;v.state.revision=v.state.revision+1;v.source.retire(v.handle)
	eq(v.source.app_current(v.application,v.runtime,v.handle.origin),true)
end)
test('model change leaves running same-origin app source current',function()
	local v=world();v:capture();eq(v:publish(),true);v.preferences.set('llm.models.ollama','other:model');v.state.model='other:model';v.state.revision=v.state.revision+1
	eq(v.source.app_current(v.application,v.runtime,v.handle.origin),true)
end)
test('backend source drift retires app source',function()
	local v=world();v:capture();eq(v:publish(),true);v.preferences.set('llm.models.selected','api')
	eq(v.source.app_current(v.application,v.runtime,v.handle.origin),false)
end)
test('scope lifecycle epoch retires app despite same endpoint',function()
	local v=world();v:capture();eq(v:publish(),true);v.state.app_epoch=v.state.app_epoch+1
	eq(v.source.app_current(v.application,v.runtime,v.handle.origin),false)
end)
test('pause retires acknowledged app source',function()
	local v=world();v:capture();eq(v:publish(),true);v.state.paused=true
	eq(v.source.app_current(v.application,v.runtime,v.handle.origin),false)
end)
test('physical native origin drift retires stable app source',function()
	local v=world();v:capture();eq(v:publish(),true);v.state.origin='http://127.0.0.1:1234'
	eq(v.source.app_current(v.application,v.runtime,v.handle.origin),false)
end)
test('classified second-read backend drift cannot borrow an old Ollama value',function()
	local v=world();v:capture();eq(v:publish(),true);local target=v.reads+2
	v.on_read=function(count)if count==target then v.bytes=v.bytes:gsub('selected = "ollama"','selected = "api"')end end
	eq(v.source.app_current(v.application,v.runtime,v.handle.origin),false)
end)
test('classified second-read enabled-only edit preserves stable app source',function()
	local v=world();v:capture();eq(v:publish(),true);local target=v.reads+2
	v.on_read=function(count)if count==target then v.bytes=v.bytes:gsub('enabled = true','enabled = false')end end
	eq(v.source.app_current(v.application,v.runtime,v.handle.origin),true)
end)
test('classified second-read model-only edit preserves stable app source',function()
	local v=world();v:capture();eq(v:publish(),true);local target=v.reads+2
	v.on_read=function(count)if count==target then v.bytes=v.bytes:gsub('llama3.2:3b','other:model')end end
	eq(v.source.app_current(v.application,v.runtime,v.handle.origin),true)
end)
test('existing writer conditionally restores prior false after refused native handoff',function()
	local v=world();v:capture();v.publish_refused=true;eq(v:publish(),false)
	eq(v.preferences.get('llm.enabled'),true);eq(v.state.enabled,false)
	eq(v.source.compensate(v.handle),true)
	eq(v.preferences.get('llm.enabled'),false);eq(v.profiles.is_enabled(),false);eq(v.state.enabled,false)
	eq(v.writes,2)
end)
test('own native ACK may be restored after declined application proof',function()
	local v=world();v:capture()
	local accepted=v.source.publish(v.handle,function()return false end)
	eq(accepted,false);eq(v.state.enabled,true)
	eq(v.source.compensate(v.handle),true)
	eq(v.preferences.get('llm.enabled'),false);eq(v.state.enabled,false)
end)
test('conditional compensation refuses exact foreign replacement bytes',function()
	local v=world();v:capture();v.publish_refused=true;eq(v:publish(),false)
	v.bytes=v.bytes..'# foreign replacement image\n';local foreign=v.bytes
	eq(v.source.compensate(v.handle),false);eq(v.bytes,foreign);eq(v.preferences.get('llm.enabled'),true)
	eq(v.state.enabled,false);eq(v.writes,1)
end)
test('conditional compensation refuses newer same-byte enabled intent',function()
	local v=world();v:capture();v.publish_refused=true;eq(v:publish(),false)
	eq(v.preferences.set('llm.enabled',true),true)
	eq(v.source.compensate(v.handle),false);eq(v.preferences.get('llm.enabled'),true);eq(v.writes,2)
end)
test('conditional compensation never restores an independently changed native context',function()
	local v=world();v:capture();v.publish_refused=true;eq(v:publish(),false)
	v.state.revision=v.state.revision+1
	eq(v.source.compensate(v.handle),false);eq(v.preferences.get('llm.enabled'),true);eq(v.writes,1)
end)
test('native publish pause callback cannot borrow an older app lifetime',function()
	local v=world();v:capture();v.on_native_pause=function()v.state.app_epoch=v.state.app_epoch+1 end
	eq(v:publish(),false);eq(v.state.enabled,false);eq(v.accept_count,0)
end)
test('native restore pause callback cannot mutate a successor app lifetime',function()
	local v=world();v:capture();eq(v.source.publish(v.handle,function()return false end),false)
	eq(v.state.enabled,true);v.on_native_pause=function()v.state.app_epoch=v.state.app_epoch+1 end
	eq(v.source.compensate(v.handle),false);eq(v.state.enabled,true)
end)
local function revoke_in_final_read(v,change)
	v.on_publication_read=function(frame)
		if frame.reads==2 then
			v.on_publication_read=nil
			v.final_read_reached=true
			change()
		end
	end
end
test('source final classified read cannot disable newer native intent',function()
	local v=world();v:capture();v.publish_refused=true;eq(v:publish(),false)
	local before=v.bytes
	revoke_in_final_read(v,function()v.state.revision=v.state.revision+1 end)
	eq(v.source.compensate(v.handle),false);eq(v.final_read_reached,true)
	eq(v.bytes,before);eq(v.writes,1);eq(v.profiles.is_enabled(),true)
end)
test('source final classified read cannot disable successor app lifetime',function()
	local v=world();v:capture();v.publish_refused=true;eq(v:publish(),false)
	local before=v.bytes
	revoke_in_final_read(v,function()v.state.app_epoch=v.state.app_epoch+1 end)
	eq(v.source.compensate(v.handle),false);eq(v.final_read_reached,true)
	eq(v.bytes,before);eq(v.writes,1);eq(v.profiles.is_enabled(),true)
end)
test('source final classified read cannot disable newer same-byte preference intent',function()
	local v=world();v:capture();v.publish_refused=true;eq(v:publish(),false)
	local before=v.bytes;local changed
	revoke_in_final_read(v,function()changed=v.preferences.set('llm.enabled',true)end)
	eq(v.source.compensate(v.handle),false);eq(v.final_read_reached,true);eq(changed,true)
	eq(v.bytes,before);eq(v.writes,2);eq(v.profiles.is_enabled(),true)
end)
test('source final classified read cannot disable newly acquired scope owner',function()
	local v=world();v:capture();v.publish_refused=true;eq(v:publish(),false)
	local before=v.bytes;local acquired
	revoke_in_final_read(v,function()acquired=v.preferences.acquire({pending=function()return false end})end)
	eq(v.source.compensate(v.handle),false);eq(v.final_read_reached,true);eq(acquired,true)
	eq(v.bytes,before);eq(v.writes,1);eq(v.profiles.is_enabled(),true)
end)
test('enable final classified read cannot publish after native cancellation',function()
	local v=world();v:capture();local before=v.bytes
	revoke_in_final_read(v,function()v.state.revision=v.state.revision+1 end)
	eq(v:publish(),false);eq(v.final_read_reached,true);eq(v.bytes,before)
	eq(v.writes,0);eq(v.state.enabled,false);eq(v.profiles.is_enabled(),false)
end)
test('continuously changing classified source is unavailable without native admission',function()
	local v=world();v.on_read=function()v.bytes=v.bytes..'# changed source\n'end
	eq(v.source.capture(),nil);eq(v.writes,0)
end)

test('canonical protected writer refuses runtime publication without effects',function()
	local v=world();local before=v.bytes
	Writer.refuse_writes('/memory/config.toml','future schema protected')
	eq(v.preferences.admit(),false)
	eq(v.preferences.set('llm.enabled',true),false)
	eq(v.source.capture(),nil);eq(v.writes,0);eq(v.bytes,before)
	eq(v.state.enabled,false);eq(v.profiles.is_enabled(),false)
end)

-- Fresh native backend reads use the real Preferences.get below. A concurrent
-- file edit can therefore advance its revision after Source.get_many returned.
local function diagnostic_test(name,body)
	test(name,function()body(world())end)
end
local function diagnostic_origin(v, branch)
	v:capture()
	if branch ~= 'original' then eq(v:publish(), true) end
	if branch == 'compensated' then eq(v.source.compensate(v.handle), true) end
end
for _, branch in ipairs({ 'original', 'saved', 'compensated' }) do
	diagnostic_test('runtime diagnostic retains its healthy '..branch..' source', function(v)
		diagnostic_origin(v, branch); v.reads=0
		eq(v.source.diagnostic_current(v.handle), true)
		eq(v.reads, 2, 'one source snapshot and the existing native backend read')
	end)
	diagnostic_test('runtime diagnostic refuses a source revision observed during native read: '..branch, function(v)
		diagnostic_origin(v, branch); v.reads=0
		local edited=false
		v.on_read=function(count)
			if count==2 then edited=true;v.bytes=v.bytes..'# concurrent external edit\n' end
		end
		eq(v.source.diagnostic_current(v.handle), false)
		eq(edited, true);eq(v.reads, 2, 'the final fence must be RAM-only')
	end)
end
for _, mutation in ipairs({ 'backend', 'model', 'same-byte-write' }) do
	diagnostic_test('runtime diagnostic refuses '..mutation..' during native preference read', function(v)
		diagnostic_origin(v, 'original');v.reads=0
		local changed=false
		v.on_read=function(count)
			if count~=2 then return end
			v.on_read=nil;changed=true
			if mutation=='backend' then v.bytes=v.bytes:gsub('selected = "ollama"','selected = "api"')
			elseif mutation=='model' then v.bytes=v.bytes:gsub('llama3.2:3b','new:model')
			else
				local before=v.bytes
				eq(v.preferences.set('llm.models.ollama','llama3.2:3b'), true)
				eq(v.bytes,before,'real acknowledged write retained exactly the same bytes')
			end
		end
		eq(v.source.diagnostic_current(v.handle),false);eq(changed,true)
	end)
end
diagnostic_test('runtime diagnostic cannot revive a retired notice source from native read',function(v)
	diagnostic_origin(v,'original');v.reads=0
	v.on_read=function(count)if count==2 then v.source.retire(v.handle)end end
	eq(v.source.diagnostic_current(v.handle),false)
end)

for _, stale in ipairs({ false, true }) do
	diagnostic_test('runtime diagnostic exact failure caller '..(stale and 'withholds stale notice' or 'delivers current notice'),function(v)
		diagnostic_origin(v,'original');v.reads=0
		if stale then v.on_read=function(count)if count==2 then v.bytes=v.bytes..'# external source edit\n'end end end
		local notices, logs=0,0
		package.loaded['adapters.notifier']={send=function(_,options)
			notices=notices+1;eq(options.level,'error');return true
		end}
		v.on_log=function(template)
			if template:find('Local Ollama repair refused',1,true)then logs=logs+1 end
		end
		local file=assert(io.open(helpers.driver_root()..'/modules/llm/prediction_engine.lua','rb'))
		local text=file:read('*a');file:close()
		local callback=assert(text:match('request:on_result%((function%(result%).-\n\t\t\t\tend)%)'), 'actual production runtime failure observer')
		local env={type=type,tostring=tostring,require=require,Logger=logger,LOG='runtime-notice-test',
			owner={source=v.source},handle=v.handle,I18n=require('infra.i18n')}
		local chunk
		if setfenv then chunk=assert(loadstring('return '..callback));setfenv(chunk,env)
		else chunk=assert(load('return '..callback,'actual-runtime-error-observer','t',env))end
		chunk()({ok=false,error='fixture_runtime_refusal'})
		eq(notices,stale and 0 or 1);eq(v.reads,2)
		-- This change owns the notifier lifetime, not the existing error log.
		eq(logs,1)
	end)
end

end
local called, detail = pcall(run_registered)
for _, name in ipairs(names) do package.loaded[name] = previous[name] end
if not called then error(detail, 0) end
