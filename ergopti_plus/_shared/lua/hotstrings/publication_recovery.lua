--- _shared/lua/hotstrings/publication_recovery.lua

--- ==============================================================================
--- MODULE: Native Hotstring Publication Recovery
--- DESCRIPTION:
--- Verifies invocation-scoped native publication capabilities and settles only
--- their retained physical release. Consumers own admission epochs, inverse
--- ordering and runtime rollback; equal bytes never establish native ownership.
--- ==============================================================================

local M = {}

local function classified(source)
	return type(source) == "table" and ((source.status == "absent" and source.content == nil)
		or (source.status == "ok" and type(source.content) == "string"))
end

local function copy_source(source)
	return { status = source.status, content = source.content }
end

local function same_source(left, right)
	return classified(left) and classified(right)
		and left.status == right.status and left.content == right.content
end

local function strict_call(callback, ...)
	local called, accepted = pcall(callback, ...)
	return called and accepted == true
end

--- Binds one actual native receipt to its invocation and consumer admission.
--- A nil result is a refusal, not evidence that native work never happened.
--- @param options table {files,native,path,expected,candidate,on_error,current}
--- @return table|nil lease Bound zero-argument native release methods.
--- @return string|nil detail Fixed refusal category.
function M.lease(options)
	if type(options) ~= "table" or type(options.files) ~= "table"
		or type(options.files.publication_receipt_view) ~= "function"
		or type(options.native) ~= "table" or type(options.path) ~= "string"
		or options.path == "" or not classified(options.expected)
		or type(options.candidate) ~= "string" or type(options.current) ~= "function"
		or (options.on_error ~= nil and type(options.on_error) ~= "function") then
		return nil, "invalid-publication-capability"
	end
	local files, native, path = options.files, options.native, options.path
	local expected, candidate = copy_source(options.expected), options.candidate
	local on_error, current = options.on_error, options.current
	local function admitted() return strict_call(current) end
	local function view()
		if not admitted() then return nil end
		local called, result = pcall(files.publication_receipt_view,
			native, path, expected, candidate, on_error)
		if not admitted() or not called or type(result) ~= "table"
			or type(result.published) ~= "boolean" or not classified(result.source) then return nil end
		local owned = result.published and { status = "ok", content = candidate } or expected
		if not same_source(owned, result.source) then return nil end
		return { published = result.published, source = copy_source(result.source) }
	end
	local function matches_source()
		if not view() or type(native.matches_source) ~= "function" then return false end
		local matched = strict_call(native.matches_source)
		return matched and view() ~= nil
	end
	local function is_settled()
		if not view() or type(native.is_settled) ~= "function" then return false end
		local settled = strict_call(native.is_settled)
		return settled and view() ~= nil
	end
	local function settle()
		if not matches_source() then return false end
		if not is_settled() then
			if not view() or type(native.retry) ~= "function" then return false end
			local released = strict_call(native.retry)
			if not released or not view() then return false end
		end
		-- A retry return, or an already-settled flag, cannot replace the actual
		-- source/route and consumer guard checks surrounding terminal settlement.
		return matches_source() and is_settled() and matches_source()
	end
	if not view() then return nil, "unverified-publication-capability" end
	return { view = view, matches_source = matches_source, is_settled = is_settled, settle = settle }
end

--- Creates one publication owner without prescribing a multi-source cohort order.
--- The default inverse restores a present source; absent-source consumers must
--- retain debt until they supply their separately verified removal capability.
--- @param options table {files,capture,current,writer?}
--- @return table owner Bound single-source publication methods.
function M.new(options)
	assert(type(options) == "table" and type(options.files) == "table"
		and type(options.capture) == "function" and type(options.current) == "function",
		"publication recovery requires its native files and consumer guards")
	local files = options.files
	assert(options.writer == nil or type(options.writer) == "table", "publication writer must be a module")
	local writer = options.writer or require("toml_codec.writer")
	assert(type(writer.publish_if_unchanged) == "function" and type(writer.read_classified) == "function",
		"publication recovery requires the conditional writer")
	local active, pending
	local function current(attempt)
		return strict_call(options.current, attempt.capture)
	end
	local function make_lease(record)
		return M.lease({ files = files, native = record.native, path = record.path,
			expected = record.expected, candidate = record.candidate, on_error = record.on_error,
			current = function() return current(record.attempt) end })
	end
	local function physical_matches(record, source)
		if not current(record.attempt) then return false end
		local called, content, status = pcall(writer.read_classified, record.path, files, record.on_error)
		return called and current(record.attempt)
			and same_source(source, { status = status, content = content })
	end
	local function legacy_external_source(record)
		if type(files.publication_receipt_view) == "function" or not current(record.attempt) then return false end
		local called, content, status = pcall(writer.read_classified, record.path, files, record.on_error)
		return called and status == "ok" and type(content) == "string" and current(record.attempt)
			and content ~= record.candidate and (record.expected.status ~= "ok" or content ~= record.expected.content)
	end
	local function begin()
		if active or pending then return false end
		local called, captured = pcall(options.capture)
		if not called or captured == nil then return false end
		active = { capture = captured }
		if not current(active) then active = nil; return false end
		return true
	end
	local function finish(accepted)
		local attempt = active
		local admitted = attempt ~= nil and current(attempt)
		if admitted and accepted == true and pending and pending.attempt == attempt and pending.acknowledged then
			local lease = pending.native ~= nil and make_lease(pending) or nil
			if pending.native == nil or (lease and lease.matches_source() and lease.is_settled() and current(attempt)) then
				pending = nil
			end
		end
		local finished = admitted and accepted == true and pending == nil and current(attempt)
		active = nil
		return finished
	end
	local function publish(path, candidate, adapter, expected, on_error, publisher)
		local attempt = active
		if not attempt or pending or adapter ~= files or not current(attempt)
			or type(path) ~= "string" or path == "" or type(candidate) ~= "string" or not classified(expected)
			or (on_error ~= nil and type(on_error) ~= "function")
			or (publisher ~= nil and type(publisher) ~= "function") then
			return false, "publication-admission-refused"
		end
		local record = { path = path, candidate = candidate, expected = copy_source(expected),
			on_error = on_error, attempt = attempt, publisher = publisher or writer.publish_if_unchanged }
		-- Reserve the invocation before entering a native callback. Its receipt
		-- must survive false returns and any reentrant consumer revocation.
		pending = record
		local called, acknowledged, detail, native = pcall(record.publisher,
			path, candidate, files, record.expected, on_error)
		record.acknowledged, record.native = called and acknowledged == true, native
		local admitted = current(attempt)
		if native ~= nil then
			local lease = make_lease(record)
			if record.acknowledged and admitted and lease
				and lease.matches_source() and lease.is_settled() and current(attempt) then
				return true, nil, native
			end
		else
			if record.acknowledged and admitted then
				return true
			end
			-- Compatibility publishers cannot issue a recovery lease. A failed
			-- changed image stays closed rather than becoming a no-caps fastpath.
			if admitted and (physical_matches(record, record.expected) or legacy_external_source(record)) then pending = nil end
		end
		return false, called and detail or "native-publication-raised", native
	end
	local function settle_pending()
		local record = pending
		if not current(record.attempt) then return false end
		local forward = make_lease(record)
		if not forward then return false end
		local inverse = record.inverse
		if not inverse then
			if not forward.settle() or not current(record.attempt) then return false end
			local view = forward.view()
			if not view then return false end
			if not view.published then
				if not forward.matches_source() or not current(record.attempt) then return false end
				pending = nil
				return true
			end
			if record.expected.status ~= "ok" then return false end
			inverse = { path = record.path, expected = copy_source(view.source),
				candidate = record.expected.content, on_error = record.on_error, attempt = record.attempt }
			record.inverse = inverse
		end
		if inverse.native ~= nil then
			local owned = make_lease(inverse)
			if not owned or not owned.settle() or not current(record.attempt) then return false end
			local view = owned.view()
			if not view then return false end
			if view.published then
				pending = nil
				return true
			end
			-- Release-only inverse debt still leaves the forward image present.
			-- A new inverse CAS is admitted only after its native release settles.
			inverse.native = nil
		end
		if not forward.matches_source() or not current(record.attempt) then return false end
		local called, acknowledged, detail, native = pcall(record.publisher,
			inverse.path, inverse.candidate, files, inverse.expected, inverse.on_error)
		inverse.acknowledged, inverse.native = called and acknowledged == true, native
		if not current(record.attempt) then return false end
		if native ~= nil then
			local owned = make_lease(inverse)
			if not owned or not owned.settle() or not current(record.attempt) then return false end
			local view = owned.view()
			if view and view.published then pending = nil; return true end
			return false
		end
		if inverse.acknowledged and physical_matches(inverse, record.expected) then
			pending = nil
			return true
		end
		return false
	end
	local function retry()
		if active then return false end
		if not pending then return true end
		active = pending.attempt
		local called, settled = pcall(settle_pending)
		active = nil
		return called and settled == true
	end
	return { begin = begin, finish = finish, publish = publish, retry = retry,
		has_pending = function() return pending ~= nil end }
end

return M
