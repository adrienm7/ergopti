--- _shared/lua/llm/runtime_repair.lua

--- ==============================================================================
--- MODULE: Shared Explicit Ollama Runtime Repair
--- DESCRIPTION:
--- Orchestrates user-authorized binary installation, observed owned serve,
--- typed readiness and acknowledged application lifetime handoff.
--- ==============================================================================

local Budget = require('llm.bootstrap_budget')
local Receipt = require('llm.enable_admission')
local M = {}

local function positive(value)
	return type(value) == 'number' and value > 0 and value <= 9007199254740991 and value % 1 == 0
end

--- Only canonical plaintext loopback origins can name this locally owned serve.
function M.loopback_origin(origin)
	if type(origin) ~= 'string' then return nil end
	local host, port = origin:match('^http://(127%.0%.0%.1):([1-9][0-9]*)$')
	if not host then
		port = origin:match('^http://%[::1%]:([1-9][0-9]*)$')
		if port then host = '[::1]' end
	end
	local number = port and tonumber(port)
	if not number or number > 65535 then return nil end
	return origin, host .. ':' .. port
end

local function yes(fn, ...)
	local ok, answer = pcall(fn, ...)
	return ok and answer == true
end

--- Ports are bound functions. Returned operations use colon lifetime methods.
--- Source/writer ports must retain their own opaque originating identity proofs.
function M.new(ports, policy)
	assert(type(ports) == 'table' and type(policy) == 'table'
		and positive(policy.bootstrap_timeout_ms) and positive(policy.poll_ms), 'runtime policy invalid')
	for _, key in ipairs({'current', 'resolve', 'install', 'start_service', 'probe', 'after',
		'now_ms', 'publish', 'app_capture', 'app_current', 'compensate'}) do
		assert(type(ports[key]) == 'function', 'runtime port missing: ' .. key)
	end
	-- Capture the ports once; arbitrary mutation of the caller table has no authority.
	local P = {}; for key, value in pairs(ports) do P[key] = value end
	local active, app, sequence, controller = nil, nil, 0, {}
	local bootstrap_ms, poll_ms=policy.bootstrap_timeout_ms, policy.poll_ms

	local function call(fn, ...)
		local ok, answer, detail = pcall(fn, ...)
		if ok then return answer, detail end
		return nil, 'runtime_port_exception'
	end
	local function op_settled(held)
		return held and not held.acquiring and not held.unknown
			and yes(held.settled, held.operation)
	end
	local function app_current(record)
		if app ~= record or record.stopping then return false end
		if not yes(record.runtime_current) then return false end
		if app ~= record or record.stopping then return false end
		return yes(P.app_current, record.source, record.runtime, record.origin)
			and app == record and not record.stopping
	end
	local function app_live(record)
		if not app_current(record) then return false end
		local held=record.service
		return type(held.running)=='function' and yes(held.running,held.operation)
			and app==record and not record.stopping
	end
	local function stop_held(held)
		if not held or held.acquiring or held.unknown then return false end
		if op_settled(held) then return true end
		pcall(held.cancel, held.operation)
		return op_settled(held)
	end
	local function retire_app(record)
		if record==nil or app ~= record then return app == nil end
		record.stopping = true
		stop_held(record.service)
		if op_settled(record.service) then
			if app==record then app=nil end
			return true
		end
		return false
	end
	function controller:stop_app()
		if not app then return true end
		return retire_app(app)
	end
	function controller:app_status()
		local record=app
		if not record then return 'absent' end
		local admitted=not record.stopping and app_live(record)
		-- The authoritative predicates may retire or replace this exact owner.
		if app~=record then return app and 'retiring' or 'absent' end
		if not admitted then retire_app(record); return app and 'retiring' or 'absent' end
		return 'running'
	end
	function controller:has_debt() return active ~= nil or (app ~= nil and app.stopping) end

	function controller:start(snapshot, action, explicit_consent, on_done)
		local request = {started = false}
		if active or app then
			request.result = {ok=false, error='runtime_owner_busy'}
			function request:is_settled() return true end
			function request:cancel() return true end
			function request:retry_cleanup() return true end
			function request:on_result(fn)
				if type(fn)~='function' then return false end
				local ok=pcall(fn,self.result)
				if not ok then self.observer_error='runtime_observer_refused' end
				return true
			end
			function request:on_settled(fn)
				if type(fn)~='function' then return false end
				pcall(fn);return true
			end
			return request
		end
		sequence = sequence + 1
		local entry = {request=request, snapshot=snapshot, resources={}, stage='admission',
			cancelled=false, settled=false, listeners={}, result_listeners={}, sequence=sequence}
		active = entry -- Reserve before source/native callbacks can reenter.
		local budget_owner, budget, service, descriptor, executable, runtime_current
		local candidate_app, pumping, again, failing = nil, false, false, false
		local pump, fail, acquire
		local function notify(fn, ...)
			if type(fn) ~= 'function' then return end
			local ok = pcall(fn, ...)
			if not ok then request.observer_error='runtime_observer_refused' end
		end
		local function current()
			if active ~= entry or entry.cancelled or entry.settled or type(snapshot)~='table'
				or snapshot.origin~=entry.origin then return false end
			if budget and not budget.current() then return false end
			if not yes(P.current, snapshot) then return false end
			return active == entry and not entry.cancelled and not entry.settled
				and snapshot.origin==entry.origin and (not budget or budget.current())
		end
		local function service_authorized()
			if candidate_app then
				if candidate_app.stopping then return false end
				if candidate_app == app then return app_current(candidate_app) end
				return active == entry and not entry.cancelled and yes(runtime_current)
					and yes(P.app_current, candidate_app.source, descriptor, entry.origin)
					and active == entry and not entry.cancelled
			end
			return current() and yes(runtime_current) and current()
		end
		local function all_retired(include_service)
			if entry.acquisition_unknown then return false end
			for _, held in ipairs(entry.resources) do
				if (include_service or held ~= service) and not op_settled(held) then return false end
			end
			return not budget_owner or budget_owner:is_settled()
		end
		local function complete()
			if entry.settled or not all_retired(not entry.promoted) then return false end
			entry.settled = true; request.cleanup_error = nil
			if active == entry then active = nil end
			local listeners=entry.listeners; entry.listeners={}
			for _, callback in ipairs(listeners) do notify(callback) end
			if not entry.cancelled and request.result and ((entry.promoted and candidate_app and app_live(candidate_app))
				or (not entry.promoted and yes(P.current, snapshot))) then
				notify(on_done, request.result)
			end
			return true
		end
		local function clean()
			for _, held in ipairs(entry.resources) do
				if held ~= service or not entry.promoted then stop_held(held) end
			end
			if budget_owner then budget_owner:cancel(request.result and request.result.error or 'runtime_cancelled') end
			if not complete() then request.cleanup_error='runtime_cleanup_pending' end
		end
		local function announce_result()
			local pending=entry.result_listeners;entry.result_listeners={}
			for _,callback in ipairs(pending) do notify(callback,request.result) end
		end
		fail = function(reason)
			if entry.promoted then return end
			if not failing then
				failing=true; request.result={ok=false,error=reason or 'runtime_refused'}
				announce_result()
			end
			entry.stage='cleanup'; clean()
		end
		function request:cancel()
			if entry.promoted or entry.settled then return true end
			entry.cancelled=true; fail('runtime_cancelled'); return entry.settled
		end
		function request:is_settled() return entry.settled end
		--- Observes a logical verdict independently of physical cleanup debt.
		--- @param fn function Observer; its result never releases native ownership.
		--- @return boolean registered
		function request:on_result(fn)
			if type(fn)~='function' then return false end
			if request.result then notify(fn,request.result)
			else entry.result_listeners[#entry.result_listeners+1]=fn end
			return true
		end
		function request:on_settled(fn)
			if type(fn) ~= 'function' then return false end
			if entry.settled then notify(fn) else entry.listeners[#entry.listeners+1]=fn end
			return true
		end
		function request:retry_cleanup()
			if entry.stage=='cleanup' then clean() elseif pump then pump() end
			return entry.settled
		end
		acquire = function(kind, constructor)
			local held = {kind=kind, acquiring=true}
			entry.resources[#entry.resources+1]=held
			local function completed(result)
				if held.delivered then return end
				held.delivered=true; held.result=result
				if pump and not held.acquiring then pump() end
			end
			local operation = call(constructor, completed)
			if type(operation)=='table' and type(operation.cancel)=='function'
				and type(operation.is_settled)=='function' and type(operation.on_settled)=='function' then
				held.operation=operation; held.cancel=operation.cancel; held.settled=operation.is_settled
				held.on_settled=operation.on_settled
				if kind=='service' then held.is_current=operation.is_current;held.running=operation.is_running end
				held.acquiring=false
				local ok, registered=pcall(held.on_settled, operation, function()
					if kind=='service' then
						if entry.promoted then
							if candidate_app then retire_app(candidate_app) end
						elseif entry.stage~='cleanup' then fail('runtime_service_unavailable')
						elseif pump then pump() end
					elseif pump then pump() end
				end)
				if not ok or registered~=true then request.observer_error='runtime_settlement_observer_refused' end
			else held.acquiring=false; held.unknown=true end
			return held
		end
		local function service_live()
			local held=service
			return held and not held.unknown and type(held.is_current)=='function'
				and type(held.running)=='function' and held.operation.started==true and not op_settled(held)
				and yes(held.is_current,held.operation) and service_authorized()
				and yes(held.running,held.operation) and service==held
				and active==entry and not entry.cancelled
		end
		local function publish()
			if not current() or not service_live() then fail('runtime_source_changed'); return end
			if not budget_owner:retire() then entry.stage='retire_budget'; return end
			if not current() or not service_live() then fail('runtime_source_changed'); return end
			entry.stage='writing'
			local acknowledged, accepting=false, false
			local function accept(proof)
				if acknowledged or accepting or entry.cancelled or active~=entry or not budget.current() then return false end
				accepting=true
				local source=call(P.app_capture, proof, snapshot, descriptor, entry.origin)
				if source==nil or source==false or active~=entry or entry.cancelled
					or not budget.current() or not yes(runtime_current) then return false end
				local pending={source=source, runtime=descriptor, runtime_current=runtime_current,
					origin=entry.origin, service=service, stopping=false}
				candidate_app=pending
				if not service_live() then candidate_app=nil; return false end
				acknowledged=true
				return true
			end
			local written=call(P.publish, snapshot, accept)
			if written~=true or not acknowledged or active~=entry or entry.cancelled
				or not budget.current() or not service_live() then
				candidate_app=nil
				local restored=call(P.compensate,snapshot)==true
				fail(restored and 'runtime_writer_unacknowledged_restored' or 'runtime_writer_unacknowledged_partial')
				return
			end
			app=candidate_app
			entry.promoted=true
			budget_owner:finish()
			request.result={ok=true, installed=entry.installed==true, origin=entry.origin,
				model_installed=false}
			entry.stage='done'; complete(); announce_result()
		end
		local function start_probe()
			if not current() or not service_live() then fail('runtime_source_changed'); return end
			entry.stage='probe'
			entry.probe=nil
			entry.probe=acquire('probe', function(done)
				return P.probe(entry.origin .. Receipt.VERSION_PATH, budget, current, done)
			end)
			if entry.probe.unknown then fail('runtime_http_acquisition_unknown') end
		end
		local function begin_service()
			if not current() or not yes(runtime_current) or not current() then fail('runtime_source_changed'); return end
			entry.stage='service'
			service=acquire('service', function(done)
				return P.start_service(executable, {'serve'}, {origin=entry.origin,
					host=entry.host, timeout_ms=false, authorized=service_authorized,
					owner='ollama-runtime-' .. tostring(sequence)}, done)
			end)
			if not service_live() then fail('runtime_service_unavailable'); return end
			request.started=true; start_probe()
		end
		local function resolved()
			if not current() then fail('runtime_source_changed'); return end
			local answer=call(P.resolve, snapshot)
			if not current() then fail('runtime_source_changed'); return end
			if type(answer)~='table' or answer.status~='installed' or type(answer.runtime)~='table' then
				fail('runtime_installed_descriptor_unavailable'); return
			end
			descriptor=answer.runtime; runtime_current=descriptor.current
			local get=descriptor.executable
			if type(runtime_current)~='function' or type(get)~='function' or not yes(runtime_current) then
				fail('runtime_installed_descriptor_unavailable'); return
			end
			executable=call(get)
			if type(executable)~='string' or executable:sub(1,1)~='/' or executable:find('\0',1,true)
				or not yes(runtime_current) or not current() then fail('runtime_source_changed'); return end
			begin_service()
		end
		pump=function()
			if pumping then again=true; return end
			pumping=true
			repeat
				again=false
				if entry.stage=='cleanup' then clean()
				elseif entry.stage=='writing' or entry.stage=='done' or entry.stage=='admission' then
					-- External acquisition/write frames own these boundaries.
				elseif not current() then fail('runtime_source_changed')
				elseif entry.stage=='install' then
					local held=entry.install
					if held and op_settled(held) then
						if held.delivered and type(held.result)=='table' and held.result.ok==true then
							entry.installed=true; resolved()
						else fail('runtime_install_failed') end
					end
				elseif entry.stage=='probe' then
					local held=entry.probe
					if held and op_settled(held) then
						if not service_live() then fail('runtime_service_unavailable')
						elseif held.delivered and Receipt.receipt(held.result) and current() then publish()
						else
							local remaining=budget.remaining_ms()
							if not remaining or remaining<=0 then fail('runtime_timeout')
							else
								entry.stage='retry'
								entry.retry_expected=remaining - math.min(poll_ms, remaining)
								entry.retry=nil
								entry.retry=acquire('retry', function(done)
									return P.after(math.min(poll_ms, remaining), function() done(true) end)
								end)
								if entry.retry.unknown then fail('runtime_timer_acquisition_unknown') end
							end
						end
					end
				elseif entry.stage=='retry' then
					if op_settled(entry.retry) then
						local left=budget.remaining_ms()
						if entry.retry.delivered and left and left<=entry.retry_expected then start_probe()
						else fail('runtime_retry_refused') end
					end
				elseif entry.stage=='retire_budget' then
					if budget_owner:retire() then publish() end
				end
			until not again
			pumping=false
		end
		local origin, host=M.loopback_origin(type(snapshot)=='table' and snapshot.origin)
		entry.origin, entry.host=origin,host
		if explicit_consent~=true or (action~='download' and action~='start') or not origin then
			fail('runtime_explicit_choice_invalid'); return request
		end
		if not current() then fail('runtime_source_changed'); return request end
		local ok, owner, capability=pcall(Budget.new, bootstrap_ms,
			{now_ms=P.now_ms, after=P.after})
		if not ok then entry.acquisition_unknown=true; fail('runtime_budget_acquisition_unknown'); return request end
		budget_owner,budget=owner,capability
		budget.on_cancel(function(reason) fail(reason) end)
		budget_owner:on_settled(function() if pump then pump() end end)
		if not current() then fail('runtime_source_changed'); return request end
		local answer=call(P.resolve, snapshot)
		if not current() then fail('runtime_source_changed'); return request end
		if type(answer)=='table' and answer.status=='installed' then resolved()
		elseif action=='download' and type(answer)=='table' and answer.status=='missing' then
			entry.stage='install'
			entry.install=acquire('install', function(done)
				return P.install(snapshot, budget, current, done)
			end)
			if entry.install.unknown then fail('runtime_installer_acquisition_unknown') end
		else fail('runtime_binary_unavailable') end
		pump()
		return request
	end
	return controller
end
return M
