--- _shared/lua/file_system/ports.lua

--- ==============================================================================
--- MODULE: FileSystem Port Spec — Lease and Atomic Write
--- DESCRIPTION:
--- What a driver's file-system owner (adapters/file_system.lua) must offer
--- besides the five plain operations that FileSystem.spec.js pins by arity: the
--- classified read, the publication that refuses a source that changed since it
--- was read, the optional conditional removal, the write lease and the
--- publication receipts. The configuration migration, the writers and the
--- recovery journals call these by name; a missing one used to surface as a
--- nil call deep inside a transaction.
---
--- FEATURES & RATIONALE:
--- 1. Required methods (FileSystem) and optional capabilities (ConditionalRemoval,
---    WriteLease, PublicationReceipts) are listed with the signature callers
---    rely on. `check` raises on a missing required method; `check_capabilities`
---    raises on a capability offered by halves, because a caller that finds the
---    first method assumes the second.
--- 2. The atomic write is a contract, not a mechanism: macOS publishes under
---    cooperative write locks and a receipt chain; Linux publishes through
---    toml_codec.writer inside the single-threaded daemon, so it holds no lease
---    and issues no receipt. Absence is a capability the caller branches on.
--- 3. Seen by the Windows port as a reading list: the AHK FileSystem owner is
---    to offer the same required names once the PC adopts the spec.
---
--- Pinned by file_system_ports_contract (corpus file_system/port_vectors.json)
--- and by the real owners of both Lua drivers.
--- ==============================================================================

local TableUtil = require("table_util")

local M = {}

--- Methods every owner offers.
M.CONTRACTS = {
	FileSystem = {
		read = "read(path) -> string|nil: exact bytes, nil on any failure.",
		write = "write(path, content) -> boolean: replaces the file.",
		append = "append(path, content) -> boolean: appends, creating the file.",
		exists = "exists(path) -> boolean: metadata only, no readable stream needed.",
		delete = "delete(path) -> boolean: true when removed or already absent.",
		read_with_status = "read_with_status(path, on_error) -> content|nil, status, detail: a classified "
			.. "source (present, absent, unreadable) the publication can later be conditioned on.",
		write_if_unchanged = "write_if_unchanged(path, content, expected, on_error) -> committed, detail: "
			.. "atomic replacement, refused when the file no longer matches the classified `expected` source.",
		write_if_unchanged_admitted = "write_if_unchanged_admitted(path, content, expected, on_error, admission) "
			.. "-> committed, detail: the same publication with a final logical admission checked just before commit.",
		configuration_ports = "configuration_ports() -> owner, reader, writer, publisher, remover, "
			.. "admitted_remover, exact_remover, delete, ...: the owner's own method identities, without IO.",
	},
}

--- Optional capabilities: an owner offers every method of one, or none.
M.CAPABILITIES = {
	ConditionalRemoval = {
		remove_if_unchanged = "remove_if_unchanged(path, expected_source, on_error, admission) -> removed, detail.",
		remove_if_unchanged_admitted = "remove_if_unchanged_admitted(path, expected_source, on_error, admission) "
			.. "-> removed, detail: the removal with a final logical admission.",
		remove_exact = "remove_exact(path) -> removed, detail: removes only the exact file it classified.",
	},
	WriteLease = {
		acquire_write_locks = "acquire_write_locks(paths) -> group|nil, acquired|err: a lease on every path, "
			.. "or none of them.",
		release_write_locks = "release_write_locks(group) -> boolean: returns a lease; the lock file stays.",
	},
	PublicationReceipts = {
		publication_receipt_view = "publication_receipt_view(receipt, path, expected, candidate, on_error) "
			.. "-> view|nil: reads an opaque receipt the owner issued.",
		publication_receipt_chain_restore = "publication_receipt_chain_restore(previous, forward, inverse) "
			.. "-> receipt|nil: the exact rename-inverse lineage of a publication.",
	},
}

local function missing_methods(contract, owner)
	local missing = {}
	for method in pairs(contract) do
		if type(owner[method]) ~= "function" then missing[#missing + 1] = method end
	end
	table.sort(missing)
	return missing
end




-- =================================
-- =================================
-- ======= 1/ Public API ===========
-- =================================
-- =================================

--- Checks that an owner offers every required method.
--- @param port_name string "FileSystem".
--- @param owner table The driver's file-system owner.
--- @return table owner The same owner, for chaining.
function M.check(port_name, owner)
	local contract = M.CONTRACTS[port_name]
	if contract == nil then error("unknown port: " .. tostring(port_name), 2) end
	if type(owner) ~= "table" then error(port_name .. " must be a table", 2) end
	local missing = missing_methods(contract, owner)
	if #missing > 0 then error(port_name .. " lacks: " .. table.concat(missing, ", "), 2) end
	return owner
end

--- Names the optional capabilities an owner offers completely, and refuses one
--- it offers by halves.
--- @param owner table The driver's file-system owner.
--- @return string[] offered Sorted capability names.
function M.check_capabilities(owner)
	if type(owner) ~= "table" then error("FileSystem must be a table", 2) end
	local offered = {}
	for name, contract in pairs(M.CAPABILITIES) do
		local missing = missing_methods(contract, owner)
		if #missing == 0 then
			offered[name] = true
		elseif #missing < TableUtil.count(contract) then
			error(name .. " is offered by halves, it lacks: " .. table.concat(missing, ", "), 2)
		end
	end
	return TableUtil.sorted_keys(offered)
end

--- Checks an owner completely: required methods, then capabilities.
--- @param owner table The driver's file-system owner.
--- @return string[] offered The capabilities it offers.
function M.check_owner(owner)
	M.check("FileSystem", owner)
	return M.check_capabilities(owner)
end

return M
