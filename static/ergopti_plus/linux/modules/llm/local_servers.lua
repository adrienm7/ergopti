--- modules/llm/local_servers.lua

--- Local API discovery's Linux native port. The shared controller owns logical
--- sweeps; every catalogue server retains a separate HTTP physical cleanup owner.
local M = {}
local Catalogue = require("modules.llm.local_server_catalogue")
local Ports = require("modules.llm.local_server_ports")
local Discovery = require("ai.engine.local_servers.discovery")
local Auth = require("ai.engine.local_servers.auth")
local Menu = require("ai.engine.local_servers.menu")
local Entries = require("modules.llm.api_entries")
local Remote = require("modules.llm.api_remote")
local Http = require("core.network.adapters.http_client")
local Timings = require("core.timing.engine.timings")
local Clock = require("core.logger.engine.monotonic")
local EventLoop = require("core.events.loop")
local Logger = require("core.logger.engine.shim")
local LOG = "llm.local_servers"
local catalogue_order, catalogue_servers, _, catalogue_discovery, _, _, catalogue_identities = Catalogue.load({})
-- Server id -> the last port scan result (llm.local_server_ports); the callbacks
-- of the rescans waiting for the running scan, nil when none runs
local port_scans, scan_waiters, scan_owners = {}, nil, {}
local order, servers = catalogue_order, catalogue_servers
local requests, pending, view_receipts = {}, {}, setmetatable({}, { __mode = "k" })
local queued = {}
local closed, cancelling, active_waiters, active_rescans, active_acquisitions, active_http_callbacks, cancel_generation, view_generation, configuration_generation = false, false, 0, 0, 0, 0, 0, 0, 0
local cached_source, source_initialized = nil, false
local controller = Discovery.new({ order = order, clock = Clock.now_ms, identities = catalogue_identities,
	max_age = function() return Timings.ms("llm", "local_server_detection_max_age_ms") end,
	on_publish = function(results, changed)
		if changed then view_generation = view_generation + 1 end
		local found = {}
		for _, id in ipairs(order) do
			local result = results[id]
			if result and result.status ~= Discovery.STATUS_DOWN then
				local scan = port_scans[id]
				found[#found + 1] = string.format("%s=%s at %s%s%s", id, result.status, tostring(result.base_url),
					scan and scan.source and scan.base_url == result.base_url and (" (port from " .. scan.source .. ")") or "",
					result.server and (" (answers as " .. result.server .. ")") or "")
			elseif result and result.shadowed_by then
				found[#found + 1] = string.format("%s at %s answers as %s", id, tostring(result.base_url), result.shadowed_by)
			end
		end
		Logger.info(LOG, "Local servers swept: %s.", #found > 0 and table.concat(found, ", ") or "none answers")
		-- A joint negative source refusal may publish while no physical source
		-- receipt is admitted. It never authorizes a model for that source.
		cached_source, source_initialized = Entries.capture_source(), true
	end,
	on_error = function(kind) Logger.warn(LOG, "Local discovery %s was refused.", kind) end })

--- Releases queued credentials before native cancellation or event-loop stop.
local function revoke_queued()
	for id, record in pairs(queued) do record.job = nil; queued[id] = nil end
end

--- Synchronizes private source identity and view membership without acknowledging
--- any retired native owner. Credentials never enter the shared cache authority.
local function refresh_views()
	local providers = {}
	for _, id in ipairs({ "openai", "openai_compat" }) do providers[id] = Remote.provider(id) end
	local configured_order, configured = Auth.configured_views(Entries.list(), catalogue_servers, providers)
	local source = Entries.capture_source()
	local source_changed = source_initialized and ((cached_source ~= nil and not Entries.source_is_current(cached_source))
		or (cached_source == nil and source ~= nil))
	cached_source, source_initialized = source, true
	local next_order, next_servers = {}, {}
	for _, id in ipairs(catalogue_order) do next_order[#next_order + 1] = id; next_servers[id] = catalogue_servers[id] end
	for _, id in ipairs(configured_order) do next_order[#next_order + 1] = id; next_servers[id] = configured[id] end
	local changed = controller.set_order(next_order, source_changed)
	order, servers = next_order, next_servers
	if changed then
		revoke_queued()
		view_generation = view_generation + 1
		for _, record in pairs(requests) do
			record.successor = nil
			if record.operation and record.cancel then pcall(record.cancel, record.operation) end
		end
	end
end

--- Resolves native target fields without passing credentials into shared state.
function M.target(id)
	refresh_views()
	local server = servers[id]
	if not server then return nil end
	if server.entry_id then
		local entry = Entries.get(server.entry_id)
		if not entry or entry.provider ~= server.provider or entry.base_url ~= server.base_url then return nil end
		return { id = id, entry_id = entry.id, provider = entry.provider, base_url = entry.base_url, token = entry.token }
	end
	local active = Entries.active()
	for _, exact in ipairs({ true, false }) do
		local function matches(entry)
			return entry ~= nil and (entry.provider == id) == exact
				and Auth.entry_matches(entry.provider, entry.base_url, id, servers)
		end
		local entry = matches(active) and active or nil
		if not entry then
			for _, candidate in ipairs(Entries.list()) do if matches(candidate) then entry = candidate; break end end
		end
		if entry then
			-- An entry at the catalogue address follows the scan, as one stored
			-- without an address; any other address is the user's
			local scan = port_scans[id]
			local default = entry.base_url == "" or entry.base_url == server.base_url
			local base_url = entry.base_url ~= "" and entry.base_url or server.base_url
			if default and scan and scan.running then base_url = scan.base_url end
			return { id = id, entry_id = entry.id, provider = entry.provider, base_url = base_url, token = entry.token,
				port_source = default and (scan and scan.source or nil) or "user" }
		end
	end
	local fields = pending[id] or {}
	if fields.base_url then return { id = id, base_url = fields.base_url, token = fields.token or "", port_source = "user" } end
	local scan = port_scans[id]
	return { id = id, base_url = scan and scan.running and scan.base_url or server.base_url, token = fields.token or "",
		port_source = scan and scan.source or nil }
end

local function same_target(a, b)
	return a and b and a.id == b.id and a.entry_id == b.entry_id and a.provider == b.provider and a.base_url == b.base_url and a.token == b.token
end

--- Returns where the last scan found a catalogue server.
--- @param id string Server id.
--- @return table|nil { running, pids, base_url, port, source, detail }; nil before any scan.
function M.port_scan(id)
	local result = port_scans[id]
	if not result then return nil end
	local pids = {}
	for index, pid in ipairs(result.pids or {}) do pids[index] = pid end
	return { running = result.running, pids = pids, base_url = result.base_url, port = result.port,
		source = result.source, detail = result.detail }
end

local function admitted(admit)
	local ok, value = pcall(admit)
	return ok and value == true
end

--- Captures source/configuration/verdict ownership for a menu callback.
function M.capture(id)
	local source, target = Entries.capture_source(), M.target(id)
	if not source or not target or closed then return nil end
	local receipt = {}
	local verdict = controller.result(id)
	local models = {}
	for index, model in ipairs(verdict and verdict.models or {}) do models[index] = model end
	view_receipts[receipt] = { source = source, target = target, view = view_generation,
		configuration = configuration_generation, models = models }
	return receipt
end

--- Rechecks actual private-file identity and every owned observable model field.
function M.is_current(receipt, model)
	refresh_views()
	local held = type(receipt) == "table" and view_receipts[receipt] or nil
	if not held or closed or held.view ~= view_generation or held.configuration ~= configuration_generation
		or not Entries.source_is_current(held.source) or not same_target(held.target, M.target(held.target.id)) then return false end
	if model ~= nil then
		local verdict = controller.result(held.target.id)
		if not verdict or verdict.status ~= Discovery.STATUS_UP or verdict.base_url ~= held.target.base_url
			or #verdict.models ~= #held.models then return false end
		local found = false
		for index, id in ipairs(verdict.models) do
			if held.models[index] ~= id then return false end
			if id == model then found = true end
		end
		if not found then return false end
	end
	return true
end

--- Commits only current acknowledged local selections. Empty unselected address
--- preferences stay ephemeral, as in the existing Mac owner, until a model exists.
function M.apply(receipt, fields, admit)
	if type(admit) ~= "function" or not admitted(admit) or not M.is_current(receipt, fields.model) then return nil end
	local held = view_receipts[receipt]
	local target, entry = held.target, held.target.entry_id and Entries.get(held.target.entry_id)
	if not entry and fields.model == nil then
		for key, value in pairs(fields) do
			if (key ~= "base_url" and key ~= "token") or type(value) ~= "string" then return nil end
		end
		if fields.base_url and not Remote.normalize_base_url(fields.base_url) then return nil end
		if fields.token and not Auth.token_allowed(target.id, fields.token, servers) then return nil end
		pending[target.id] = pending[target.id] or {}
		for key, value in pairs(fields) do pending[target.id][key] = value end
		configuration_generation = configuration_generation + 1
		controller.invalidate()
		return { saved = false, pending = true }
	end
	local changes = { base_url = fields.base_url or target.base_url, token = fields.token or target.token,
		model = fields.model or entry.model }
	local saved = Entries.upsert_local(target.id, changes, held.source, function() return admitted(admit) end, fields.model ~= nil, target.entry_id)
	if not saved then return nil end
	pending[target.id] = nil
	configuration_generation = configuration_generation + 1
	controller.invalidate()
	return { saved = true, entry = saved }
end

local acquire
local function retire(id, record)
	if requests[id] ~= record or not record.operation then return end
	local operation, observe = record.operation, record.observe
	if type(observe) ~= "function" or operation.is_settled ~= observe then return end
	local ok, settled = pcall(observe, operation)
	if not ok or settled ~= true or requests[id] ~= record or record.operation ~= operation
		or operation.is_settled ~= observe or requests[id] ~= record then return end
	requests[id] = nil
	local successor = record.successor
	record.successor = nil
	if successor then acquire(id, successor) end
end

--- A successor may wait behind an exact native operation's retained close debt.
local function acquire_owned(id, job)
	if not job.current() then job.settle(nil); return end
	local prior = requests[id]
	if prior then
		prior.successor = job
		if prior.operation and prior.cancel then pcall(prior.cancel, prior.operation); retire(id, prior) end
		return
	end
	local record = { constructing = true }
	requests[id] = record
	local headers = { ["Accept"] = "application/json" }
	if job.target.token ~= "" then headers.Authorization = "Bearer " .. job.target.token end
	local normalized = Remote.normalize_base_url(job.target.base_url)
	if not normalized then requests[id] = nil; job.settle(nil); return end
	local delivered, response = false, nil
	local function deliver_owned(value)
		if record.constructing or record.observing then delivered, response = true, value; return end
		if requests[id] == record and job.current() and requests[id] == record
			and record.operation.started == true and requests[id] == record then job.settle(value)
		else job.settle(nil) end
	end
	local function deliver(value)
		active_http_callbacks = active_http_callbacks + 1
		local ok = pcall(deliver_owned, value)
		if not ok then pcall(Logger.error, LOG, "Local discovery HTTP callback raised an error.") end
		active_http_callbacks = active_http_callbacks - 1
	end
	local function unavailable()
		if job.current() then job.settle({ ok = false, status = 0, body = "", probe_error = true })
		else job.settle(nil) end
	end
	local ok, operation = pcall(Http.get_owned, normalized .. "/models", headers, {
		owner = "llm_local_server:" .. id, follow_redirects = false,
		timeout_ms = Timings.ms("llm", "local_server_probe_timeout_ms") }, deliver)
	record.constructing = false
	if not ok or type(operation) ~= "table" or type(operation.is_settled) ~= "function"
		or type(operation.on_settled) ~= "function" or type(operation.cancel) ~= "function" then
		-- A malformed producer cannot acknowledge any possibly acquired handle.
		Logger.error(LOG, "Local discovery retained an uncertain HTTP owner.")
		record.untrusted_operation = operation
		unavailable()
		return
	end
	record.operation, record.observe, record.cancel, record.subscribe = operation, operation.is_settled,
		operation.cancel, operation.on_settled
	if record.successor or not job.current() then pcall(record.cancel, operation) end
	-- Native refusal may synchronously invoke its response before returning a
	-- dead-start operation. Register typed retirement before replaying any answer.
	record.observing = true
	local observing, accepted = pcall(record.subscribe, operation, function()
		active_http_callbacks = active_http_callbacks + 1
		local ok = pcall(function() if not record.observing then retire(id, record) end end)
		if not ok then pcall(Logger.error, LOG, "Local discovery settlement callback raised an error.") end
		active_http_callbacks = active_http_callbacks - 1
	end)
	record.observing = false
	if not observing or accepted ~= true then
		Logger.error(LOG, "Local discovery could not observe its exact HTTP settlement owner.")
		pcall(record.cancel, operation)
		unavailable()
	elseif operation.started ~= true then
		Logger.error(LOG, "Local discovery native HTTP dispatch was refused.")
		unavailable()
	elseif delivered then deliver(response) end
	retire(id, record)
end

acquire = function(id, job)
	active_acquisitions = active_acquisitions + 1
	local ok = pcall(acquire_owned, id, job)
	if not ok then
		pcall(Logger.error, LOG, "Local discovery acquisition raised an error; ownership is retained.")
		pcall(job.settle, nil)
	end
	active_acquisitions = active_acquisitions - 1
end

--- Defers native acquisition until after the owning loop pumps physical input.
--- The mutable receipt releases credentials even if its detached callback survives
--- cancellation. No HTTP deadline exists until acquire() actually runs.
--- @param id string Captured server identity.
--- @param job table Captured source, admission and logical settlement owner.
--- @return boolean
local function queue_acquisition(id, job)
	if queued[id] then queued[id].job = nil end
	local record = { job = job }
	queued[id] = record
	local ok, accepted = pcall(EventLoop.defer, function()
		if queued[id] ~= record then return end
		local held = record.job
		record.job, queued[id] = nil, nil
		if held then acquire(id, held) end
	end)
	if not ok or accepted ~= true then
		if queued[id] == record then queued[id] = nil; record.job = nil end
		return false
	end
	return true
end

--- Sweeps once the port scan settled: a catalogue server whose process does
--- not run, at its default address, is not probed.
--- @param admit function
--- @param on_done function Receives changed.
--- @return boolean started
local function sweep(admit, on_done)
	if closed or not admitted(admit) then return false end
	local source = Entries.capture_source()
	if not source then return false end
	refresh_views()
	local targets, private_targets = {}, {}
	for _, id in ipairs(order) do
		local target = M.target(id)
		local scan = catalogue_servers[id] and port_scans[id] or nil
		if target and target.port_source ~= "user" and scan and scan.running == false then
			Logger.debug(LOG, "Local server '%s' is not probed: %s.", id, tostring(scan.detail))
		elseif target then
			Logger.debug(LOG, "Local server '%s' probed at %s (%s).", id, Remote.redact_url(target.base_url),
				target.port_source == "user" and "address set by the user" or ("port from " .. tostring(target.port_source)))
			private_targets[id] = target
			targets[#targets + 1] = { id = id, base_url = target.base_url }
		end
	end
	return controller.sweep(targets, function(target, settle, ticket)
		local captured = private_targets[target.id]
		local function current()
			local function active()
				if closed then return false end
				local ok, held = pcall(ticket.is_current)
				return ok and held == true and not closed
			end
			if not active() or not admitted(admit) or not active() then return false end
			local checked, source_current = pcall(Entries.source_is_current, source)
			if not checked or source_current ~= true or not active() then return false end
			local read, live_target = pcall(M.target, target.id)
			if not read or not active() or not same_target(captured, live_target) then return false end
			return active()
		end
		return queue_acquisition(target.id, { target = captured, settle = settle, current = current })
	end, on_done)
end

--- A waiter remains owned through its callback stack, even after its scan retires.
local function notify_waiters(waiters, changed)
	active_waiters = active_waiters + 1
	for _, waiter in ipairs(waiters) do
		if waiter.on_done then
			local called = pcall(waiter.on_done, changed)
			if not called then pcall(Logger.error, LOG, "Local server rescan callback raised an error.") end
		end
	end
	active_waiters = active_waiters - 1
end

--- Retires a scan only when its exact owned native children acknowledge closure.
local function retire_scan(owner)
	if type(owner.operation) == "table" and owner.operation.failed == true then owner.cancelled = true end
	if owner.constructing or owner.uncertain or type(owner.operation) ~= "table" then return false end
	local ok, settled = pcall(owner.is_settled, owner.operation)
	if not ok or settled ~= true then return false end
	scan_owners[owner] = nil
	if owner.cancelled and scan_waiters == owner then
		scan_waiters = nil
		notify_waiters(owner, false)
	end
	return true
end

--- Starts an asynchronous catalogue sweep with source/admission fences, after
--- scanning where each catalogue server runs (modules/llm/local_server_ports.lua).
--- A rescan asked during the scan joins it.
--- @param admit function Current admission.
--- @param on_done function|nil Receives changed when the sweep published.
--- @return boolean started
local function rescan_owned(admit, on_done)
	local generation = cancel_generation
	local function current() return not closed and generation == cancel_generation end
	if not current() or type(admit) ~= "function" or not admitted(admit) or not current() then return false end
	for owner in pairs(scan_owners) do retire_scan(owner) end
	if not current() or not admitted(admit) or not current() then return false end
	if not Entries.capture_source() or not current() then return false end
	if scan_waiters then
		if scan_waiters.cancelled then return false end
		scan_waiters[#scan_waiters + 1] = { admit = admit, on_done = on_done }
		return true
	end
	if type(Ports.scan_owned) ~= "function" then
		Logger.error(LOG, "Owned local server port scanning is unavailable.")
		return false
	end
	local owner = { { admit = admit, on_done = on_done }, constructing = true }
	scan_owners[owner] = true
	scan_waiters = owner
	local entries, undescribed = {}, {}
	for _, id in ipairs(catalogue_order) do
		local server = catalogue_servers[id]
		if catalogue_discovery[id] then
			entries[#entries + 1] = { id = id, descriptor = catalogue_discovery[id], base_url = server.base_url }
		else
			undescribed[id] = { id = id, running = false, pids = {}, base_url = server.base_url,
				detail = "no discovery descriptor in local_servers.json" }
		end
	end
	local ok, operation = pcall(Ports.scan_owned, entries, function(results)
		if scan_waiters ~= owner then return end
		local waiters = owner
		scan_waiters = nil
		local function done(changed)
			notify_waiters(waiters, changed)
		end
		if owner.cancelled then done(false); return end
		for id, result in pairs(undescribed) do results[id] = result end
		port_scans = results
		-- The newest admission decides; an expired one publishes nothing
		local last = waiters[#waiters]
		if not last or sweep(last.admit, done) ~= true then
			Logger.warn(LOG, "Local server sweep was not admitted after its port scan.")
			done(false)
		end
	end, function() return not owner.cancelled and current() end)
	do
		owner.constructing = false
		if ok and type(operation) == "table" and type(operation.cancel) == "function"
			and type(operation.is_settled) == "function" then
			owner.operation, owner.cancel, owner.is_settled = operation, operation.cancel, operation.is_settled
			if owner.cancelled then pcall(owner.cancel, operation) end
		else
			owner.uncertain = true
		end
		if type(operation) == "table" and operation.failed then owner.cancelled = true end
		retire_scan(owner)
	end
	if not ok or owner.uncertain or operation.failed then
		-- A throwing constructor may have retained native work.
		if scan_waiters == owner then owner.cancelled = true end
		Logger.error(LOG, "The local server port scan could not start.")
		return false
	end
	return not owner.cancelled and current()
end

function M.rescan(admit, on_done)
	active_rescans = active_rescans + 1
	local ok, accepted = pcall(rescan_owned, admit, on_done)
	if not ok then pcall(Logger.error, LOG, "Local server rescan raised an error; ownership is retained.") end
	active_rescans = active_rescans - 1
	return ok and accepted == true
end

--- Lists every local server view with where it was looked for and what it
--- answered, in menu order: the stable shape the menu and the model selector
--- page read (the same as the macOS api_remote.local_server_views).
--- @return table views Array of { id, display_name, port, port_source, base_url,
---        models, status, reason }.
function M.views()
	refresh_views()
	local views = {}
	for _, id in ipairs(order) do
		local target, server = M.target(id), servers[id]
		if target and server then
			local scan = catalogue_servers[id] and port_scans[id] or nil
			local verdict = controller.result(id)
			local view = { id = id, display_name = Menu.label_of(servers, id, verdict), base_url = target.base_url,
				port = tonumber(target.base_url:match("^%a[%w+.-]*://[^/]-:(%d+)")), port_source = target.port_source }
			if target.port_source ~= "user" and scan and scan.running == false then
				view.reason = "not_running"
			elseif not verdict then
				view.reason = "not_swept"
			elseif verdict.status == Discovery.STATUS_UP then
				view.status, view.models = verdict.status, {}
				for index, model in ipairs(verdict.models or {}) do view.models[index] = model end
			else
				view.status = verdict.status
				view.reason = verdict.status == Discovery.STATUS_NEEDS_KEY and "needs_key"
					or verdict.status == Discovery.STATUS_UNAVAILABLE and "unavailable" or "no_answer"
			end
			views[#views + 1] = view
		end
	end
	return views
end

--- Logical fencing precedes physical cancellation; unresolved owners stay retained.
local function cancel_owned()
	local settled, captured = true, {}
	cancel_generation = cancel_generation + 1
	if scan_waiters then scan_waiters.cancelled = true end
	for owner in pairs(scan_owners) do
		owner.cancelled = true
		captured[#captured + 1] = owner
	end
	revoke_queued()
	view_generation = view_generation + 1
	controller.invalidate()
	for _, owner in ipairs(captured) do
		if scan_owners[owner] then
			if owner.operation then pcall(owner.cancel, owner.operation) end
			if not retire_scan(owner) then settled = false end
		end
	end
	if scan_waiters then settled = false end
	for id, record in pairs(requests) do
		record.successor = nil
		if record.operation and record.cancel then pcall(record.cancel, record.operation); retire(id, record) end
		if requests[id] ~= nil then settled = false end
	end
	-- A settlement callback may have admitted a successor after the snapshot.
	if active_waiters ~= 0 or active_rescans ~= 0 or active_acquisitions ~= 0 or active_http_callbacks ~= 0
		or scan_waiters or next(scan_owners) ~= nil
		or next(requests) ~= nil or next(queued) ~= nil then
		settled = false
	end
	return settled
end

function M.cancel()
	if cancelling then return false end
	cancelling = true
	local ok, settled = pcall(cancel_owned)
	if not ok then pcall(Logger.error, LOG, "Local server cancellation raised an error; ownership is retained.") end
	cancelling = false
	return ok and settled == true
end
function M.shutdown() closed = true; return M.cancel() end
function M.order() refresh_views(); local copy = {}; for index,id in ipairs(order) do copy[index] = id end; return copy end
function M.servers() refresh_views(); return servers end
function M.result(id) refresh_views(); return controller.result(id) end
function M.detected() refresh_views(); return controller.detected() end
function M.is_stale() refresh_views(); return controller.is_stale() end
function M.is_sweeping() return scan_waiters ~= nil or controller.is_sweeping() end
return M
