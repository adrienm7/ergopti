--- modules/llm/local_servers.lua

--- Local API discovery's Linux native port. The shared controller owns logical
--- sweeps; every catalogue server retains a separate HTTP physical cleanup owner.
local M = {}
local Catalogue = require("modules.llm.local_server_catalogue")
local Discovery = require("llm.local_server_discovery")
local Auth = require("llm.local_server_auth")
local Entries = require("modules.llm.api_entries")
local Remote = require("modules.llm.api_remote")
local Http = require("adapters.http_client")
local Timings = require("infra.timings")
local Clock = require("infra.monotonic")
local Logger = require("logger.shim")
local LOG = "llm.local_servers"
local catalogue_order, catalogue_servers = Catalogue.load({})
local order, servers = catalogue_order, catalogue_servers
local requests, pending, view_receipts = {}, {}, setmetatable({}, { __mode = "k" })
local closed, view_generation, configuration_generation = false, 0, 0
local cached_source, source_initialized = nil, false
local controller = Discovery.new({ order = order, clock = Clock.now_ms,
	max_age = function() return Timings.ms("llm", "local_server_detection_max_age_ms") end,
	on_publish = function(_, changed)
		if changed then view_generation = view_generation + 1 end
		-- A joint negative source refusal may publish while no physical source
		-- receipt is admitted. It never authorizes a model for that source.
		cached_source, source_initialized = Entries.capture_source(), true
	end,
	on_error = function(kind) Logger.warn(LOG, "Local discovery %s was refused.", kind) end })

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
		view_generation = view_generation + 1
		for _, record in pairs(requests) do
			record.successor = nil
			if record.operation then record.operation:cancel() end
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
			return { id = id, entry_id = entry.id, provider = entry.provider,
				base_url = entry.base_url ~= "" and entry.base_url or server.base_url, token = entry.token }
		end
	end
	local fields = pending[id] or {}
	return { id = id, base_url = fields.base_url or server.base_url, token = fields.token or "" }
end

local function same_target(a, b)
	return a and b and a.id == b.id and a.entry_id == b.entry_id and a.provider == b.provider and a.base_url == b.base_url and a.token == b.token
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
	if requests[id] ~= record or not record.operation or record.operation:is_settled() ~= true then return end
	requests[id] = nil
	local successor = record.successor
	if successor then acquire(id, successor) end
end

--- A successor may wait behind an exact native operation's retained close debt.
acquire = function(id, job)
	if not job.current() then job.settle(nil); return end
	local prior = requests[id]
	if prior then
		prior.successor = job
		if prior.operation then prior.operation:cancel(); retire(id, prior) end
		return
	end
	local record = { constructing = true }
	requests[id] = record
	local headers = { ["Accept"] = "application/json" }
	if job.target.token ~= "" then headers.Authorization = "Bearer " .. job.target.token end
	local normalized = Remote.normalize_base_url(job.target.base_url)
	if not normalized then requests[id] = nil; job.settle(nil); return end
	local delivered, response = false, nil
	local function deliver(value)
		if record.constructing or record.observing then delivered, response = true, value; return end
		if requests[id] == record and job.current() and record.operation.started == true then job.settle(value)
		else job.settle(nil) end
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
	record.operation = operation
	if record.successor or not job.current() then operation:cancel() end
	-- Native refusal may synchronously invoke its response before returning a
	-- dead-start operation. Register typed retirement before replaying any answer.
	record.observing = true
	local observing, accepted = pcall(operation.on_settled, operation, function()
		if not record.observing then retire(id, record) end
	end)
	record.observing = false
	if not observing or accepted ~= true then
		Logger.error(LOG, "Local discovery could not observe its exact HTTP settlement owner.")
		operation:cancel()
		unavailable()
	elseif operation.started ~= true then
		Logger.error(LOG, "Local discovery native HTTP dispatch was refused.")
		unavailable()
	elseif delivered then deliver(response) end
	retire(id, record)
end

--- Starts an asynchronous catalogue sweep with source/admission fences.
function M.rescan(admit, on_done)
	if closed or type(admit) ~= "function" or not admitted(admit) then return false end
	local source = Entries.capture_source()
	if not source then return false end
	refresh_views()
	local targets, private_targets = {}, {}
	for _, id in ipairs(order) do
		local target = M.target(id)
		private_targets[id] = target
		targets[#targets + 1] = { id = id, base_url = target.base_url }
	end
	return controller.sweep(targets, function(target, settle, ticket)
		local captured = private_targets[target.id]
		local function current()
			return not closed and ticket.is_current() and admitted(admit)
				and Entries.source_is_current(source) and same_target(captured, M.target(target.id)) and ticket.is_current()
		end
		acquire(target.id, { target = captured, settle = settle, current = current })
		return true
	end, on_done)
end

--- Logical fencing precedes physical cancellation; unresolved owners stay retained.
function M.cancel()
	view_generation = view_generation + 1
	controller.invalidate()
	local settled = true
	for id, record in pairs(requests) do
		record.successor = nil
		if record.operation then record.operation:cancel(); retire(id, record) end
		if requests[id] ~= nil then settled = false end
	end
	return settled
end
function M.shutdown() closed = true; return M.cancel() end
function M.order() refresh_views(); local copy = {}; for index,id in ipairs(order) do copy[index] = id end; return copy end
function M.servers() refresh_views(); return servers end
function M.result(id) refresh_views(); return controller.result(id) end
function M.detected() refresh_views(); return controller.detected() end
function M.is_stale() refresh_views(); return controller.is_stale() end
function M.is_sweeping() return controller.is_sweeping() end
return M
