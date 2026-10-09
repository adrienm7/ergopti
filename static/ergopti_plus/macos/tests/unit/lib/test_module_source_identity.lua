--- tests/unit/lib/test_module_source_identity.lua

--- ==============================================================================
--- MODULE: Canonical Loader Source Coordinates
--- DESCRIPTION:
--- Requires exact constructors on both POSIX and Windows-hosted Lua fixtures.
--- Source coordinates never grant filesystem or configuration authority.
--- ==============================================================================

local helpers = require("tests.helpers")
local owner = require("module_source_identity")

helpers.describe("canonical loader source coordinates", function()
	local function check(label, observed, expected)
		helpers.it(label, function()
			helpers.assert_eq(observed, expected)
		end)
	end
	check('actual Windows drive constructor coordinates', owner.normalize('@C:/repo/shared/toml_codec\\writer.lua'), '@C:/repo/shared/toml_codec/writer.lua')
	check('same normal mixed separator source', owner.same('@C:/repo/shared/config_migrate.lua', '@C:\\repo\\shared\\config_migrate.lua'), true)
	check('exact Windows sibling', owner.sibling('@C:/repo/shared/toml_codec/writer.lua', 'toml_codec/writer.lua', 'config_migrate.lua'), '@C:/repo/shared/config_migrate.lua')
	check('foreign constructor stays refused', owner.same('@C:/foreign/config_migrate.lua', '@C:/repo/shared/config_migrate.lua'), false)
	check('different drive stays refused', owner.same('@D:/repo/shared/config_migrate.lua', '@C:/repo/shared/config_migrate.lua'), false)
	check('case remains exact', owner.same('@c:/repo/shared/config_migrate.lua', '@C:/repo/shared/config_migrate.lua'), false)
	check('drive-relative source unanchored refused', owner.normalize('@C:repo/shared/config_migrate.lua'), nil)
	check('parent traversal above drive root refused', owner.normalize('@C:/../config_migrate.lua'), nil)
	check('parent traversal above POSIX root refused', owner.normalize('@/../config_migrate.lua'), nil)
	check('POSIX normalization preserved', owner.normalize('@/repo/shared/./toml_codec/../config_migrate.lua'), '@/repo/shared/config_migrate.lua')
	check('POSIX relative explicit anchor preserved', owner.normalize('@shared/config_migrate.lua', '/repo'), '@/repo/shared/config_migrate.lua')
	check('non-file source refused', owner.normalize('=caller_supplied'), nil)
	check('NUL source refused', owner.normalize('@C:/repo/\0config_migrate.lua'), nil)
end)
