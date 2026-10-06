--- modules/llm/ollama_install_admission.lua

--- Native ancestry admission around the exact archive-file owner.
--- Cancellation withdraws mutation authority, while cleanup retains its native
--- identity authority independently of the originating enable ticket.
local M = {}

--- Builds one file owner bound to an immutable resolver and source predicate.
--- @param resolver table Native plan/current/prepare owner.
--- @param factory table Exact native file owner factory exposing new(directory).
--- @param authorized function Captured originating source admission.
--- @param explicit_consent boolean Literal chosen runtime-download consent.
--- @return table|nil owner
--- @return string|nil reason
function M.new(resolver, factory, authorized, explicit_consent)
	if type(resolver) ~= "table" or type(resolver.plan) ~= "function"
		or type(resolver.current) ~= "function" or type(resolver.prepare) ~= "function"
		or type(factory) ~= "table" or type(factory.new) ~= "function" or type(authorized) ~= "function" then
		return nil, "install_ancestry_port_unavailable"
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
	local function current()
		local called, allowed = pcall(authorized)
		if not called or allowed ~= true then return false, "install_source_stale" end
		return ancestry()
	end
	owner.current = current
	local methods = { "prepare", "admit_size", "hash_command", "admit_checksum", "extract_command",
		"admit_extraction", "publish_command", "admit_publication" }
	for _, name in ipairs(methods) do
		local method_name, invoke = name, files[name]
		if type(invoke) ~= "function" then return nil, "install_file_port_unavailable" end
		owner[name] = function(...)
			local admitted, failure = current()
			if not admitted then return nil, failure end
			if method_name == "prepare" then
				if explicit_consent ~= true then return nil, "install_consent_unavailable" end
				local called, ready, parent_reason = pcall(prepare_parent, { explicit_consent = true, authorized = current })
				if not called or ready ~= true then return nil, parent_reason or "install_parent_admission_refused" end
				admitted, failure = current()
				if not admitted then return nil, failure end
			end
			local value, detail = invoke(...)
			owner.published = files.published == true
			admitted, failure = current()
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
		owner.published = files.published == true
		if cleaned == true then return true end
		return false, "install_file_cleanup_refused"
	end
	return owner
end

return M
