--- ai/engine/local_servers/runtime_composition.lua

--- ==============================================================================
--- MODULE: Linux Ollama Runtime Composition
--- DESCRIPTION:
--- Connects shared repair policy to source, file, process, HTTP and timer
--- owners without publishing configuration.
--- ==============================================================================

local Repair=require('ai.engine.local_servers.runtime_repair')
local Receipt=require('ai.engine.settings.enable_admission_core')
local Json=require('core.text.engine.json')
local Logger=require('core.logger.engine.shim')
local LOG='ai.engine.local_servers.runtime_composition'
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
--- process (single finite/service bridge), http, owned_timer, timings, environment,
--- serve_environment (rows of the shared managed_ollama_environment.json),
--- optional network ({policy,lookup,timeout_ms,origins,relay}: the shared proxy policy,
--- the owned system proxy lookup, its bound, the route_origins.json "ollama"
--- inventory and the sign-in relay binding (core/network/engine/proxy_auth_relay.lua: policy,
--- probe, timeout_ms, executable, timings), see ../ollama/managed_ollama_proxy.lua).
--- listeners ({listening,owned}, ../ollama/listener_owner.lua) proves the
--- answering socket is the owned daemon's; seal ({command,digests,encode,matches,
--- read,write,NAME}, ../ollama/runtime_seal.lua) checks the tree against its
--- pinned archive; retention ({stale,remove}, ../ollama/runtime_retention.lua)
--- removes the release folders an update left behind.
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
	local listeners,seal,retention=d.listeners,d.seal,d.retention
	assert(type(listeners)=='table' and type(listeners.listening)=='function' and type(listeners.owned)=='function',
		'runtime listener port unavailable')
	assert(type(seal)=='table' and type(seal.command)=='function' and type(seal.digests)=='function'
		and type(seal.encode)=='function' and type(seal.matches)=='function' and type(seal.read)=='function'
		and type(seal.write)=='function' and type(seal.NAME)=='string', 'runtime seal port unavailable')
	assert(type(retention)=='table' and type(retention.stale)=='function' and type(retention.remove)=='function',
		'runtime retention port unavailable')
	-- The service the last start dispatched: readiness is admitted from its socket only.
	local owned_service=nil
	-- One removal at a time; a refused one is listed again by the next start.
	local retiring=nil
	local function retire(paths,label)
		if retiring and not retiring:is_settled() then return end
		retiring=retention.remove(paths,d.process,bootstrap,label)
	end
	local admission_new=d.admission.new
	local environment=d.environment
	assert(type(environment)=='function', 'captured native environment port unavailable')
	-- The shared serve environment keeps the owned daemon on local models only.
	local serve_environment,owned_names={},{}
	assert(type(d.serve_environment)=='table' and #d.serve_environment>0, 'managed serve environment unavailable')
	for _,row in ipairs(d.serve_environment) do
		local name=type(row)=='string' and row:match('^([A-Z][A-Z0-9_]*)=')
		assert(name and name~='OLLAMA_HOST' and not row:find('\0',1,true), 'managed serve environment invalid')
		serve_environment[#serve_environment+1]=row;owned_names[name]=true
	end
	-- Names the proxy selection may add; the base environment never keeps its own copy.
	local proxy_names={}
	local network=d.network
	if network~=nil then
		assert(type(network)=='table' and type(network.policy)=='table' and type(network.lookup)=='function'
			and type(network.timeout_ms)=='number' and type(network.origins)=='table'
			and type(network.relay)=='table' and type(network.relay.executable)=='function'
			and type(network.relay.timings)=='function', 'managed network port unavailable')
		for _,name in ipairs(require('ai.engine.ollama.managed_ollama_proxy').VARIABLES) do proxy_names[name]=true end
	end
	local p={current=s.current,publish=s.publish,app_capture=s.app_capture,app_current=s.app_current, compensate=s.compensate,
		after=d.owned_timer.after, now_ms=d.owned_timer.now_ms}
	function p.resolve(snapshot)
		if not current(function()return s.current(snapshot)end) or not current(resolve_current) then return {status='unavailable'} end
		local result=installed_capture(d.resolver)
		if not current(function()return s.current(snapshot)end) or not current(resolve_current) then return {status='unavailable'} end
		return result
	end
	--- Hashes the tree's files and checks them against the seal its install
	--- wrote, or writes that seal right after the install that checked the
	--- pinned archive (fresh). A tree that fails is never started and is
	--- removed, so the next download installs it again from the archive.
	function p.verify(runtime,budget,authorized,fresh,done)
		if not current(authorized) then return empty('runtime_source_changed',done) end
		local plan=get_plan()
		local files=type(runtime)=='table' and type(runtime.files)=='function' and runtime.files() or nil
		if type(plan)~='table' or type(plan.asset)~='table' or type(plan.parent)~='string'
			or type(plan.directory)~='string' or type(files)~='table' or #files==0 then
			return empty('runtime_seal_plan_unavailable',done)
		end
		local path=plan.parent .. '/' .. seal.NAME
		local text,missing
		if not fresh then
			text,missing=seal.read(path)
			if not text then
				Logger.error(LOG,'The managed Ollama at %s has no readable seal (%s); it is removed and must be downloaded again.',
					plan.directory,tostring(missing))
				retire({plan.parent},'the unsealed Ollama runtime')
				return empty(missing or 'runtime_seal_unreadable',done)
			end
		end
		local remaining=budget.remaining_ms()
		if type(remaining)~='number' or remaining<=0 then return empty('runtime_timeout',done) end
		local program,args=seal.command(files)
		Logger.info(LOG,'%s the managed Ollama runtime (%d files)...',fresh and 'Sealing' or 'Verifying',#files)
		return d.process.start(program,args,{owner='ollama-runtime-seal',authorized=authorized,
			timeout_ms=math.min(bootstrap,remaining)},function(result)
			if not current(authorized) then return end
			local digests,reason=seal.digests(result,files)
			if not digests then
				Logger.warn(LOG,'The managed Ollama runtime could not be hashed (%s).',tostring(reason))
				done({ok=false,error=reason});return
			end
			if fresh then
				local rendered=seal.encode(plan.directory,digests,plan.asset.sha256)
				if not rendered or not seal.write(path,rendered) then
					Logger.error(LOG,'The seal of the managed Ollama runtime could not be written to %s.',path)
					done({ok=false,error='runtime_seal_write_refused'});return
				end
				Logger.info(LOG,'Managed Ollama runtime sealed.')
				done({ok=true});return
			end
			local matches,refusal=seal.matches(text,plan.directory,digests,plan.asset.sha256)
			if not matches then
				Logger.error(LOG,'The managed Ollama at %s does not match its seal (%s); it is removed and must be downloaded again.',
					plan.directory,tostring(refusal))
				retire({plan.parent},'the altered Ollama runtime')
				done({ok=false,error=refusal});return
			end
			Logger.info(LOG,'Managed Ollama runtime verified.')
			done({ok=true})
		end)
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
		-- Rows the proxy stage selected: only its declared variables, never a newline.
		-- A variable is replaced only when the stage chose a value for it, so a proxy
		-- the user exported (which the stage leaves alone) reaches the daemon intact.
		local selected,replaced={},{}
		for _,row in ipairs(options.environment or {}) do
			local name=type(row)=='string' and row:match('^([%a_][%w_]*)=')
			if not name or not proxy_names[name] or row:find('[%z\r\n]') then
				return empty('runtime_environment_unavailable',done)
			end
			selected[#selected+1]=row;replaced[name]=true
		end
		local env={}
		for key,item in pairs(base) do
			if type(key)~='number' or key<=0 or key%1~=0 or type(item)~='string'
				or not item:match('^[^=]+=' ) or item:find('\0',1,true) then
				return empty('runtime_environment_unavailable',done)
			end
			-- The configured loopback origin is the exact bind address. Existing
			-- process environment is otherwise preserved, including library paths.
			local name=item:match('^([^=]+)=')
			if name~='OLLAMA_HOST' and not owned_names[name] and not replaced[name] then env[#env+1]=item end
		end
		env[#env+1]='OLLAMA_HOST=' .. options.host
		for _,row in ipairs(serve_environment) do env[#env+1]=row end
		for _,row in ipairs(selected) do env[#env+1]=row end
		if not current(authorized) then return empty('runtime_source_changed',done) end
		-- The owned daemon binds its own port: a server already listening there
		-- would answer the readiness probe in its place (OLL-13).
		local port=tonumber(type(options.host)=='string' and options.host:match(':(%d+)$'))
		local held,unreadable=listeners.listening(port)
		if not held then return empty(unreadable or 'runtime_listener_unreadable',done) end
		if next(held)~=nil then
			Logger.warn(LOG,'Another server already listens on port %s; the managed Ollama is not started.',tostring(port))
			return empty('runtime_port_occupied',done)
		end
		-- A proxy that demands an NTLM/Negotiate sign-in: the relay serves the
		-- daemon for its lifetime and is the process this service owns, so it
		-- stops with Ergopti exactly as the daemon did (proxy-auth-relay.md).
		if options.relay~=nil then
			local relay=network and network.relay
			local relay_executable=relay and relay.executable()
			if type(options.relay)~='table' or not relay_executable then
				return empty('runtime_proxy_relay_unavailable',done)
			end
			local wrapped=relay.policy.run_args(options.relay.upstream,
				{require('ai.engine.ollama.managed_ollama_proxy').VARIABLE},relay.timings(),executable,args)
			if not wrapped then return empty('runtime_proxy_relay_unavailable',done) end
			executable,args=relay_executable,wrapped
		end
		local service=serve_start(executable,args,{owner=options.owner,authorized=authorized,
			timeout_ms=false,env=env,capture_tail=true},done)
		owned_service=service
		return service
	end
	if network~=nil then
		local proxy_port=require('ai.engine.ollama.managed_ollama_proxy').new({policy=network.policy,lookup=network.lookup,
			environment=environment,timeout_ms=network.timeout_ms,owner='ollama-runtime-proxy',origins=network.origins,
			relay=network.relay,
			probe=network.probe,relay_address=network.relay_address,probe_timeout_ms=network.probe_timeout_ms})
		function p.network(budget,authorized,done) return proxy_port(budget,authorized,done) end
	end
	function p.probe(url,budget,authorized,done)
		if not current(authorized) then return empty('runtime_source_changed',done) end
		-- Native source admission precedes the final remaining-budget read.
		local remaining=budget.remaining_ms()
		if type(remaining)~='number' or remaining<=0 then return empty('runtime_timeout',done) end
		local port=tonumber(url:match('^http://[^/]*:(%d+)/'))
		return http_get(url,{}, {timeout_ms=math.min(probe_timeout,remaining),
			owner='ollama-runtime-version',follow_redirects=false,https_only=false,authorized=authorized},function(result)
			-- A stale logical response never publishes. The returned HTTP operation
			-- remains independently retained until physical process/group/close ACK.
			if not current(authorized) then return end
			if not Receipt.receipt(result) then done(result);return end
			-- Only the daemon this composition started may answer, with the pinned
			-- version, as Windows admits only its child's socket (OLL-13). A
			-- foreign answer is not readiness: the owned daemon, which cannot
			-- bind, exits and ends the repair.
			local service=owned_service
			local pid=service and type(service.pid)=='function' and service:pid() or nil
			local owned,refusal=listeners.owned(port,pid)
			if not owned then
				Logger.warn(LOG,'A server on port %s answered that is not the managed Ollama (%s).',tostring(port),tostring(refusal))
				done({ok=false,error='runtime_'..tostring(refusal)});return
			end
			local plan=get_plan()
			local version=Json.decode_lossless(result.body).version
			if type(plan)~='table' or type(plan.asset)~='table' or version~=plan.asset.version then
				Logger.error(LOG,'The managed Ollama answered version %s, not the pinned %s; it is stopped.',
					tostring(version),tostring(type(plan)=='table' and type(plan.asset)=='table' and plan.asset.version))
				pcall(service.cancel,service)
				done({ok=false,error='runtime_version_mismatch'});return
			end
			-- The pinned release is verified and serving: an update's earlier
			-- release folders can go (OLL-07).
			local stale,scan_refusal=retention.stale(plan)
			if not stale then
				Logger.warn(LOG,'Earlier Ollama runtimes could not be listed (%s); retried at the next start.',tostring(scan_refusal))
			elseif #stale>0 then
				retire(stale,'the earlier Ollama runtimes')
			end
			done(result)
		end)
	end
	return Repair.new(p,{bootstrap_timeout_ms=bootstrap,poll_ms=poll})
end
return M
