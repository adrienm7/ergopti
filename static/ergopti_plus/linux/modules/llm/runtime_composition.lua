--- modules/llm/runtime_composition.lua

--- ==============================================================================
--- MODULE: Linux Ollama Runtime Composition
--- DESCRIPTION:
--- Connects shared repair policy to source, file, process, HTTP and timer
--- owners without publishing configuration.
--- ==============================================================================

local Repair=require('llm.runtime_repair')
local M={}
local function empty(reason, done)
	local op={started=false,result={ok=false,error=reason}}
	function op:cancel() return true end
	function op:is_settled() return true end
	function op:on_settled(fn) if type(fn)~='function' then return false end; pcall(fn); return true end
	if type(done)=='function' then pcall(done,op.result) end
	return op
end
local function current(fn)
	local ok,value=pcall(fn); return ok and value==true
end
--- deps: source, resolver, installed, file_factory, admission, install_phase,
--- process (single finite/service bridge), http, owned_timer, timings, environment.
--- `source` owns captured enable/app source proofs and existing writer ACK.
function M.new(deps)
	assert(type(deps)=='table', 'runtime composition unavailable')
	local d={};for k,v in pairs(deps) do d[k]=v end
	local source=d.source
	assert(type(source)=='table' and type(source.current)=='function'
		and type(source.publish)=='function' and type(source.app_capture)=='function'
		and type(source.app_current)=='function', 'runtime writer/source port unavailable')
	local s={};for k,v in pairs(source) do s[k]=v end
	local bootstrap=d.timings.ms('llm','dependency_bootstrap_timeout_ms')
	local probe_timeout=d.timings.ms('llm','local_server_probe_timeout_ms')
	local poll=d.timings.ms('ui','ollama_deps_poll_ms')
	local phase_start,serve_start,http_get=d.install_phase.start,d.process.start_service,d.http.get_owned
	local get_plan,resolve_current=d.resolver.plan,d.resolver.current
	local installed_capture=d.installed.capture
	local admission_new=d.admission.new
	local environment=d.environment
	assert(type(environment)=='function', 'captured native environment port unavailable')
	local p={current=s.current,publish=s.publish,app_capture=s.app_capture,app_current=s.app_current, compensate=s.compensate,
		after=d.owned_timer.after, now_ms=d.owned_timer.now_ms}
	function p.resolve(snapshot)
		if not current(function()return s.current(snapshot)end) or not current(resolve_current) then return {status='unavailable'} end
		local result=installed_capture(d.resolver)
		if not current(function()return s.current(snapshot)end) or not current(resolve_current) then return {status='unavailable'} end
		return result
	end
	function p.install(snapshot,budget,authorized,done)
		if not current(authorized) then return empty('runtime_source_changed',done) end
		local plan=get_plan()
		if not current(authorized) or type(plan)~='table' or type(plan.asset)~='table' then
			return empty('runtime_asset_unavailable',done)
		end
		local files,reason=admission_new(d.resolver,d.file_factory,authorized,true)
		if not files then return empty(reason or 'runtime_file_admission_unavailable',done) end
		-- The phase owns reservation, budget subscription and every native stage.
		return phase_start({files=files,process=d.process,http=d.http,archive_factory=d.archive_factory}, {
			asset=plan.asset,explicit_consent=true,authorized=authorized,budget=budget,
			timeout_ms=bootstrap,helper_timeout_ms=bootstrap},done)
	end
	function p.start_service(executable,args,options,done)
		local authorized=options.authorized
		if not current(authorized) then return empty('runtime_source_changed',done) end
		local base=environment()
		if type(base)~='table' or not current(authorized) then return empty('runtime_environment_unavailable',done) end
		local env={}
		for key,item in pairs(base) do
			if type(key)~='number' or key<=0 or key%1~=0 or type(item)~='string'
				or not item:match('^[^=]+=' ) or item:find('\0',1,true) then
				return empty('runtime_environment_unavailable',done)
			end
			-- The configured loopback origin is the exact bind address. Existing
			-- process environment is otherwise preserved, including library paths.
			if not item:match('^OLLAMA_HOST=') then env[#env+1]=item end
		end
		env[#env+1]='OLLAMA_HOST=' .. options.host
		if not current(authorized) then return empty('runtime_source_changed',done) end
		return serve_start(executable,args,{owner=options.owner,authorized=authorized,
			timeout_ms=false,env=env,capture_tail=true},done)
	end
	function p.probe(url,budget,authorized,done)
		if not current(authorized) then return empty('runtime_source_changed',done) end
		-- Native source admission precedes the final remaining-budget read.
		local remaining=budget.remaining_ms()
		if type(remaining)~='number' or remaining<=0 then return empty('runtime_timeout',done) end
		return http_get(url,{}, {timeout_ms=math.min(probe_timeout,remaining),
			owner='ollama-runtime-version',follow_redirects=false,https_only=false,authorized=authorized},function(result)
			-- A stale logical response never publishes. The returned HTTP operation
			-- remains independently retained until physical process/group/close ACK.
			if current(authorized) then done(result) end
		end)
	end
	return Repair.new(p,{bootstrap_timeout_ms=bootstrap,poll_ms=poll})
end
return M
