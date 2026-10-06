--- infra/managed_http.lua

--- ==============================================================================
--- MODULE: Linux Managed HTTP Operation Coordinator
--- DESCRIPTION:
--- Retains one exact public owner across native proxy lookup, existing owned
--- curl dispatch and admitted ordered relay. Native children keep their own
--- physical-exit and handle-close ledgers; this coordinator never rewrites them.
--- Cancellation fences publication immediately while physical debt remains.
--- ==============================================================================

local M = {}
local ExactIdentity = require("infra.curl_identity")

--- Constructs one initialized native coordinator against explicit owners.
--- @param dependencies table { policy, proxy, curl, clock, deadline, environment, report }
--- @return table|nil coordinator, string|nil error
function M.new(dependencies)
	if type(dependencies) ~= "table" or type(dependencies.policy) ~= "table"
		or type(dependencies.policy.route) ~= "function" or type(dependencies.policy.selection) ~= "function"
		or type(dependencies.policy.can_retry) ~= "function" or type(dependencies.proxy) ~= "table"
		or type(dependencies.proxy.lookup_owned) ~= "function" or type(dependencies.curl) ~= "function"
		or type(dependencies.clock) ~= "function" or type(dependencies.environment) ~= "function"
		or type(dependencies.deadline) ~= "function"
		or type(dependencies.report) ~= "function" then return nil, "managed-http-initialization-invalid" end
	local owned = {}
	local coordinator = {}
	local start_curl
	local settle_stage
	local dispatch_route
	local expire
	local request_cancel

	--- Rechecks only the captured source under its original public reservation.
	--- Caller reentry cannot authorize a retired/replaced/cancelled operation.
	local function source_current(record)
		if record.operation._cancelled or record.operation._settled or owned[record.owner] ~= record then return false end
		if not record.authorized then return true end
		if record.authorization_revoked or record.authorizing or record.operation._cancelled
			or record.operation._settled or owned[record.owner] ~= record then return false end
		record.authorizing = true
		local called, accepted = pcall(record.authorized)
		record.authorizing = false
		local current = called and accepted == true and not record.operation._cancelled
			and not record.operation._settled and owned[record.owner] == record
		if not current then record.authorization_revoked = true end
		return current
	end

	--- Revokes delivery while retaining the exact child and deadline close debt.
	local function source_admitted(record)
		if source_current(record) then return true end
		request_cancel(record)
		return false
	end

	--- Observes an exact child's physical settlement through its native API.
	--- @param record table
	--- @return boolean
	local function child_settled(record)
		if not record.child then return true end
		local ok, settled
		if record.stage == "proxy" then ok, settled = pcall(record.child.is_settled)
		else ok, settled = pcall(record.child.is_settled, record.child) end
		return ok and settled == true
	end

	--- Builds a safe refusal without copying private native diagnostics.
	--- @param error_code string
	--- @return table
	local function refusal(error_code)
		return { ok = false, status = 0, body = "", error = error_code }
	end

	--- Computes remaining time from the one original monotonic deadline.
	--- @param record table
	--- @return number
	local function remaining(record)
		return math.floor(record.deadline - dependencies.clock())
	end

	--- Publishes a boolean terminal without acknowledging native retirement.
	--- @param record table
	--- @param result table
	local function publish_logical(record, result)
		if record.options.owned_api or record.logical_done or record.operation._cancelled then return end
		record.logical_done, record.visible_active = true, false
		result.proxy_selection_receipt = record.selection_metadata
		if type(record.done) == "function" then
			local ok = pcall(record.done, result)
			if not ok then dependencies.report("Managed HTTP logical completion callback raised.") end
		end
	end

	--- Publishes only after the child and the operation deadline timer retire.
	--- @param record table
	--- @param result table
	local function finish(record, result)
		if record.operation._settled or record.uncertain then return end
		if record.admitted and not record.operation._cancelled and remaining(record) <= 0 then
			record.expired, record.visible_active = true, false
			result = refusal("timeout")
		end
		record.pending_result = result
		if record.constructing or record.deadline_constructing or record.admitting or record.authorizing or not child_settled(record) then return end
		if record.deadline_child then
			if record.finalizing then return end
			record.finalizing = true
			local ok, settled = pcall(record.deadline_child.is_settled, record.deadline_child)
			if not ok or settled ~= true then
				local called, accepted = pcall(record.deadline_child.cancel, record.deadline_child)
				record.deadline_close_accepted = called and accepted == true
				if not called or accepted ~= true then
					dependencies.report("Managed HTTP deadline cleanup refused; ownership retained.")
				end
				ok, settled = pcall(record.deadline_child.is_settled, record.deadline_child)
			end
			record.finalizing = false
			if not ok or settled ~= true then return end
		end
		-- A delayed timer close ACK cannot admit success past the original budget.
		if record.admitted and not record.operation._cancelled and remaining(record) <= 0 then
			record.expired, record.visible_active = true, false
			record.pending_result = refusal("timeout")
		end
		if record.authorized and not record.operation._cancelled then
			record.admitting = true
			if not source_current(record) then record.operation._cancelled = true end
			if record.admitted and not record.operation._cancelled and remaining(record) <= 0 then
				record.expired, record.visible_active = true, false
				record.pending_result = refusal("timeout")
			end
			record.admitting = false
		end
		result = record.pending_result
		if record.predecessor and record.predecessor.successor == record then
			record.predecessor.successor = nil
		end
		record.predecessor = nil
		record.operation._settled, record.visible_active = true, false
		if owned[record.owner] == record then owned[record.owner] = nil end
		local successor = record.successor
		record.successor = nil
		if successor and not successor.operation._settled then
			successor.predecessor = nil
			owned[record.owner] = successor
			if successor.operation._cancelled or successor.expired or successor.deadline_failed then
				finish(successor, successor.pending_result or refusal("cancelled"))
			elseif not successor.admitting and not successor.uncertain then
				dispatch_route(successor, successor.route)
			end
		end
		if not record.operation._cancelled and not record.logical_done and type(record.done) == "function" then
			local ok = pcall(record.done, result)
			if not ok then dependencies.report("Managed HTTP completion callback raised.") end
		end
		local listeners = record.operation._listeners
		record.operation._listeners = {}
		for _, listener in ipairs(listeners) do
			local ok = pcall(listener)
			if not ok then dependencies.report("Managed HTTP settlement callback raised.") end
		end
	end

	--- Asks the exact native child to retire without altering public intent.
	--- @param record table
	--- @return boolean
	local function stop_child(record)
		if not record.child then return true end
		local ok, accepted
		if record.stage == "proxy" then ok, accepted = pcall(record.child.cancel)
		else ok, accepted = pcall(record.child.request_cancel, record.child) end
		return ok and accepted == true
	end

	--- Expires one accepted operation while retaining every physical debt.
	--- @param record table
	expire = function(record)
		if record.operation._settled or record.expired or record.operation._cancelled then return end
		record.expired, record.visible_active = true, false
		local result = refusal("timeout")
		record.pending_result = result
		-- Expired queued timers remain linked until their exact close ACK, so
		-- public cancellation can retry this debt after the predecessor exits.
		publish_logical(record, result)
		if not record.constructing then stop_child(record) end
		finish(record, result)
	end

	--- Arms the original deadline and retains its exact native close observer.
	--- @param record table
	--- @return boolean
	local function arm_deadline(record)
		record.deadline_constructing = true
		local called, token = pcall(dependencies.deadline, record.deadline, function() expire(record) end)
		record.deadline_constructing = false
		if not called or type(token) ~= "table" or type(token.is_settled) ~= "function"
			or type(token.cancel) ~= "function" or type(token.on_settled) ~= "function" then
			record.uncertain = true
			dependencies.report("Managed HTTP deadline producer retained uncertain native ownership.")
			return false
		end
		record.deadline_child = token
		local observing, accepted = pcall(token.on_settled, token, function()
			if record.operation._settled or record.finalizing then return end
			if record.pending_result then finish(record, record.pending_result) end
		end)
		if not observing or accepted ~= true then
			record.uncertain = true
			dependencies.report("Managed HTTP deadline refused its retirement observer; ownership retained.")
			pcall(token.cancel, token)
			return false
		end
		if record.expired then finish(record, refusal("timeout")); return false end
		if token.started ~= true then
			record.visible_active, record.deadline_failed, record.operation.started = false, true, false
			local result = refusal("managed-http-deadline-unavailable")
			publish_logical(record, result)
			finish(record, result)
			return false
		end
		return true
	end

	--- Suppresses delivery immediately and asks only the current child to retire.
	--- @param record table
	--- @return boolean Native signal/cleanup acceptance, not settlement.
	request_cancel = function(record)
		local previously_cancelled = record.operation._cancelled
		record.operation._cancelled = true
		if record.operation._settled then return true end
		if record.uncertain then return false end
		if record.constructing then return true end
		if not record.child then
			record.visible_active = false
			finish(record, refusal("cancelled"))
			return record.operation._settled or record.deadline_close_accepted ~= false
		end
		local accepted = stop_child(record)
		if not accepted and not record.options.owned_api and not previously_cancelled then
			record.operation._cancelled = false
		end
		if accepted then record.visible_active = false end
		if child_settled(record) then finish(record, refusal("cancelled")) end
		return accepted
	end

	--- Attaches native retirement without treating logical completion as an ACK.
	--- @param record table
	--- @param generation number
	local function observe(record, generation)
		local function retired()
			if owned[record.owner] ~= record or record.generation ~= generation or record.constructing then return end
			settle_stage(record)
		end
		local ok, accepted
		if record.stage == "proxy" then ok, accepted = pcall(record.child.on_settled, retired)
		else ok, accepted = pcall(record.child.on_settled, record.child, retired) end
		if not ok or accepted ~= true then
			-- An uncertain producer cannot release its acquired child or start a
			-- replacement. Native owner/cancel/retry remain available to callers.
			dependencies.report("Managed HTTP child refused its retirement observer; ownership retained.")
			return
		end
		if record.operation._cancelled then request_cancel(record)
		elseif record.expired then stop_child(record) end
		retired()
	end

	--- Publishes the historical boolean-port terminal event without retiring debt.
	--- @param record table
	--- @param result table
	local function logical_complete(record, result)
		if record.options.owned_api or record.logical_done or record.operation._cancelled then return end
		if type(result) ~= "table" then return end
		if record.expired or remaining(record) <= 0 then expire(record); return end
		local choice = record.choices[record.choice]
		local file_relay_candidate = not record.options.output_path or type(record.options.proxy_retry_admit) == "function"
		local may_relay = file_relay_candidate and record.choice < #record.choices and result.ok == false
			and dependencies.policy.can_retry(result.failure_receipt, {
				selection_mode = choice.mode, delivered_bytes = record.delivered_bytes,
				proxy_used = result.proxy_used == true,
			}) == true
		if may_relay then return end
		publish_logical(record, result)
	end

	--- Starts an admitted curl choice only after its exact predecessor retires.
	--- @param record table
	start_curl = function(record)
		if owned[record.owner] ~= record or record.operation._cancelled then finish(record, refusal("cancelled")); return end
		if not source_admitted(record) then return end
		local budget = remaining(record)
		if record.expired or budget <= 0 then expire(record); return end
		if owned[record.owner] ~= record or record.operation._cancelled or record.operation._settled then return end
		local choice = record.choices[record.choice]
		if not choice then finish(record, refusal("proxy-selection-invalid")); return end
		record.stage, record.child, record.result, record.done_received = "curl", nil, nil, false
		record.generation = record.generation + 1
		local generation = record.generation
		local options = {}
		for key, value in pairs(record.options) do options[key] = value end
		options.owner, options.timeout_ms, options.proxy_selection = record.owner, budget, choice
		local capabilities = record.curl_capabilities
		local executable = type(capabilities) == "table" and capabilities.executable or nil
		options.curl_executable, options.curl_executable_identity, options.curl_executable_identity_exact = nil, nil, nil
		if type(executable) == "string" and capabilities.executable_observation == "owned-child"
			and type(capabilities.executable_identity) == "table" and capabilities.executable_identity_exact == nil then
			options.curl_executable = executable
			if type(capabilities.executable_identity) == "table" then
				options.curl_executable_identity = {}
				for key, value in pairs(capabilities.executable_identity) do options.curl_executable_identity[key] = value end
			end
		end
		if type(executable) == "string" and capabilities.executable_observation == "owned-child"
			and capabilities.executable_identity == nil then
			local exact = ExactIdentity.copy(capabilities.executable_identity_exact)
			if exact then options.curl_executable, options.curl_executable_identity_exact = executable, exact end
		end
		options.proxy_metrics_available = options.curl_executable ~= nil and capabilities.proxy_used == true
		options.authorized = nil
		if record.authorized then
			options.authorized = function()
				if owned[record.owner] ~= record or record.generation ~= generation or record.operation._cancelled
					or record.operation._settled or record.expired then return false end
				if not source_admitted(record) then return false end
				if remaining(record) <= 0 then expire(record); return false end
				return owned[record.owner] == record and record.generation == generation
					and not record.operation._cancelled and not record.operation._settled and not record.expired
			end
		end
		options.on_native_terminal = function(result)
			if owned[record.owner] ~= record or record.generation ~= generation then return end
			logical_complete(record, result)
		end
		local function complete(result)
			if owned[record.owner] ~= record or record.generation ~= generation or record.operation._cancelled then return end
			if not source_admitted(record) then return end
			record.result, record.done_received = result, true
		end
		local function chunk(bytes)
			if owned[record.owner] ~= record or record.generation ~= generation or record.operation._cancelled or record.logical_done then return end
			if not source_admitted(record) then return end
			if record.expired or remaining(record) <= 0 then expire(record); return end
			if owned[record.owner] ~= record or record.generation ~= generation
				or record.operation._cancelled or record.operation._settled then return end
			if type(bytes) ~= "string" then request_cancel(record); return end
			record.delivered_bytes = record.delivered_bytes + #bytes
			if type(record.chunk) == "function" then
				local ok = pcall(record.chunk, bytes)
				if not ok then dependencies.report("Managed HTTP chunk callback raised.") end
			end
		end
		record.constructing = true
		local called, child = pcall(dependencies.curl, record.url, record.headers, record.body, options, chunk, complete)
		record.constructing = false
		if not called or type(child) ~= "table" or type(child.is_settled) ~= "function"
			or type(child.on_settled) ~= "function" or type(child.request_cancel) ~= "function" then
			-- A throwing/malformed native producer might have acquired resources.
			-- Preserve this record; never turn uncertainty into a safe successor.
			record.uncertain = true
			dependencies.report("Managed HTTP curl producer retained uncertain native ownership.")
			return
		end
		record.child = child
		record.operation.started = record.operation.started or child.started == true
		observe(record, generation)
	end

	--- Advances one stage only after observing its actual native retirement.
	--- @param record table
	settle_stage = function(record)
		if not child_settled(record) then return end
		if record.operation._cancelled then finish(record, refusal("cancelled")); return end
		if not source_admitted(record) then return end
		if record.expired or remaining(record) <= 0 then
			expire(record)
			finish(record, refusal("timeout"))
			return
		end
		if not record.done_received then
			finish(record, refusal("managed-http-completion-missing"))
			return
		end
		if record.stage == "proxy" then
			local choices, err = dependencies.policy.selection(record.result)
			if not choices then
				local result = refusal(err)
				result.failure_receipt = { stage = "proxy_resolve", backend = "gio", failure_provenance = "unknown" }
				finish(record, result)
				return
			end
			record.choices, record.choice = choices, 1
			record.curl_capabilities = type(record.result) == "table" and record.result.curl_capabilities or nil
			record.selection_metadata = {
				backend = "gio", failure_provenance = "unavailable",
				proxy_resolution_status = type(record.result) == "table" and record.result.ok == true and "selected" or "unavailable",
				native_backend = type(record.result) == "table" and record.result.backend or nil,
			}
			if #choices == 1 and choices[1].mode == "direct" then record.selection_metadata.proxy_resolution_status = "direct" end
			start_curl(record)
			return
		end
		local result = record.result
		if type(result) ~= "table" then finish(record, refusal("managed-http-completion-invalid")); return end
		local choice = record.choices[record.choice]
		local safe_file = not record.options.output_path
		if not safe_file and type(record.options.proxy_retry_admit) == "function" then
			local admitted, acknowledged = pcall(record.options.proxy_retry_admit)
			safe_file = admitted and acknowledged == true
		end
		local can_retry = not record.logical_done and safe_file and record.choice < #record.choices and result.ok == false
			and dependencies.policy.can_retry(result.failure_receipt, {
				selection_mode = choice.mode, delivered_bytes = record.delivered_bytes,
				proxy_used = result.proxy_used == true,
			}) == true
		if can_retry then record.choice = record.choice + 1; start_curl(record); return end
		result.proxy_selection_receipt = record.selection_metadata
		finish(record, result)
	end

	--- Begins one preflighted route after exclusive public ownership admission.
	--- @param record table
	--- @param route table
	dispatch_route = function(record, route)
		local operation = record.operation
		if owned[record.owner] ~= record or operation._settled or record.uncertain then return operation end
		if operation._cancelled then finish(record, refusal("cancelled")); return operation end
		if not source_admitted(record) then return operation end
		if record.expired or record.deadline_failed then
			finish(record, record.pending_result or refusal("timeout")); return operation
		end
		if route.mode ~= "system" then
			record.choices, record.choice = { route }, 1
			start_curl(record)
			return operation
		end
		record.stage, record.constructing = "proxy", true
		record.generation = record.generation + 1
		local generation = record.generation
		local budget = remaining(record)
		if record.expired or budget <= 0 then record.constructing = false; expire(record); return operation end
		if owned[record.owner] ~= record or operation._cancelled or operation._settled then
			record.constructing = false
			finish(record, refusal("cancelled")); return operation
		end
		local called, child, lookup_error = pcall(dependencies.proxy.lookup_owned, record.url, {
			owner = record.owner, timeout_ms = budget, probe_curl = true,
			logical_cancel = record.options.owned_api == false,
			on_native_terminal = function(result)
				if owned[record.owner] ~= record or record.generation ~= generation then return end
				if type(result) == "table" and result.error == "proxy-lookup-timeout" then expire(record) end
			end,
			environment_exclusions = route.environment_exclusions,
		}, function(result)
			if owned[record.owner] ~= record or record.generation ~= generation or operation._cancelled then return end
			record.result, record.done_received = result, true
		end)
		record.constructing = false
		if not called then
			record.uncertain = true
			dependencies.report("Managed HTTP proxy producer retained uncertain native ownership.")
			return operation
		end
		if not child then
			record.result, record.done_received = { ok = false, error = lookup_error }, true
			settle_stage(record)
			return operation
		end
		if type(child) ~= "table" or type(child.is_settled) ~= "function" or type(child.on_settled) ~= "function"
			or type(child.cancel) ~= "function" then
			record.uncertain = true
			dependencies.report("Managed HTTP proxy producer retained uncertain native ownership.")
			return operation
		end
		record.child, operation.started = child, true
		observe(record, generation)
		return operation
	end

	--- Starts a managed request while preserving existing public owner semantics.
	--- @param url string
	--- @param headers table
	--- @param body string|nil
	--- @param options table Validated native HTTP options, including owner/deadline.
	--- @param on_chunk function|nil
	--- @param on_done function
	--- @return table operation
	function coordinator.start(url, headers, body, options, on_chunk, on_done, admission)
		local operation = { started = false, _settled = false, _cancelled = false, _listeners = {} }
		local record = {
			url = url, headers = headers, body = body, options = options, owner = options.owner,
			chunk = on_chunk, done = on_done, operation = operation, generation = 0, delivered_bytes = 0, visible_active = false,
			deadline = admission and 0 or dependencies.clock() + options.timeout_ms,
		}
		function operation:is_settled() return self._settled end
		function operation:on_settled(listener)
			if type(listener) ~= "function" then return false end
			if self._settled then
				local ok = pcall(listener)
				if not ok then dependencies.report("Managed HTTP settlement callback raised.") end
			else self._listeners[#self._listeners + 1] = listener end
			return true
		end
		function operation:cancel() request_cancel(record); return self._settled end
		function operation:request_cancel() return request_cancel(record) end
		if admission then
			-- Reserve before caller source/preflight metadata. Unlike boolean
			-- successors, this owner never cancels or probes a predecessor source.
			if owned[record.owner] then
				if admission.authorized then operation._settled = true
				else finish(record, refusal("previous request cleanup pending")) end
				return operation
			end
			owned[record.owner] = record
			record.admitting, record.authorized = true, admission.authorized
			local clocked, started = pcall(dependencies.clock)
			if not clocked or type(started) ~= "number" or started ~= started or math.abs(started) == math.huge then
				record.admitting = false
				finish(record, refusal("managed-http-clock-unavailable")); return operation
			end
			record.deadline = started + options.timeout_ms
			if not source_admitted(record) then
				record.admitting = false
				finish(record, refusal("cancelled")); return operation
			end
			local prepared, native_options, preparation_error = pcall(admission.prepare)
			if not source_admitted(record) then
				record.admitting = false
				finish(record, refusal("cancelled")); return operation
			end
			if not prepared or type(native_options) ~= "table" then
				record.admitting = false
				finish(record, refusal(prepared and preparation_error or "owned request admission failed")); return operation
			end
			record.options = native_options
		end
		local fetched, environment = pcall(dependencies.environment)
		local route, err
		if fetched then route, err = dependencies.policy.route(url, environment) end
		if admission then
			if not source_admitted(record) then
				record.admitting = false
				finish(record, refusal("cancelled")); return operation
			end
			record.admitting = false
			if record.operation._cancelled then finish(record, refusal("cancelled")); return operation end
			if remaining(record) <= 0 then expire(record); return operation end
			if owned[record.owner] ~= record or operation._cancelled or operation._settled then
				finish(record, refusal("cancelled")); return operation
			end
			if not route then finish(record, refusal(err or "proxy-environment-unavailable")); return operation end
			record.route, record.admitted, record.visible_active = route, true, true
			if not arm_deadline(record) then return operation end
			dispatch_route(record, route)
			return operation
		end
		if not route then finish(record, refusal(err or "proxy-environment-unavailable")); return operation end
		record.route = route
		local predecessor = owned[record.owner]
		if predecessor then
			if options.owned_api or predecessor.options.owned_api then finish(record, refusal("previous request cleanup pending")); return operation end
			if predecessor.successor then
				request_cancel(predecessor.successor)
				if predecessor.successor and not predecessor.successor.operation._settled then
					finish(record, refusal("previous request cleanup pending")); return operation
				end
			end
			record.admitting = true
			predecessor.successor, record.predecessor = record, predecessor
			operation.started, record.admitted, record.visible_active = true, true, true
			if not request_cancel(predecessor) then
				if predecessor.successor == record then predecessor.successor = nil end
				record.predecessor, operation.started, record.admitted, record.admitting = nil, false, false, false
				finish(record, refusal("previous request cancellation failed"))
				return operation
			end
			record.admitting = false
			-- A synchronous predecessor listener can cancel this adopted record.
			-- Admission must be rechecked before allocating its deadline or child.
			if record.operation._settled or record.operation._cancelled then
				finish(record, refusal("cancelled")); return operation
			end
			if not arm_deadline(record) then return operation end
			if not record.predecessor then dispatch_route(record, route) end
			return operation
		end
		owned[record.owner] = record
		record.admitted, record.visible_active = true, true
		if not arm_deadline(record) then return operation end
		dispatch_route(record, route)
		return operation
	end


	--- Preserves logical cancellation for the public boolean HTTP adapter port.
	--- @param owner string
	--- @return boolean
	function coordinator.cancel(owner)
		local record = owned[owner]
		if not record then return true end
		local successor_accepted = true
		if record.successor then successor_accepted = request_cancel(record.successor) end
		local accepted = request_cancel(record)
		return accepted and successor_accepted
	end

	--- Reports activity across native lookup, curl and retained retirement debt.
	--- @param owner string
	--- @return boolean
	function coordinator.is_active(owner)
		local record = owned[owner]
		if record and record.successor then record = record.successor end
		return record ~= nil and record.visible_active == true and not record.logical_done
	end

	return coordinator
end

return M
