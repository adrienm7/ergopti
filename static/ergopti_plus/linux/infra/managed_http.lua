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
	if dependencies.redirect ~= nil and type(dependencies.redirect) ~= "function" then return nil, "managed-http-initialization-invalid" end
	if dependencies.prepare_headers ~= nil and type(dependencies.prepare_headers) ~= "function" then return nil, "managed-http-initialization-invalid" end
	local next_output = type(dependencies.output) == "table" and rawget(dependencies.output, "next") or nil
	local complete_output = type(dependencies.output) == "table" and rawget(dependencies.output, "complete") or nil
	if dependencies.output ~= nil and type(next_output) ~= "function" then return nil, "managed-http-initialization-invalid" end
	local owned = {}
	local coordinator = {}
	local start_curl
	local settle_stage
	local dispatch_route
	local expire
	local request_cancel

	--- Includes a tentative queued reservation without replacing its native owner.
	local function reservation_current(record)
		local incumbent = owned[record.owner]
		return incumbent == record or (incumbent ~= nil and record.predecessor == incumbent
			and incumbent.successor == record and not incumbent.options.owned_api)
	end

	--- Rechecks only the captured source under its original public reservation.
	--- Caller reentry cannot authorize a retired/replaced/cancelled operation.
	local function source_current(record)
		if record.operation._cancelled or record.operation._settled or not reservation_current(record) then return false end
		if not record.authorized then return true end
		if record.authorization_revoked or record.authorizing or record.operation._cancelled
			or record.operation._settled or not reservation_current(record) then return false end
		record.authorizing = true
		local called, accepted = pcall(record.authorized)
		record.authorizing = false
		local current = called and accepted == true and not record.operation._cancelled
			and not record.operation._settled and reservation_current(record)
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
		return record.deadline - dependencies.clock()
	end

	--- Removes only private hop metadata; ordinary result identity is unchanged.
	local function public_result(result)
		if type(result) ~= "table" or result.redirect_receipt == nil then return result end
		local copy = {}
		for key, value in pairs(result) do if key ~= "redirect_receipt" then copy[key] = value end end
		return copy
	end

	--- Detaches public value data while retaining actual private failure evidence.
	--- Raw iteration cannot invoke receipt/header getters during ownership capture.
	local function snapshot_result(result)
		if type(result) ~= "table" then return nil end
		local copy = {}
		for key, value in next, result do
			if key ~= "redirect_receipt" then
				if key == "headers" and type(value) == "table" then
					local headers = {}
					for name, field in next, value do
						if type(name) == "string" and type(field) == "string" then headers[name] = field end
					end
					copy.headers = headers
				else copy[key] = value end
			end
		end
		return copy
	end

	--- Publishes a boolean terminal without acknowledging native retirement.
	--- @param record table
	--- @param result table
	local function publish_logical(record, result)
		if record.options.owned_api or record.logical_done or record.operation._cancelled then return end
		record.logical_done, record.visible_active = true, false
		result = public_result(result)
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
		if record.admitted and not record.prestart_refused and not record.operation._cancelled and remaining(record) <= 0 then
			record.expired, record.visible_active = true, false
			result = refusal("timeout")
		end
		local retained
		if rawequal(result, record.pending_receipt_source) and record.pending_settled_result then
			retained = snapshot_result(record.pending_settled_result)
		elseif rawequal(result, record.native_terminal_result) then
			retained = snapshot_result(record.native_terminal_snapshot)
		else retained = snapshot_result(result) end
		record.pending_result, record.pending_settled_result = public_result(result), retained
		record.pending_receipt_source = record.pending_result
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
		-- Accepted owned replacements retain the old physical debt too; invalid
		-- preflight refusals were never admitted and leave the incumbent valid.
		if record.predecessor and record.admitted and record.options.owned_api
			and not record.predecessor.operation._settled then return end
		-- A delayed timer close ACK cannot admit success past the original budget.
		if record.admitted and not record.prestart_refused and not record.operation._cancelled and remaining(record) <= 0 then
			record.expired, record.visible_active = true, false
			record.pending_result = refusal("timeout")
			record.pending_settled_result = snapshot_result(record.pending_result)
		end
		if record.authorized and not record.operation._cancelled then
			record.admitting = true
			if not source_current(record) then record.operation._cancelled = true end
			if record.admitted and not record.prestart_refused and not record.operation._cancelled and remaining(record) <= 0 then
				record.expired, record.visible_active = true, false
				record.pending_result = refusal("timeout")
			record.pending_settled_result = snapshot_result(record.pending_result)
			end
			record.admitting = false
		end
		result = record.pending_result
		-- This lexical receipt becomes available only at genuine final retirement.
		-- A writable public _settled field cannot manufacture receipt authority.
		record.settled_receipt = snapshot_result(record.operation._cancelled
			and refusal("cancelled") or record.pending_settled_result)
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
			if successor.operation._cancelled or successor.expired or successor.deadline_failed
				or successor.replacement_refused then
				finish(successor, successor.pending_result or refusal("cancelled"))
			elseif not successor.admitting and not successor.uncertain then
				dispatch_route(successor, successor.route)
			end
		end
		if not record.operation._cancelled and not record.logical_done and type(record.done) == "function" then
			local ok
			if record.options.output_target ~= nil then
				ok = pcall(record.done, result, result.ok == true and record.output_completion or nil)
			else ok = pcall(record.done, result) end
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
		local ok, accepted, native_refusal
		if record.stage == "proxy" then ok, accepted = pcall(record.child.cancel)
		else ok, accepted, native_refusal = pcall(record.child.request_cancel, record.child) end
		return ok and accepted == true, ok and native_refusal or nil
	end

	--- Admits only the unchanged private positive cancellation lineage.
	--- A native cancellation ACK permits a queued reservation, never a new child.
	local function cancelled_boolean_current(record, receipt)
		return type(receipt) == "table" and record.cancelled_boolean_receipt == receipt
			and owned[record.owner] == record and record.operation == receipt.operation
			and record.child == receipt.child and record.generation == receipt.generation
			and record.options == receipt.options and record.options.owned_api == false
			and record.cancellation_attempt == receipt.attempt and record.deadline == receipt.deadline
			and record.stage == "curl" and rawget(receipt.child, "started") == true
			and record.admitted == true and record.operation.started == true
			and record.operation._cancelled == true and not record.operation._settled
			and record.visible_active == false and not record.logical_done
			and not record.expired and not record.prestart_refused and not record.uncertain
			and not record.authorization_revoked and record.authorized == nil
			and rawget(record.options, "authorized") == nil
	end

	--- Refences the old original budget after protected clock reentry.
	--- The initial successor check uses its existing clock observation after reservation.
	local function cancelled_boolean_budget_current(record, receipt, observed)
		if not cancelled_boolean_current(record, receipt) then return false end
		local called = true
		if observed == nil then called, observed = pcall(dependencies.clock) end
		return called and type(observed) == "number" and observed == observed
			and math.abs(observed) ~= math.huge and observed < receipt.deadline
			and cancelled_boolean_current(record, receipt)
	end

	--- Expires one accepted operation while retaining every physical debt.
	--- @param record table
	expire = function(record)
		if record.operation._settled or record.expired or record.operation._cancelled or record.prestart_refused then return end
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
		-- An opaque attempt fences newer reentrant cancellation receipts without
		-- guessing native generations or using a numeric sequence as authority.
		local attempt = {}
		record.cancellation_attempt, record.cancelled_boolean_receipt = attempt, nil
		record.operation._cancelled = true
		if record.operation._settled then return true end
		if record.uncertain then return false end
		if record.constructing then return true end
		if not record.child then
			record.visible_active = false
			finish(record, refusal("cancelled"))
			return record.operation._settled or record.deadline_close_accepted ~= false
		end
		-- Capture before the native cancellation call, then recheck its exact
		-- lineage after any synchronous settlement or callback reentry.
		local lineage
		if owned[record.owner] == record
			and record.options.owned_api == false and record.admitted == true
			and record.stage == "curl"
			and type(record.child) == "table" and rawget(record.child, "started") == true
			and record.operation.started == true and not record.logical_done
			and not record.expired and not record.prestart_refused and not record.uncertain
			and not record.authorization_revoked and record.authorized == nil
			and rawget(record.options, "authorized") == nil then
			lineage = { operation = record.operation, child = record.child,
				generation = record.generation, options = record.options, attempt = attempt, deadline = record.deadline }
			local called, observed = pcall(dependencies.clock)
			if not called or type(observed) ~= "number" or observed ~= observed
				or math.abs(observed) == math.huge or observed >= lineage.deadline
				or record.cancellation_attempt ~= attempt or owned[record.owner] ~= record
				or record.child ~= lineage.child or record.generation ~= lineage.generation
				or record.options ~= lineage.options or record.deadline ~= lineage.deadline
				or record.operation._settled then lineage = nil end
		end
		local accepted, native_refusal = stop_child(record)
		local descriptor_refusal = record.stage == "curl" and record.prestart_refused
			and record.child.started == false and native_refusal == "body-descriptor-retirement-pending"
		-- Descriptor retirement can refuse after accepting logical revocation;
		-- a failed process signal keeps the original boolean delivery law.
		if record.cancellation_attempt == attempt and not accepted and not descriptor_refusal
			and not record.options.owned_api and not previously_cancelled then
			record.operation._cancelled = false
		end
		if accepted and record.cancellation_attempt == attempt then record.visible_active = false end
		if accepted and lineage and record.cancellation_attempt == attempt then
			local called, observed = pcall(dependencies.clock)
			if called and type(observed) == "number" and observed == observed
				and math.abs(observed) ~= math.huge and observed < lineage.deadline
				and record.cancellation_attempt == attempt then
				record.cancelled_boolean_receipt = lineage
				if not cancelled_boolean_current(record, lineage) then record.cancelled_boolean_receipt = nil end
			end
		elseif not accepted and record.cancellation_attempt == attempt then record.cancelled_boolean_receipt = nil end
		if record.cancellation_attempt == attempt and child_settled(record)
			and record.cancellation_attempt == attempt then finish(record, refusal("cancelled")) end
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

	--- Purely inspects a private hop receipt, never dispatching before retirement.
	local function redirect_decision(record, result)
		if not record.redirect_policy then return { action = "terminal" } end
		local generation = record.generation
		local called, decision = pcall(record.redirect_policy.transition, {
			current_url = record.url, headers = record.headers, result = result,
			https_floor = record.https_floor, hops = record.hops, visited = record.visited,
		})
		if owned[record.owner] ~= record or record.generation ~= generation
			or record.operation._cancelled or record.operation._settled then return nil end
		local budget = remaining(record)
		-- The clock is a native port and may reenter cancellation or replacement.
		if owned[record.owner] ~= record or record.generation ~= generation
			or record.operation._cancelled or record.operation._settled then return nil end
		if record.expired or budget <= 0 then expire(record); return nil end
		if not called or type(decision) ~= "table" or (decision.action ~= "follow"
			and decision.action ~= "terminal" and decision.action ~= "refuse") then
			return { action = "refuse", error = "HTTP redirect receipt refused" }
		end
		return decision
	end

	--- Preserves only the verified legacy HTTPS refusal's original HTTP result.
	--- Deliberate managed/archive owners retain their strict protocol refusal.
	local function redirect_refusal(record, result, decision)
		if decision.reason == "https_downgrade" and record.options.managed_redirects ~= true
			and record.options.archive_redirects ~= true then return result end
		return refusal(decision.error)
	end

	--- Produces an exact new output capability after actual retired hop receipt.
	--- Every native/lease probe retains the original parent generation/deadline.
	local function output_successor(record, result, disposition)
		local target, producer, generation = record.options.output_target, record.child, record.generation
		if target == nil or type(next_output) ~= "function" then return false end
		local function current()
			if not source_admitted(record) then return false end
			local budget = remaining(record)
			return budget > 0 and not record.expired and owned[record.owner] == record
				and record.generation == generation and rawequal(record.child, producer)
				and rawequal(record.options.output_target, target)
				and not record.operation._cancelled and not record.operation._settled
		end
		if not current() then return false end
		local called, successor = pcall(next_output, target, producer, result, disposition, current)
		if not called or type(successor) ~= "table" or not current() then return false end
		record.options.output_target = successor
		return true
	end

	--- Publishes the historical boolean-port terminal event without retiring debt.
	--- @param record table
	--- @param result table
	local function logical_complete(record, result)
		if record.options.owned_api or record.logical_done or record.operation._cancelled then return end
		if type(result) ~= "table" then return end
		if record.expired or remaining(record) <= 0 then expire(record); return end
		local decision = redirect_decision(record, result)
		if not decision then return end
		if decision.action == "follow" then return end
		if decision.action == "refuse" then publish_logical(record, redirect_refusal(record, result, decision)); return end
		local choice = record.choices[record.choice]
		local file_relay_candidate = record.options.output_target == nil
			and (not record.options.output_path or type(record.options.proxy_retry_admit) == "function")
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
		record.construction_terminal = nil
		record.native_terminal_result, record.native_terminal_snapshot = nil, nil
		record.native_terminal_captured = false
		record.generation = record.generation + 1
		local generation = record.generation
		local options = {}
		for key, value in pairs(record.options) do options[key] = value end
		options.owner, options.timeout_ms, options.proxy_selection = record.owner, budget, choice
		if options.prepared_headers ~= nil then
			if not dependencies.prepare_headers then finish(record, refusal("HTTP prepared headers unavailable")); return end
			local called, token = pcall(dependencies.prepare_headers, options.prepared_headers, record.headers)
			if owned[record.owner] ~= record or record.generation ~= generation or record.operation._cancelled or record.operation._settled then return end
			if not called or type(token) ~= "table" then finish(record, refusal("HTTP prepared headers refused")); return end
			options.prepared_headers = token
			local adjusted = remaining(record)
			if owned[record.owner] ~= record or record.generation ~= generation or record.operation._cancelled or record.operation._settled then return end
			if adjusted <= 0 then expire(record); return end
			options.timeout_ms = adjusted
		end
		options.single_hop_redirect, options.single_hop_receipt_bytes, options.single_hop_url_bytes = nil, nil, nil
		if record.redirect_policy then
			options.single_hop_redirect, options.follow_redirects = true, false
			options.single_hop_receipt_bytes = record.redirect_policy.max_native_receipt_bytes
			options.single_hop_url_bytes = record.redirect_policy.max_url_bytes
		end
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
			-- Capture before the first original logical callback can mutate values.
			if not record.native_terminal_captured then
				record.native_terminal_captured = true
				record.native_terminal_result, record.native_terminal_snapshot = result, snapshot_result(result)
			end
			-- A pre-start refusal can still own pipes, timers or descriptors.
			-- Its original failure publishes through physical completion, while
			-- an admitted native child keeps ordinary early logical terminals.
			if record.constructing then record.construction_terminal = result; return end
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
		local construction_terminal = record.construction_terminal
		record.construction_terminal = nil
		if construction_terminal and child.started == true then logical_complete(record, construction_terminal)
		elseif type(construction_terminal) == "table" and construction_terminal.ok == false then
			-- The actual child refused to start. Its failure already became
			-- terminal before the deadline; cleanup is not a new timeout phase.
			record.prestart_refused, record.pending_result = true, construction_terminal
			local accepted, closed = pcall(record.deadline_child.cancel, record.deadline_child)
			if not accepted or closed ~= true then
				dependencies.report("Managed HTTP deadline cleanup refused; ownership retained.")
			end
		end
		observe(record, generation)
	end

	--- Advances one stage only after observing its actual native retirement.
	--- @param record table
	settle_stage = function(record)
		if not child_settled(record) then return end
		if record.operation._cancelled then finish(record, refusal("cancelled")); return end
		if not source_admitted(record) then return end
		if not record.prestart_refused and (record.expired or remaining(record) <= 0) then
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
		local decision = redirect_decision(record, result)
		if not decision then return end
		if decision.action == "refuse" then finish(record, redirect_refusal(record, result, decision)); return end
		if decision.action == "follow" then
			if type(decision.url) ~= "string" or type(decision.headers) ~= "table" or type(decision.key) ~= "string"
				or type(decision.hops) ~= "number" or decision.hops ~= record.hops + 1 then
				finish(record, refusal("HTTP redirect receipt refused")); return
			end
			if record.options.output_target ~= nil and not output_successor(record, result, "redirect") then
				finish(record, refusal("archive redirect continuation refused")); return
			end
			-- The preceding child's is_settled ACK is observed above. Keep the
			-- same parent/deadline while replacing only the retired hop's state.
			record.url, record.headers, record.hops = decision.url, decision.headers, decision.hops
			record.visited[decision.key] = true
			record.child, record.result, record.done_received = nil, nil, false
			record.curl_capabilities, record.selection_metadata = nil, nil
			record.choices, record.choice = nil, nil
			local generation = record.generation
			local fetched, environment = pcall(dependencies.environment)
			local routed, route, route_error
			if fetched then routed, route, route_error = pcall(dependencies.policy.route, record.url, environment) end
			if owned[record.owner] ~= record or record.generation ~= generation
				or record.operation._cancelled or record.operation._settled then return end
			local budget = remaining(record)
			if owned[record.owner] ~= record or record.generation ~= generation
				or record.operation._cancelled or record.operation._settled then return end
			if record.expired or budget <= 0 then expire(record); return end
			if not routed or not route then finish(record, refusal(route_error or "proxy-environment-unavailable")); return end
			record.route = route
			dispatch_route(record, route)
			return
		end
		local choice = record.choices[record.choice]
		-- Retained FD retry needs an exact previous-attempt ticket, not the old
		-- zero-argument pathname admission callback. Target relay additionally
		-- consumes the captured physical producer and zero-byte receipt below.
		local safe_file = not record.options.output_path and (record.options.output_target == nil or type(next_output) == "function")
		if not safe_file and record.options.output_target == nil and type(record.options.proxy_retry_admit) == "function" then
			local admitted, acknowledged = pcall(record.options.proxy_retry_admit)
			safe_file = admitted and acknowledged == true
		end
		local can_retry = not record.logical_done and safe_file and record.choice < #record.choices and result.ok == false
			and dependencies.policy.can_retry(result.failure_receipt, {
				selection_mode = choice.mode, delivered_bytes = record.delivered_bytes,
				proxy_used = result.proxy_used == true,
			}) == true
		if can_retry then
			if record.options.output_target ~= nil and not output_successor(record, result, "relay") then
				result.proxy_selection_receipt = record.selection_metadata
				finish(record, result); return
			end
			record.choice = record.choice + 1; start_curl(record); return
		end
		if record.options.output_target ~= nil and result.ok == true then
			local completed, token = false, nil
			if type(complete_output) == "function" then
				completed, token = pcall(complete_output, record.options.output_target, record.child, result)
			end
			if not completed or type(token) ~= "table" then
				finish(record, refusal("archive output completion refused")); return
			end
			-- Completing probes the captured lease/native owner. Re-admit the
			-- same parent after that boundary before publishing its token.
			if not source_admitted(record) then return end
			local budget = remaining(record)
			if owned[record.owner] ~= record or record.operation._cancelled or record.operation._settled then return end
			if record.expired or budget <= 0 then expire(record); return end
			record.output_completion = token
		end
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
			owner = record.owner, timeout_ms = math.ceil(budget), probe_curl = true,
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
			deadline = admission and 0 or math.min(dependencies.clock() + options.timeout_ms, rawget(options, "absolute_deadline_ms") or math.huge),
		}
		function operation:is_settled() return self._settled end
		--- Returns detached final public data only after exact physical retirement.
		function operation:settled_result() return snapshot_result(record.settled_receipt) end
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
			local incumbent = owned[record.owner]
			-- A positively cancelled, actually started BOOLEAN curl child may
			-- accept one reservation while retaining every physical retirement debt.
			local cancelled_receipt = incumbent and incumbent.cancelled_boolean_receipt
			local cancelled_incumbent = incumbent and cancelled_boolean_current(incumbent, cancelled_receipt)
			if incumbent and (incumbent.options.owned_api or incumbent.successor
				or incumbent.admitted ~= true or incumbent.uncertain
				or ((incumbent.visible_active ~= true or incumbent.operation._cancelled) and not cancelled_incumbent)
				or incumbent.logical_done or incumbent.expired or incumbent.prestart_refused) then
				if admission.authorized then operation._settled = true
				else finish(record, refusal("previous request cleanup pending")) end
				return operation
			end
			if incumbent then
				incumbent.successor, record.predecessor = record, incumbent
				if cancelled_incumbent then record.cancelled_predecessor_receipt = cancelled_receipt end
			else owned[record.owner] = record end
			record.admitting, record.authorized = true, admission.authorized
			local clocked, started = pcall(dependencies.clock)
			if not clocked or type(started) ~= "number" or started ~= started or math.abs(started) == math.huge then
				record.admitting = false
				finish(record, refusal("managed-http-clock-unavailable")); return operation
			end
			record.deadline = math.min(started + options.timeout_ms, rawget(options, "absolute_deadline_ms") or math.huge)
			if record.predecessor and record.cancelled_predecessor_receipt
				and not cancelled_boolean_budget_current(record.predecessor, record.cancelled_predecessor_receipt, started) then
				-- Match pre-metadata cleanup refusal: source-bound callers receive
				-- no guessed authorization callback on an expired incumbent.
				if admission.authorized then operation._cancelled = true end
				record.admitting = false
				finish(record, refusal("previous request cleanup pending")); return operation
			end
			if not source_admitted(record) then
				record.admitting = false
				finish(record, refusal("cancelled")); return operation
			end
			local prepared, native_options, preparation_error, prepared_headers = pcall(admission.prepare)
			if not source_admitted(record) then
				record.admitting = false
				finish(record, refusal("cancelled")); return operation
			end
			if not prepared or type(native_options) ~= "table" then
				record.admitting = false
				finish(record, refusal(prepared and preparation_error or "owned request admission failed")); return operation
			end
			if prepared_headers ~= nil then
				if type(prepared_headers) ~= "table" then
					record.admitting = false
					finish(record, refusal("HTTP prepared headers unavailable")); return operation
				end
				record.headers, headers = prepared_headers, prepared_headers
			elseif native_options.prepared_headers ~= nil then
				record.admitting = false
				finish(record, refusal("HTTP prepared headers unavailable")); return operation
			end
			record.options = native_options
		end
		-- Prepared owned metadata is the actual per-hop admission input; the
		-- reservation/source/absolute deadline established above remain unchanged.
		local redirect_options = record.options
		local authority = type(url) == "string" and url:match("^[^:]+://([^/?#]*)") or nil
		local archive_hops = redirect_options.output_target ~= nil and redirect_options.buffered == false
			and redirect_options.archive_redirects == true and type(next_output) == "function"
		local buffered_hops = redirect_options.buffered == true and redirect_options.follow_redirects
			and redirect_options.output_target == nil
		local hop_eligible = dependencies.redirect ~= nil and redirect_options.method == "GET" and (buffered_hops or archive_hops)
			and body == nil and redirect_options.output_path == nil
			and redirect_options.etag_compare == nil and redirect_options.etag_save == nil and authority and not authority:find("@", 1, true)
		local function redirect_still_current()
			local generation = record.generation
			if admission and not source_admitted(record) then
				record.admitting = false
				finish(record, refusal("cancelled")); return false
			end
			if record.operation._cancelled or record.operation._settled then
				record.admitting = false
				finish(record, refusal("cancelled")); return false
			end
			local budget = remaining(record)
			-- Boolean starts have not reserved an owner yet; owned admission has.
			if record.operation._cancelled or record.operation._settled or record.generation ~= generation
				or (admission and not reservation_current(record)) then
				record.admitting = false
				finish(record, refusal("cancelled")); return false
			end
			if budget <= 0 then
				record.admitting = false
				expire(record); return false
			end
			return true
		end
		if hop_eligible then
			local loaded, redirect, load_error = pcall(dependencies.redirect)
			if not redirect_still_current() then return operation end
			if not loaded or type(redirect) ~= "table" or type(redirect.transition) ~= "function" or type(redirect.address) ~= "function" then
				record.admitting = false
				finish(record, refusal(load_error or "HTTP redirect policy unavailable")); return operation
			end
			local parsed, initial = pcall(redirect.address, url)
			if not redirect_still_current() then return operation end
			if not parsed or type(initial) ~= "table" or type(initial.key) ~= "string" then
				record.admitting = false
				finish(record, refusal("HTTP redirect URL refused")); return operation
			end
			local copied, headers_copy = pcall(function()
				local copy = {}
				for name, value in pairs(headers) do copy[name] = value end
				return copy
			end)
			if not redirect_still_current() then return operation end
			if not copied then
				record.admitting = false
				finish(record, refusal("HTTP redirect headers refused")); return operation
			end
			record.redirect_policy, record.hops, record.visited = redirect, 0, { [initial.key] = true }
			record.https_floor = redirect_options.https_only == true or initial.scheme == "https"
			record.headers = headers_copy
		end
		local fetched, environment = pcall(dependencies.environment)
		local route, err
		if fetched then route, err = dependencies.policy.route(url, environment) end
		if admission then
			if not source_admitted(record) then
				record.admitting = false
				finish(record, refusal("cancelled")); return operation
			end
			if record.operation._cancelled then
				record.admitting = false; finish(record, refusal("cancelled")); return operation
			end
			local budget = remaining(record)
			if not reservation_current(record) or operation._cancelled or operation._settled then
				record.admitting = false; finish(record, refusal("cancelled")); return operation
			end
			if budget <= 0 then record.admitting = false; expire(record); return operation end
			if not route then
				record.admitting = false; finish(record, refusal(err or "proxy-environment-unavailable")); return operation
			end
			record.route, record.admitted, record.visible_active = route, true, true
			-- Keep the tentative successor fenced while timer ports may reenter
			-- predecessor settlement. Its absolute wait budget is already running.
			if not arm_deadline(record) then
				record.admitting = false
				-- Failed arming never accepts a replacement or cancels its valid
				-- predecessor; the exact allocated timer debt remains linked.
				if record.deadline_failed then record.admitted = false end
				if record.pending_result then finish(record, record.pending_result) end
				return operation
			end
			if record.operation._cancelled or record.expired then
				record.admitting = false; finish(record, record.pending_result or refusal("cancelled")); return operation
			end
			local incumbent = record.predecessor
			if incumbent then
				operation.started = true
				local cancellation_accepted
				if record.cancelled_predecessor_receipt then
					-- Revalidate after metadata/environment/timer reentry. The old
					-- positive ACK is not permission to signal an already cancelled child again.
					cancellation_accepted = cancelled_boolean_budget_current(incumbent, record.cancelled_predecessor_receipt)
					-- A clock callback may complete the old exact physical owner;
					-- its settled adoption is the ordinary standalone admission path.
					if record.predecessor == nil and incumbent.operation._settled
						and reservation_current(record) and not operation._cancelled and not operation._settled then
						cancellation_accepted = true
					end
				else cancellation_accepted = request_cancel(incumbent) end
				if not cancellation_accepted then
					-- Refused admission remains terminal while its own timer closes;
					-- predecessor retirement must never dispatch this reservation.
					record.replacement_refused = true
					operation.started, record.admitted, record.visible_active, record.admitting = false, false, false, false
					finish(record, refusal(record.cancelled_predecessor_receipt and "previous request cleanup pending"
						or "previous request cancellation failed")); return operation
				end
			end
			record.admitting = false
			if record.operation._cancelled or record.operation._settled or record.expired then
				finish(record, record.pending_result or refusal("cancelled")); return operation
			end
			if not record.predecessor then dispatch_route(record, route) end
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
