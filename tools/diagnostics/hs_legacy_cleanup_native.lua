-- tools/diagnostics/hs_legacy_cleanup_native.lua
-- Private-file production cleanup acceptance. No user backup, UI or lease proof.
local M = {}

local function read(path)
	local file = assert(io.open(path, "rb"))
	local content = assert(file:read("*a"))
	assert(file:close())
	return content
end

local function write(path, content)
	local file = assert(io.open(path, "wb"))
	assert(file:write(content))
	assert(file:close())
end

local function equal(first, second)
	if type(first) ~= type(second) then return false end
	if type(first) ~= "table" then return first == second end
	for key, value in pairs(first) do if not equal(value, second[key]) then return false end end
	for key in pairs(second) do if first[key] == nil then return false end end
	return true
end

local function backups(directory)
	local found = {}
	for name in hs.fs.dir(directory) do
		if name:match("%.bak$") then found[#found + 1] = directory .. "/" .. name end
	end
	table.sort(found)
	return found
end

--- Loads the real production catalogue/context without initializing a bridge.
--- @param data string Current production data directory.
--- @return table context Validated production generator context.
function M.context(data)
	local Config = require("platform.remap.config")
	local Generator = require("platform.remap.generator")
	local actions = assert(Config.load_available_actions(data .. "actions.json"))
	local keys = assert(Config.load_tap_hold_keys(data .. "tap_hold_keys.json"))
	local combos = assert(Config.load_mod_combos(data .. "mod_combos.json"))
	local state = Config.build_default_state(keys, combos)
	local generated, detail, _, context = Generator.build_karabiner_json(state, actions, keys,
		combos, Config.compute_non_canonical_combos(combos), data,
		"0123456789abcdef0123456789abcdef")
	assert(generated and type(context) == "table", tostring(detail))
	return context
end

--- Executes one frozen case with actual files and captured production methods.
--- Interleaving wrappers model scheduling only; each genuine adapter still runs.
--- @param directory string Fresh owned ordinary case directory.
--- @param corpus table Independently handwritten immutable expectations.
--- @param id string Exact scenario identity.
--- @param context table Actual production generator context.
--- @return table result Closed case receipt; exceptions refuse the whole case.
function M.run_case(directory, corpus, id, context)
	local FileSystem = require("adapters.file_system")
	local Codec = require("adapters.json_codec")
	local Generator = require("platform.remap.generator")
	local Removal = require("platform.remap.managed_rule_removal")
	local destination = directory .. "/karabiner.json"
	local original = id == "invalid_original_refuses" and corpus.invalid_original or corpus.original
	write(destination, original)
	local before = backups(directory)
	assert(#before == 0, "Case must own a fresh backup namespace")
	local saved_create, saved_publish = FileSystem.create_if_absent, FileSystem.write_if_unchanged
	local observed_backup, boundary_calls, publication_calls = nil, 0, 0
	local function perform()
		if id ~= "invalid_original_refuses" then
			local conflicts = assert(Generator.find_legacy_signature_conflicts(
				assert(Codec.decode(read(destination))), context))
			assert(equal(conflicts, corpus.expected_conflicts), "Frozen conflict locations/reasons differ")
		end
		if id == "existing_backup_name" or id == "backup_readback_changed" then
			FileSystem.create_if_absent = function(path, bytes, ...)
				boundary_calls = boundary_calls + 1
				assert(bytes == original and path:sub(1, #destination + 1) == destination .. ".")
				observed_backup = path
				if id == "existing_backup_name" then write(path, corpus.backup_collision) end
				local result = table.pack(saved_create(path, bytes, ...))
				if id == "backup_readback_changed" then
					assert(result[1] == true, "Actual create-only backup did not complete")
					write(path, corpus.backup_altered)
				end
				return table.unpack(result, 1, result.n)
			end
		end
		FileSystem.write_if_unchanged = function(path, bytes, expected, ...)
			publication_calls = publication_calls + 1
			assert(path == destination and expected.status == "ok" and expected.content == original)
			if id == "stale_destination_after_verified_backup" then
				local list = backups(directory)
				assert(#list == 1 and read(list[1]) == original, "Actual original backup must precede edit")
				boundary_calls = boundary_calls + 1
				write(destination, corpus.foreign_edit)
			end
			return saved_publish(path, bytes, expected, ...)
		end
		return table.pack(Removal.remove_legacy_rules(destination, context))
	end
	local protected = table.pack(xpcall(perform, debug.traceback))
	FileSystem.create_if_absent, FileSystem.write_if_unchanged = saved_create, saved_publish
	assert(FileSystem.create_if_absent == saved_create and FileSystem.write_if_unchanged == saved_publish)
	if protected[1] ~= true then error(protected[2], 0) end
	-- Outcome, callback facts and actual retained bytes are asserted after unwind.
	local outcome = protected[2]
	local list = backups(directory)
	if id == "remove_two_signature_conflicts" or id == "unchanged_second_request" then
		assert(outcome[1] == true and outcome[2] == "removed" and outcome[3] == 2, tostring(outcome[2]))
		assert(type(outcome[4]) == "string" and #list == 1 and outcome[4] == list[1])
		assert(read(list[1]) == original and publication_calls == 1)
		local retained = read(destination)
		assert(equal(assert(Codec.decode(retained)), assert(Codec.decode(corpus.expected_retained))))
		for _, span in pairs(corpus.foreign_rules) do
			assert(retained:find(span, 1, true), "Original foreign rule bytes were changed")
		end
		assert(#assert(Generator.find_legacy_signature_conflicts(assert(Codec.decode(retained)), context)) == 0)
		if id == "unchanged_second_request" then
			local repeated = table.pack(Removal.remove_legacy_rules(destination, context))
			assert(repeated[1] == true and repeated[2] == "unchanged" and repeated[3] == 0 and repeated[4] == nil)
			assert(read(destination) == retained and read(list[1]) == original)
			assert(equal(backups(directory), list), "No second backup may be invented")
		end
	elseif id == "stale_destination_after_verified_backup" then
		assert(outcome[1] == false and outcome[3] == 0 and type(outcome[4]) == "string", tostring(outcome[2]))
		assert(boundary_calls == 1 and publication_calls == 1 and #list == 1)
		assert(read(destination) == corpus.foreign_edit and outcome[4] == list[1] and read(list[1]) == original)
	elseif id == "existing_backup_name" or id == "backup_readback_changed" then
		assert(outcome[1] == false and outcome[3] == 0 and outcome[4] == nil)
		assert(boundary_calls == 1 and publication_calls == 0 and #list == 1 and list[1] == observed_backup, tostring(outcome[2]))
		assert(read(destination) == original)
		assert(read(list[1]) == (id == "existing_backup_name" and corpus.backup_collision or corpus.backup_altered))
	elseif id == "invalid_original_refuses" then
		assert(outcome[1] == false and outcome[3] == 0 and outcome[4] == nil)
		assert(publication_calls == 0 and #list == 0 and read(destination) == original)
	else
		error("Unknown frozen cleanup scenario", 0)
	end
	return { id = id, passed = true }
end

return M
