--- tests/support/modules/updater/storage_isolation.lua

--- ==============================================================================
--- MODULE: Updater Receiving Fixture Storage Isolation
--- DESCRIPTION:
--- A warmed real storage owner must remain writable after the actual receiving
--- scenario temporarily replaces the TOML writer. Every file belongs to this
--- fixture; no native transport, installer or user configuration is exercised.
--- ==============================================================================

local M = {}
local helpers = require("tests.helpers")
local uv = require("luv")

--- Checks the public storage API after one actual updater fixture lifetime.
--- @param scenario function The receiving module's own scenario helper.
function M.check(scenario)
	-- Storage resolves these constructors lazily; load their transitive owners
	-- before routing the one private store so none can capture this fixture.
	require("adapters.storage")
	require("toml_codec.writer")
	require("config_file_inverse")
	local paths_name, storage_name = "infra.config_paths", "adapters.storage"
	local previous_paths, previous_storage = package.loaded[paths_name], package.loaded[storage_name]
	local directory = assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-updater-storage-XXXXXX"))
	local path = directory .. "/ergopti_plus/storage.json"
	local paths = {}
	for key, value in pairs(previous_paths) do paths[key] = value end
	paths.config_home = function() return directory end
	package.loaded[paths_name], package.loaded[storage_name] = paths, nil
	local ok, err = pcall(function()
		local storage = require(storage_name)
		helpers.assert_eq(storage.path(), path)
		scenario({}, function() end)
		helpers.assert_true(rawequal(package.loaded[storage_name], storage), "the exact warmed owner is restored")
		helpers.assert_eq(storage.set("receiving_fixture_sentinel", "kept"), true,
			"a receiving scenario must not memoize its fake writer in the real storage owner")
		local file = assert(io.open(path, "rb"))
		local bytes = assert(file:read("*a")); assert(file:close())
		helpers.assert_eq(require("json").decode(bytes).receiving_fixture_sentinel, "kept")
		helpers.assert_eq(storage.get("receiving_fixture_sentinel"), "kept")
	end)
	package.loaded[paths_name], package.loaded[storage_name] = previous_paths, previous_storage
	for _, suffix in ipairs({ ".tmp", ".corrupt", "" }) do
		if uv.fs_lstat(path .. suffix) then assert(os.remove(path .. suffix)) end
	end
	if uv.fs_lstat(directory .. "/ergopti_plus") then assert(uv.fs_rmdir(directory .. "/ergopti_plus")) end
	assert(uv.fs_rmdir(directory))
	if not ok then error(err, 0) end
end

return M
