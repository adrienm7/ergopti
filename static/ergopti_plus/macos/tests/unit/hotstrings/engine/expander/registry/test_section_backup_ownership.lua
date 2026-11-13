--- tests/unit/hotstrings/engine/expander/registry/test_section_backup_ownership.lua
--- A section settings backup may never be removed based on matching bytes alone.
local helpers = require("tests.helpers")
local Fixture = require("tests.support.hotstrings.registry_mutation_transactions_fixture")

local function scenario(collision)
	local _, registry = Fixture.fresh_registry()
	registry.register_lua_group("owned", "Owned", { { name = "section" } })
	local storage = require("core.fs.adapters.storage")
	local key = registry.section_setting_key("owned", "section")
	helpers.assert_true(storage.set(key, false))
	local original_files = package.loaded["core.fs.adapters.file_system"]
	local entries, writes, deletes, backup_path = {}, 0, 0, nil
	local files = {}
	function files.read_with_status(path)
		local entry = entries[path]
		return entry and entry.bytes or nil, entry and "ok" or "absent"
	end
	function files.write_if_unchanged(path, bytes, expected)
		writes = writes + 1
		backup_path = path
		if expected.status ~= "absent" or entries[path] ~= nil then return false end
		if collision then
			-- Another owner wins after the absence read, with identical bytes.
			entries[path] = { bytes = bytes, identity = "foreign" }
			return false
		end
		entries[path] = { bytes = bytes, identity = "ours" }
		return true
	end
	function files.remove_if_unchanged(path)
		deletes = deletes + 1
		entries[path] = nil
		return true
	end
	package.loaded["core.fs.adapters.file_system"] = files
	local original_release = storage.release_owned
	storage.release_owned = function(...)
		if not collision and backup_path and entries[backup_path] then
			-- Model an ABA replacement: identical content, different owner.
			entries[backup_path] = { bytes = entries[backup_path].bytes, identity = "foreign" }
		end
		return original_release(...)
	end
	local ok, err = xpcall(function()
		local committed = registry.set_sections_enabled("owned", { "section" }, true)
		helpers.assert_eq(committed, not collision)
		helpers.assert_true(writes > 0, "the backup creation was attempted")
		helpers.assert_true(backup_path ~= nil and entries[backup_path] ~= nil)
		helpers.assert_eq(entries[backup_path].identity, "foreign")
		helpers.assert_eq(deletes, 0, "matching bytes do not authorize deleting another owner's file")
		helpers.assert_eq(registry.is_section_enabled("owned", "section"), not collision)
	end, debug.traceback)
	storage.release_owned = original_release
	package.loaded["core.fs.adapters.file_system"] = original_files
	if not ok then error(err, 0) end
end

helpers.describe("section backup pathname ownership", function()
	helpers.it("preserves an identical file that wins exclusive creation", function() scenario(true) end)
	helpers.it("preserves an identical replacement after an owned publication", function() scenario(false) end)
end)
