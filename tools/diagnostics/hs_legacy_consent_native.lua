-- tools/diagnostics/hs_legacy_consent_native.lua
-- Actual disposable files and production adapters; owner/interleavings are modeled.
local M = {}

local function read(path)
	local file = assert(io.open(path, "rb"))
	local bytes = assert(file:read("*a"))
	assert(file:close())
	return bytes
end

local function write(path, bytes)
	local file = assert(io.open(path, "wb"))
	assert(file:write(bytes))
	assert(file:close())
end

local function backups(directory)
	local result = {}
	for name in hs.fs.dir(directory) do
		if name:match("%.bak$") then result[#result + 1] = directory .. "/" .. name end
	end
	table.sort(result)
	return result
end

local function input(corpus, oracle, name)
	if name == "absent" then return nil end
	local variant = oracle.input_variants[name]
	if variant then return assert(corpus[variant.base_ref]) .. variant.append end
	return assert(corpus[name], "Unknown frozen input reference")
end

--- Run one frozen case with genuine Hammerspoon JSON, IO, backup and CAS.
--- The predicate and interleaving wrappers model owner timing only. No bridge,
--- one-use token, UI, input, installation or original user backup is qualified.
function M.run_case(directory, corpus, oracle, id, context)
	local row
	for _, candidate in ipairs(oracle.cases) do
		if candidate.id == id then assert(row == nil); row = candidate end
	end
	assert(row and oracle.schema == 1, "Unknown or ambiguous frozen consent case")
	local FS = require("adapters.file_system")
	local Generator = require("platform.remap.generator")
	local Removal = require("platform.remap.managed_rule_removal")
	local destination = directory .. "/karabiner.json"
	local original = input(corpus, oracle, row.initial_ref)
	if original ~= nil then write(destination, original) end
	assert(#backups(directory) == 0, "Case needs an exclusive fresh backup namespace")
	local expected, event = row.expect, row.interleaving
	local saved_read, saved_create, saved_publish = FS.read_with_status, FS.create_if_absent, FS.write_if_unchanged
	local saved_classify = Generator.find_legacy_signature_conflicts
	local current = event ~= "expired_before_read"
	local boundary = event == "current" or event == "expired_before_read"
	local destination_reads, creates, publications, current_checks = 0, 0, 0, 0
	local created_backup
	local function perform()
		FS.read_with_status = function(path, ...)
			if path == destination then destination_reads = destination_reads + 1 end
			local result = table.pack(saved_read(path, ...))
			if event == "expire_after_actual_destination_read" and path == destination then
				assert(result[2] == "ok" and result[1] == original)
				current, boundary = false, true
			elseif event == "expire_after_actual_backup_readback" and path == created_backup then
				assert(result[2] == "ok" and result[1] == original)
				current, boundary = false, true
			end
			return table.unpack(result, 1, result.n)
		end
		Generator.find_legacy_signature_conflicts = function(...)
			local result = table.pack(saved_classify(...))
			if event == "expire_after_actual_classification" then
				assert(type(result[1]) == "table" and #result[1] == 2)
				current, boundary = false, true
			end
			return table.unpack(result, 1, result.n)
		end
		FS.create_if_absent = function(path, bytes, ...)
			creates = creates + 1
			assert(bytes == original and path:sub(1, #destination + 1) == destination .. ".")
			local result = table.pack(saved_create(path, bytes, ...))
			assert(result[1] == true, "Actual create-only backup refused")
			created_backup = path
			return table.unpack(result, 1, result.n)
		end
		FS.write_if_unchanged = function(path, bytes, confirmed, ...)
			publications = publications + 1
			assert(path == destination and confirmed.status == "ok" and confirmed.content == original)
			if event == "current_external_write_before_actual_CAS" then
				local files = backups(directory)
				assert(#files == 1 and read(files[1]) == original)
				write(destination, corpus.foreign_edit)
				boundary = true
			end
			return saved_publish(path, bytes, confirmed, ...)
		end
		local function predicate()
			current_checks = current_checks + 1
			if event == "callback_raises" then boundary = true; error("Frozen owner callback refusal") end
			if event == "callback_returns_one" then boundary = true; return 1 end
			return current
		end
		return table.pack(Removal.remove_legacy_rules(destination, context,
			{ status = "ok", content = input(corpus, oracle, row.confirmed_ref) }, predicate))
	end
	local protected = table.pack(xpcall(perform, debug.traceback))
	FS.read_with_status, FS.create_if_absent, FS.write_if_unchanged = saved_read, saved_create, saved_publish
	Generator.find_legacy_signature_conflicts = saved_classify
	assert(FS.read_with_status == saved_read and FS.create_if_absent == saved_create
		and FS.write_if_unchanged == saved_publish and Generator.find_legacy_signature_conflicts == saved_classify)
	if protected[1] ~= true then error(protected[2], 0) end
	local outcome, files = protected[2], backups(directory)
	assert(outcome[1] == expected.ok and outcome[3] == expected.removed, tostring(outcome[2]))
	assert(type(outcome[2]) == "string")
	if expected.detail:sub(1, 7) == "prefix:" then
		local prefix = expected.detail:sub(8)
		assert(outcome[2]:sub(1, #prefix) == prefix, outcome[2])
	else
		assert(outcome[2] == expected.detail, outcome[2])
	end
	assert(#files == expected.backup_files and creates == expected.backup_files)
	assert(publications == expected.publication_calls)
	assert((outcome[4] ~= nil) == expected.backup_returned)
	local retained = input(corpus, oracle, expected.destination_ref)
	local exists = hs.fs.attributes(destination) ~= nil
	assert(exists == (retained ~= nil))
	local actual_destination = exists and read(destination) or ""
	assert(actual_destination == (retained or ""), "Destination bytes differ from frozen oracle")
	local actual_backup = ""
	if expected.backup_ref ~= nil then
		assert(#files == 1 and outcome[4] == files[1])
		actual_backup = read(files[1])
		assert(actual_backup == input(corpus, oracle, expected.backup_ref), "Backup bytes differ from original")
	end
	if id == "owner_stale_before_read" or id == "owner_callback_raises" or id == "owner_callback_nontrue" then
		assert(destination_reads == 0, "Expired owner must refuse before actual destination read")
	end
	assert(boundary, "The specified actual boundary did not run")
	assert(current_checks > 0, "Confirmed-source path must invoke its owner predicate")
	return { id = id, passed = true }, {
		id = id, ok = outcome[1], detail = outcome[2], removed = outcome[3],
		backup_files = #files, publication_calls = publications, backup_returned = outcome[4] ~= nil,
		destination_exists = exists, destination_bytes = actual_destination, backup_bytes = actual_backup,
		destination_reads = destination_reads, current_checks = current_checks,
		boundary_reached = boundary, methods_restored = true, owner_modeled = true,
	}
end

return M
