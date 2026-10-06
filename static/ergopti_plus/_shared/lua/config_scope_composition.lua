--- _shared/lua/config_scope_composition.lua

--- ==============================================================================
--- MODULE: Configuration Scope Composition
--- DESCRIPTION:
--- Runs the participants of a composite manifest scope (the global one) as one
--- all-or-nothing unit. Each participant keeps its own backup, conflict
--- detection and runtime acknowledgement; the composition orders them by the
--- manifest's `includes` and reverts every committed one, newest first, when a
--- later one refuses.
---
--- FEATURES & RATIONALE:
--- 1. One Registry: participants are looked up by manifest scope id. A scope
---    with no registered participant is skipped and reported, never guessed,
---    so a driver composes whatever owners it has without a second list.
--- 2. Continuation Contract: a participant settles each request through a
---    callback, synchronously or later, so a native owner whose terminal
---    acknowledgement is asynchronous composes like a file-only one.
--- 3. Retained Debt: a refused revert keeps the remaining inverse queue; the
---    owner stays pending until retry_restore() settles it in the same order.
--- 4. Finalization Debt: refused inverse release retains its exact ordered
---    cohort. Retry forgets only remaining inverses; already committed sources
---    and acknowledged releases are never rolled back or repeated.
---
--- A participant is a table with:
---   apply(mode, done)    done(committed, detail) exactly once
---   revert(done)         undoes its last commit; done(reverted, detail) once
---   release()            nil/true forgets the inverse; other receipts refuse
---   pending()            true while it retains its own compensation debt
---   retry_restore(done)  settles that debt; done(settled) once
--- ==============================================================================

local M = {}

local PORTS = { "apply", "revert", "release", "pending", "retry_restore" }

--- Wraps a callback so a duplicate settlement is reported and ignored.
--- @param logger table Host logger.
--- @param log string Log category.
--- @param label string What settles, for the report.
--- @param callback function The single continuation.
--- @return function once
local function once(logger, log, label, callback)
	local settled = false
	return function(...)
		if settled then
			logger.warn(log, "Duplicate settlement ignored: %s.", label)
			return
		end
		settled = true
		return callback(...)
	end
end

--- Invokes one participant port with a single-settlement continuation. A port
--- that raises before settling is a refusal; a raise after its settlement comes
--- from the continuation chain and is reported instead of settling twice.
--- @param logger table Host logger.
--- @param log string Log category.
--- @param label string Participant port, for the report.
--- @param port function Participant port receiving only the continuation.
--- @param callback function Continuation receiving (ok, detail).
local function invoke(logger, log, label, port, callback)
	local settled = false
	local continuation = once(logger, log, label, function(...)
		settled = true
		return callback(...)
	end)
	local called, raised = pcall(port, continuation)
	if called then return end
	if settled then
		logger.error(log, "Continuation after %s raised: %s.", label, tostring(raised))
		return
	end
	return continuation(false, tostring(raised))
end

--- Resolves the ordered participant steps of one composite scope.
--- @param scopes table Manifest scope declarations.
--- @param scope string Composite scope id.
--- @param registry table Scope id -> participant or ordered participant list.
--- @return table steps Ordered `{ id, participant }` records.
--- @return table skipped Scope ids without a registered participant.
local function resolve(scopes, scope, registry)
	local declaration = scopes[scope]
	assert(type(declaration) == "table", "unknown composite configuration scope: " .. tostring(scope))
	assert(type(declaration.includes) == "table" and #declaration.includes > 0,
		"configuration scope " .. scope .. " composes no scope")
	local order = {}
	for _, id in ipairs(declaration.includes) do
		assert(type(scopes[id]) == "table", "composite scope includes an unknown scope: " .. tostring(id))
		order[#order + 1] = id
	end
	-- The composite's own prefixes belong to a participant registered under its id.
	if type(declaration.prefixes) == "table" and #declaration.prefixes > 0 then order[#order + 1] = scope end
	for id in pairs(registry) do
		local known = false
		for _, candidate in ipairs(order) do known = known or candidate == id end
		assert(known, "participant registered for a scope outside " .. scope .. ": " .. tostring(id))
	end
	local steps, skipped = {}, {}
	for _, id in ipairs(order) do
		local entry = registry[id]
		local list = type(entry) == "table" and type(entry.apply) ~= "function" and entry or { entry }
		if entry == nil or #list == 0 then
			skipped[#skipped + 1] = id
		else
			for _, participant in ipairs(list) do
				assert(type(participant) == "table", "invalid participant for scope " .. id)
				for _, port in ipairs(PORTS) do
					assert(type(participant[port]) == "function",
						"participant for scope " .. id .. " lacks " .. port)
				end
				steps[#steps + 1] = { id = id, participant = participant }
			end
		end
	end
	return steps, skipped
end

--- Creates the owner of one composite scope.
--- @param options table Manifest reader, composite scope id, participant
---   registry provider and host logger.
--- @return table owner apply(mode, done), pending(), retry_restore(done).
function M.new(options)
	assert(type(options) == "table" and type(options.manifest) == "table"
		and type(options.manifest.scopes) == "function", "scope composition requires the manifest reader")
	assert(type(options.scope) == "string" and options.scope ~= "", "scope composition requires a scope id")
	assert(type(options.participants) == "function", "scope composition requires a participant registry")
	local logger = options.logger
	assert(type(logger) == "table", "scope composition requires the host logger")
	for _, level in ipairs({ "start", "success", "info", "warn", "error" }) do
		assert(type(logger[level]) == "function", "scope composition logger lacks " .. level)
	end
	local LOG = options.log or "config_scope_composition"
	local owner = {}
	local busy = false
	-- Debt left by a refused rollback: the failed participant's own inverse,
	-- the participant whose revert was refused, then the committed queue.
	local debt = nil

	--- Settles retained debt in order; done(settled) exactly once.
	local function settle(done)
		if debt == nil then return done(true) end
		if debt.release_queue then
			while debt.release_index <= #debt.release_queue do
				local current = debt.release_queue[debt.release_index]
				local called, released, detail = pcall(current.participant.release)
				if not called or (released ~= nil and released ~= true) then
					return done(false, current.id, called and tostring(detail or "inverse release refused") or tostring(released))
				end
				debt.release_index = debt.release_index + 1
			end
			debt = nil
			logger.info(LOG, "Scope %s inverse releases settled.", options.scope)
			return done(true)
		end
		local function continue()
			if debt.failed and debt.failed.participant.pending() == true then
				local failed = debt.failed
				return invoke(logger, LOG, "retry " .. failed.id, failed.participant.retry_restore, function(settled)
					if settled ~= true then return done(false) end
					debt.failed = nil
					return continue()
				end)
			end
			debt.failed = nil
			local step = debt.stuck or table.remove(debt.queue)
			if step == nil then
				debt = nil
				logger.info(LOG, "Scope %s rollback settled.", options.scope)
				return done(true)
			end
			debt.stuck = step
			local retry = step.participant.pending() == true and step.participant.retry_restore
				or step.participant.revert
			return invoke(logger, LOG, "revert " .. step.id, retry, function(settled)
				if settled ~= true then return done(false) end
				debt.stuck = nil
				return continue()
			end)
		end
		return continue()
	end

	function owner.pending()
		if busy or debt ~= nil then return true end
		return false
	end

	--- Retries retained rollback or finalization debt; done(settled) exactly once.
	--- @param done function|nil Continuation.
	--- @return boolean accepted
	function owner.retry_restore(done)
		done = done or function() end
		if busy then done(false); return false end
		busy = true
		settle(once(logger, LOG, "retry " .. options.scope, function(settled)
			busy = false
			return done(settled == true)
		end))
		return true
	end

	--- Applies one mode to every registered participant, all or nothing.
	--- @param mode string "recommended" or "clear".
	--- @param done function|nil Continuation receiving (committed, report).
	--- @return boolean accepted False when refused before any participant ran.
	function owner.apply(mode, done)
		done = done or function() end
		local report = { scope = options.scope, mode = mode, applied = {}, skipped = {} }
		if mode ~= "recommended" and mode ~= "clear" then
			report.detail = "unknown scope mode"
			done(false, report)
			return false
		end
		if busy or debt ~= nil then
			report.detail = "a composed configuration transaction is still pending"
			done(false, report)
			return false
		end
		local resolved, steps, skipped = pcall(function()
			return resolve(options.manifest.scopes(), options.scope, options.participants())
		end)
		if not resolved then
			report.detail = tostring(steps)
			logger.error(LOG, "Scope %s cannot be composed: %s.", options.scope, report.detail)
			done(false, report)
			return false
		end
		report.skipped = skipped
		for _, step in ipairs(steps) do
			if step.participant.pending() ~= false then
				report.detail = "participant " .. step.id .. " retains unsettled debt"
				logger.warn(LOG, "Scope %s refused: %s.", options.scope, report.detail)
				done(false, report)
				return false
			end
		end
		for _, id in ipairs(skipped) do
			logger.warn(LOG, "Scope %s %s skips %s: no participant is registered.", options.scope, mode, id)
		end
		busy = true
		logger.start(LOG, "Scope %s %s started (%d participant(s)).", options.scope, mode, #steps)
		local committed = {}
		local function finish(ok)
			busy = false
			if ok then
				logger.success(LOG, "Scope %s %s committed: %s.", options.scope, mode, table.concat(report.applied, ", "))
			else
				logger.error(LOG, "Scope %s %s refused at %s: %s.", options.scope, mode,
					tostring(report.failed), tostring(report.detail))
			end
			return done(ok, report)
		end
		local function roll_back()
			debt = { queue = committed }
			if report.failed_step and report.failed_step.participant.pending() == true then
				debt.failed = report.failed_step
			end
			report.failed_step = nil
			return settle(once(logger, LOG, "rollback " .. options.scope, function(settled)
				report.reverted = settled == true
				if not settled then report.detail = tostring(report.detail) .. "; rollback remains pending" end
				return finish(false)
			end))
		end
		local index = 0
		local function step()
			index = index + 1
			local current = steps[index]
			if current == nil then
				-- Every preference candidate is committed. An acknowledged inverse
				-- release is irreversible, so later refusals retain finalization,
				-- never pretend the already released cohorts can roll back.
				debt = { release_queue = committed, release_index = 1 }
				return settle(once(logger, LOG, "finalize " .. options.scope, function(settled, failed, detail)
					if settled ~= true then
						report.failed, report.detail = failed, detail
						report.phase, report.committed, report.finalization_pending = "finalization", true, true
						return finish(false)
					end
					return finish(true)
				end))
			end
			local function apply(continuation) return current.participant.apply(mode, continuation) end
			return invoke(logger, LOG, "apply " .. current.id, apply, function(ok, detail)
				if ok == true then
					committed[#committed + 1] = current
					report.applied[#report.applied + 1] = current.id
					return step()
				end
				report.failed, report.failed_step = current.id, current
				report.detail = tostring(detail or "participant refused")
				return roll_back()
			end)
		end
		step()
		return true
	end
	return owner
end

return M
