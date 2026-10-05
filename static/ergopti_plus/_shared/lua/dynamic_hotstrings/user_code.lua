--- _shared/lua/dynamic_hotstrings/user_code.lua

--- ==============================================================================
--- MODULE: Programmable Dynamic Hotstring Ownership
--- DESCRIPTION:
--- Owns user rule metadata and revocable execution tickets. Native ports retain
--- source, input, destination, scheduling and output authority; previews never
--- evaluate user callbacks.
--- ==============================================================================

local M = {}
local Utf8 = require("compat.utf8")

local function plain(value)
	return type(value) == "table" and getmetatable(value) == nil
end

local function text(value, nonempty)
	return type(value) == "string" and (not nonempty or value ~= "")
		and not value:find("[%z\r\n]") and Utf8.len(value) ~= nil
end

--- Validates an ordered source publication without invoking its callbacks.
--- @param rules any Complete factory result.
--- @return table|nil owned Detached descriptor array retaining native functions.
--- @return string|nil reason Stable refusal code without source contents.
function M.validate(rules)
	if not plain(rules) then return nil, "invalid-rules" end
	local count = 0
	for key in pairs(rules) do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #rules then
			return nil, "invalid-rule-order"
		end
		count = count + 1
	end
	if count ~= #rules then return nil, "invalid-rule-order" end
	local owned, ids, suffixes = {}, {}, {}
	for _, rule in ipairs(rules) do
		if not plain(rule) or not text(rule.id, true) or not rule.id:match("^[a-z][a-z0-9_]*$")
			or not text(rule.suffix, true) or not text(rule.preview, true)
			or type(rule.callback) ~= "function" then return nil, "invalid-rule" end
		for key in pairs(rule) do
			if key ~= "id" and key ~= "suffix" and key ~= "preview" and key ~= "callback" then
				return nil, "unknown-rule-field"
			end
		end
		if ids[rule.id] or suffixes[rule.suffix] then return nil, "duplicate-rule" end
		ids[rule.id], suffixes[rule.suffix] = true, true
		owned[#owned + 1] = { id = rule.id, suffix = rule.suffix, preview = rule.preview, callback = rule.callback }
	end
	return owned
end

local function source(value)
	return plain(value) and text(value.path, true) and type(value.present) == "boolean"
		and type(value.content) == "string" and (value.present or value.content == "")
end

--- Constructs one lifecycle owner with explicitly acknowledged native ports.
--- @param ports table Capture/current/invoke/commit/report native functions.
--- commit receives independent current/cached publication guards. Its optional
--- second return owns exact native cancel/is_settled/on_settled ports, including
--- cleanup adopted before a false commit acknowledgement. Queue acceptance alone
--- never makes that receipt quiescent.
--- @return table owner
function M.new(ports)
	assert(plain(ports), "programmable hotstrings require native ports")
	for _, name in ipairs({ "capture", "current", "invoke", "commit", "report" }) do
		assert(type(ports[name]) == "function", "programmable hotstring port missing: " .. name)
	end
	for _, name in ipairs({ "publication_current", "publication_cached" }) do
		assert(ports[name] == nil or type(ports[name]) == "function", "invalid programmable publication port: " .. name)
	end
	local owner, rules, opening = {}, {}, nil
	local generation, enabled, stopped, ready = 0, false, false, false
	local active, publications, debt = {}, {}, {}

	local function report(kind, id)
		local ok, ack = pcall(ports.report, kind, id)
		return ok and ack == true
	end

	local function cancel(operation)
		if type(operation) ~= "table" or type(operation.cancel) ~= "function" then return false end
		local ok, ack = pcall(operation.cancel)
		return ok and ack == true
	end

	local function drain()
		local retained = {}
		for _, operation in ipairs(debt) do
			if not cancel(operation) then retained[#retained + 1] = operation end
		end
		debt = retained
		return #debt == 0
	end

	local function publication_settled(record)
		if type(record.receipt.is_settled) ~= "function" then return false end
		local ok, acknowledged = pcall(record.receipt.is_settled)
		return ok and acknowledged == true
	end

	local function finish_publication(record, status)
		if record.completed then return true end
		if not publication_settled(record) then return false end
		record.completed, record.publication.closed = true, true
		if publications[record.publication] == record then publications[record.publication] = nil end
		if status == "failed" then report("output-refused", record.rule.id) end
		return true
	end

	local function retain_publication(receipt, publication, rule)
		local record = { receipt = receipt, publication = publication, rule = rule }
		record.operation = { cancel = function()
			publication.closed = true
			if publication_settled(record) then return finish_publication(record) end
			if not cancel(receipt) or not publication_settled(record) then return false end
			return finish_publication(record)
		end }
		publications[publication] = record
		if type(receipt.cancel) ~= "function" or type(receipt.is_settled) ~= "function"
			or type(receipt.on_settled) ~= "function" then return false, record end
		local ok, subscribed = pcall(receipt.on_settled, function(status)
			return finish_publication(record, status)
		end)
		if not ok or subscribed ~= true then return false, record end
		if publication_settled(record) then finish_publication(record) end
		return true, record
	end

	local function cancel_publication(record)
		if cancel(record.operation) then return true end
		if not record.in_debt then
			record.in_debt = true
			debt[#debt + 1] = record.operation
		end
		return false
	end

	--- Retires tickets before requesting native cancellation; refusal retains debt.
	--- @param reason string Stable lifecycle reason for diagnostics.
	--- @return boolean acknowledged
	function owner.invalidate(reason)
		generation = generation + 1
		local retiring = active
		active = {}
		for _, ticket in pairs(retiring) do
			if ticket.operation and not cancel(ticket.operation) then debt[#debt + 1] = ticket.operation end
		end
		local retiring_publications = publications
		publications = {}
		for _, record in pairs(retiring_publications) do cancel_publication(record) end
		local ack = drain()
		if not ack then report("cancellation-refused", reason) end
		return ack
	end

	--- Publishes one complete classified source; failed replacement stays closed.
	--- @param candidate table Factory descriptors.
	--- @param receipt table Exact admitted path, presence and source bytes.
	--- @return boolean acknowledged
	function owner.reload(candidate, receipt)
		ready = false
		local cancelled = owner.invalidate("reload")
		local staged, reason = M.validate(candidate)
		if not source(receipt) then reason = "invalid-source"
		elseif receipt.present ~= true then reason = "source-absent" end
		if reason or not cancelled then
			enabled = false
			report(reason or "cancellation-refused", "load")
			return false
		end
		rules, opening = staged, { path = receipt.path, present = receipt.present, content = receipt.content }
		ready = true
		return true
	end

	--- Sets explicit posture; an outstanding cancellation cannot reopen execution.
	--- @param value boolean Desired gate.
	--- @return boolean acknowledged
	function owner.set_enabled(value)
		if type(value) ~= "boolean" or stopped then return false end
		enabled = false
		if not owner.invalidate("enabled") then return false end
		enabled = value
		return true
	end

	--- Quarantines retained metadata after a source refusal without discarding closures.
	--- @return boolean closed Native cancellation acknowledged exactly.
	function owner.refuse_source()
		ready = false
		return owner.set_enabled(false)
	end

	--- Closes the owner permanently and acknowledges every native retirement.
	--- @return boolean acknowledged
	function owner.stop()
		enabled, stopped, ready = false, true, false
		return owner.invalidate("stop")
	end

	local function find(buffer)
		if not enabled or stopped or not ready or #debt ~= 0 or type(buffer) ~= "string" then return nil end
		for _, rule in ipairs(rules) do
			if buffer:sub(-#rule.suffix) == rule.suffix then return rule end
		end
	end

	--- Supplies metadata only; rendering grants no callback or output authority.
	--- @param buffer string Text preceding the magic key.
	--- @return table|nil preview Detached static descriptor.
	function owner.preview(buffer)
		local rule = find(buffer)
		if not rule then return nil end
		return { id = rule.id, suffix = rule.suffix, preview = rule.preview }
	end

	local function retained(ticket)
		if active[ticket] ~= ticket or ticket.generation ~= generation or not enabled or stopped or not ready then
			return false
		end
		return true
	end

	local function current(ticket)
		if not retained(ticket) then return false end
		local ok, ack = pcall(ports.current, ticket.capture, ticket.source)
		return ok and ack == true and retained(ticket)
	end

	local function publication_guard(ticket)
		local publication = { closed = false }
		local function retained_publication()
			return not publication.closed and ticket.generation == generation and enabled and not stopped and ready
		end
		--- Rechecks exact source and native context outside the physical callback.
		--- @return boolean current
		function publication.current()
			if not retained_publication() then return false end
			local probe = ports.publication_current or ports.current
			local ok, acknowledged = pcall(probe, ticket.capture, ticket.source)
			return ok and acknowledged == true and retained_publication()
		end
		--- Checks only cached native context when a raw output callback must post.
		--- @return boolean current
		function publication.cached()
			if not retained_publication() then return false end
			if ports.publication_cached == nil then return true end
			local ok, acknowledged = pcall(ports.publication_cached, ticket.capture, ticket.source)
			return ok and acknowledged == true and retained_publication()
		end
		return publication
	end

	local function retire(ticket, reason)
		if ticket.retired then return true end
		if ports.retire == nil then ticket.retired = true; return true end
		if not ticket.retirement_operation then
			ticket.retirement_operation = { cancel = function()
				if ticket.retired then return true end
				local ok, ack = pcall(ports.retire, ticket.capture, ticket.rule, reason)
				if ok and ack == true then ticket.retired = true; return true end
				return false
			end }
		end
		if cancel(ticket.retirement_operation) then return true end
		if not ticket.retirement_debt then
			ticket.retirement_debt = true
			debt[#debt + 1] = ticket.retirement_operation
		end
		report("retirement-refused", ticket.rule.id)
		return false
	end

	--- Admits a lazily started operation under exact source/input/destination fences.
	--- @param buffer string Text preceding the physical magic key.
	--- @return boolean accepted True means the native operation owns its completion.
	function owner.request(buffer)
		local rule = find(buffer)
		if not rule then return false end
		local epoch = generation
		local ok, capture = pcall(ports.capture, rule)
		if not ok or capture == nil or capture == false or epoch ~= generation then return false end
		local ticket = { generation = epoch, capture = capture, rule = rule,
			source = { path = opening.path, present = opening.present, content = opening.content } }
		active[ticket] = ticket
		local context = { id = rule.id, suffix = rule.suffix, cancelled = function() return not current(ticket) end }
		local function done(result, failure)
			if not current(ticket) then active[ticket] = nil; retire(ticket, "stale-completion"); return false end
			local valid = result == nil or type(result) == "boolean"
				or (type(result) == "string" and result ~= "" and Utf8.len(result) ~= nil)
			if failure ~= nil or not valid then report(failure ~= nil and "execution-failed" or "invalid-result", rule.id); result = false end
			if not current(ticket) then active[ticket] = nil; retire(ticket, "stale-completion"); return false end
			if result == nil then result = false end
			local publication = publication_guard(ticket)
			local committed_ok, ack, receipt = pcall(ports.commit, result, capture, rule, publication)
			local subscribed, record = true, nil
			if type(receipt) == "table" then
				subscribed, record = retain_publication(receipt, publication, rule)
			elseif receipt ~= nil then subscribed = false end
			active[ticket] = nil
			if ticket.generation ~= generation or not enabled or stopped or not ready then
				publication.closed = true
				if record then cancel_publication(record) end
				retire(ticket, "stale-completion")
				if not committed_ok or ack ~= true then report("output-refused", rule.id) end
				return false
			end
			if not committed_ok or ack ~= true or not subscribed then
				publication.closed = true
				if record then cancel_publication(record) end
				retire(ticket, "output-refused")
				report("output-refused", rule.id)
				return false
			end
			if not record then publication.closed = true end
			return true
		end
		local invoked, operation = pcall(ports.invoke, rule, context, done, capture)
		if not invoked or type(operation) ~= "table" or type(operation.start) ~= "function"
			or type(operation.cancel) ~= "function" then
			active[ticket] = nil
			retire(ticket, "launch-refused")
			report("launch-refused", rule.id)
			return false
		end
		ticket.operation = operation
		if not retained(ticket) then
			active[ticket] = nil
			if not cancel(operation) then debt[#debt + 1] = operation end
			retire(ticket, "stale-launch")
			return false
		end
		local started, ack = pcall(operation.start)
		if not started or ack ~= true then
			active[ticket] = nil
			if not cancel(operation) then debt[#debt + 1] = operation end
			retire(ticket, "launch-refused")
			report("launch-refused", rule.id)
			return false
		end
		return true
	end

	--- Returns detached static rule metadata without exposing executable functions.
	--- @return table rules
	function owner.rules()
		local records = {}
		for _, rule in ipairs(rules) do records[#records + 1] = { id = rule.id, suffix = rule.suffix, preview = rule.preview } end
		return records
	end

	--- Captures the exact publication for a configuration inverse, retaining closures.
	--- @return table snapshot Detached state bound to this lifecycle owner.
	function owner.scope_snapshot()
		return { owner = owner, rules = assert(M.validate(rules)),
			source = opening and { path = opening.path, present = opening.present, content = opening.content } or nil,
			ready = ready, enabled = enabled, stopped = stopped,
			quiescent = next(active) == nil and next(publications) == nil and #debt == 0 }
	end

	--- Restores captured publication only after every native cancellation acknowledges.
	--- @param snapshot table Publication captured from this same owner.
	--- @return boolean restored
	function owner.scope_restore(snapshot)
		if not plain(snapshot) or snapshot.owner ~= owner or type(snapshot.ready) ~= "boolean"
			or type(snapshot.enabled) ~= "boolean" or type(snapshot.stopped) ~= "boolean"
			or (stopped and not snapshot.stopped) then return false end
		local candidate = M.validate(snapshot.rules)
		if not candidate or (snapshot.source ~= nil and not source(snapshot.source))
			or (snapshot.ready and (snapshot.source == nil or snapshot.source.present ~= true)) then return false end
		if owner.invalidate("configuration inverse") ~= true then return false end
		rules = candidate
		opening = snapshot.source and { path = snapshot.source.path, present = snapshot.source.present,
			content = snapshot.source.content } or nil
		ready, enabled, stopped = snapshot.ready, snapshot.enabled, snapshot.stopped
		return true
	end

	--- Counts retained metadata, including quarantined configuration inverses.
	--- @return integer count
	function owner.count() return #rules end

	--- Counts only admitted metadata; quarantined closures remain invisible.
	--- @return integer count
	function owner.admitted_count() return ready and #rules or 0 end
	return owner
end

return M
