--- ai/engine/ollama/install_admission.lua

--- Native ancestry admission around the exact archive-file owner.
--- Cancellation withdraws mutation authority, while cleanup retains its native
--- identity authority independently of the originating enable ticket.
local M = {}

--- Builds one file owner bound to an immutable resolver and source predicate.
--- @param resolver table Native plan/current/prepare owner.
--- @param factory table Exact native file owner factory exposing new(directory).
--- @param authorized function Captured originating source admission.
--- @param explicit_consent boolean Literal chosen runtime-download consent.
--- @param reuse table|nil { window_ms, now_ms }: how long one admitted ancestor
---   walk answers current() ([llm] install_ancestry_reuse_ms) and the monotonic
---   clock that dates it. Absent, every current() walks the ancestors.
--- @return table|nil owner
--- @return string|nil reason
function M.new(resolver, factory, authorized, explicit_consent, reuse)
	if type(resolver) ~= "table" or type(resolver.plan) ~= "function"
		or type(resolver.current) ~= "function" or type(resolver.prepare) ~= "function"
		or type(factory) ~= "table" or type(factory.new) ~= "function" or type(authorized) ~= "function" then
		return nil, "install_ancestry_port_unavailable"
	end
	local window_ms, now_ms = nil, nil
	if reuse ~= nil then
		if type(reuse) ~= "table" or type(reuse.window_ms) ~= "number" or reuse.window_ms < 0
			or reuse.window_ms ~= reuse.window_ms or type(reuse.now_ms) ~= "function" then
			return nil, "install_ancestry_reuse_invalid"
		end
		window_ms, now_ms = reuse.window_ms, reuse.now_ms
	end
	local get_plan, check_path, prepare_parent = resolver.plan, resolver.current, resolver.prepare
	local planned, plan = pcall(get_plan)
	if not planned or type(plan) ~= "table" or type(plan.directory) ~= "string" then return nil, "install_plan_unavailable" end
	local directory = plan.directory
	local created, files, reason = pcall(factory.new, directory)
	if not created or type(files) ~= "table" then return nil, reason or "install_file_port_unavailable" end
	if files.directory ~= directory then return nil, "install_file_owner_mismatch" end
	local cleanup = files.cleanup
	if type(cleanup) ~= "function" then return nil, "install_file_port_unavailable" end
	local owner = { directory = directory, published = false }
	local function ancestry()
		local called, allowed, failure = pcall(check_path)
		return called and allowed == true, failure or "install_ancestor_substituted"
	end
	-- A download chunk re-admits this owner about 14 times from separate
	-- callbacks (write acknowledgement, output lease, curl reader), each walk one
	-- lstat per ancestor (about 1.5 ms per chunk on the maintainer's PC). An
	-- admitted walk answers current() for window_ms only; a refusal is never
	-- kept, and every mutation below walks again before and after it.
	local admitted_at = nil
	local function forget() admitted_at = nil end
	local function reused_ancestry()
		if not window_ms then return ancestry() end
		local read, now = pcall(now_ms)
		if not read or type(now) ~= "number" then forget(); return false, "install_ancestry_clock_unavailable" end
		if admitted_at and now >= admitted_at and now - admitted_at <= window_ms then return true end
		local allowed, failure = ancestry()
		admitted_at = allowed and now or nil
		return allowed, failure
	end
	local function current()
		local called, allowed = pcall(authorized)
		if not called or allowed ~= true then return false, "install_source_stale" end
		return reused_ancestry()
	end
	local function fresh()
		forget()
		return current()
	end
	owner.current = current
	local methods = { "prepare", "admit_size", "hash_command", "admit_checksum", "extract_command",
		"admit_extraction", "publish_command", "admit_publication" }
	-- Existing injected predecessor controls stay unchanged. The actual native
	-- files factory exposes all three retained methods; partial support refuses.
	if files.prepare_retained ~= nil or files.retained_stage ~= nil or files.admit_retained_extraction ~= nil then
		for _, name in ipairs({ "prepare_retained", "retained_stage", "admit_retained_extraction" }) do methods[#methods + 1] = name end
	end
	for _, name in ipairs(methods) do
		local method_name, invoke = name, files[name]
		if type(invoke) ~= "function" then return nil, "install_file_port_unavailable" end
		owner[name] = function(...)
			local admitted, failure = fresh()
			if not admitted then return nil, failure end
			if method_name == "prepare" or method_name == "prepare_retained" then
				if explicit_consent ~= true then return nil, "install_consent_unavailable" end
				local called, ready, parent_reason = pcall(prepare_parent, { explicit_consent = true, authorized = fresh })
				if not called or ready ~= true then return nil, parent_reason or "install_parent_admission_refused" end
				admitted, failure = fresh()
				if not admitted then return nil, failure end
			end
			local value, detail = invoke(...)
			owner.published = files.published == true
			admitted, failure = fresh()
			if not admitted then return nil, failure end
			return value, detail
		end
	end

	--- Removes only file-owner paths after external operation retirement.
	--- Source cancellation cannot revoke captured private cleanup authority.
	--- @return boolean acknowledged
	--- @return string|nil reason
	function owner.cleanup()
		local admitted, failure = ancestry()
		if not admitted then return false, failure end
		local cleaned = cleanup()
		forget()
		owner.published = files.published == true
		if cleaned == true then return true end
		return false, "install_file_cleanup_refused"
	end
	return owner
end

return M
