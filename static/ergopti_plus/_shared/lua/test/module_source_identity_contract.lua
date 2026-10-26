--- _shared/lua/test/module_source_identity_contract.lua
--- ==============================================================================
--- MODULE: Host-Native Loader Source Contract
--- DESCRIPTION:
--- Exact lexical constructor coordinates preserve host filename bytes and never
--- grant authority through native filesystem aliases or guessed directories.
--- ==============================================================================

local M = {}

--- Registers identical source-spelling controls on both Lua drivers.
--- @param helpers table Driver assertion and registration helpers.
function M.register(helpers)
	local owner = require("module_source_identity")
	helpers.describe("canonical loader source coordinates", function()
		local function check(label, windows, observe, expected)
			helpers.it(label, function()
				local before = package.config
				package.config = (windows and "\\" or "/") .. before:sub(2)
				local ok, value = pcall(observe)
				package.config = before
				if not ok then error(value, 0) end
				helpers.assert_eq(value, expected)
			end)
		end
		check('actual Windows drive constructor coordinates', true, function() return owner.normalize('@C:/repo/shared/toml_codec\\writer.lua') end, '@C:/repo/shared/toml_codec/writer.lua')
		check('same normal mixed separator source', true, function() return owner.same('@C:/repo/shared/config_migrate.lua', '@C:\\repo\\shared\\config_migrate.lua') end, true)
		check('exact Windows sibling', true, function() return owner.sibling('@C:/repo/shared/toml_codec/writer.lua', 'toml_codec/writer.lua', 'config_migrate.lua') end, '@C:/repo/shared/config_migrate.lua')
		check('foreign constructor stays refused', true, function() return owner.same('@C:/foreign/config_migrate.lua', '@C:/repo/shared/config_migrate.lua') end, false)
		check('different drive stays refused', true, function() return owner.same('@D:/repo/shared/config_migrate.lua', '@C:/repo/shared/config_migrate.lua') end, false)
		check('case remains exact', true, function() return owner.same('@c:/repo/shared/config_migrate.lua', '@C:/repo/shared/config_migrate.lua') end, false)
		check('drive-relative source unanchored refused', true, function() return owner.normalize('@C:repo/shared/config_migrate.lua') end, nil)
		check('parent traversal above drive root refused', true, function() return owner.normalize('@C:/../config_migrate.lua') end, nil)
		check('parent traversal above POSIX root refused', false, function() return owner.normalize('@/../config_migrate.lua') end, nil)
		check('POSIX normalization preserved', false, function() return owner.normalize('@/repo/shared/./toml_codec/../config_migrate.lua') end, '@/repo/shared/config_migrate.lua')
		check('POSIX relative explicit anchor preserved', false, function() return owner.normalize('@shared/config_migrate.lua', '/repo') end, '@/repo/shared/config_migrate.lua')
		check('non-file source refused', false, function() return owner.normalize('=caller_supplied') end, nil)
		check('NUL source refused', true, function() return owner.normalize('@C:/repo/\0config_migrate.lua') end, nil)
	end)
	local function with_posix(body)
		local previous = package.config
		package.config = "/" .. previous:sub(2)
		local ok, failure = pcall(body)
		package.config = previous
		if not ok then error(failure, 0) end
	end

	helpers.describe("source-identity-posix", function()
		helpers.it("source-identity-posix: relative capture remains idempotent with literal backslash and LF", function()
			with_posix(function()
				local directory = "/owned/name\\\ncomponent"
				local first = owner.normalize("@./shared/../config_migrate.lua", directory)
				helpers.assert_eq(first, "@" .. directory .. "/config_migrate.lua")
				helpers.assert_eq(owner.normalize(first, directory), first)
				helpers.assert_eq(owner.sibling("@./toml_codec/writer.lua", "toml_codec/writer.lua", "config_migrate.lua", directory), first)
				helpers.assert_true(owner.same("@./config_migrate.lua", first, directory))
			end)
		end)
		helpers.it("source-identity-posix: a backslash name never aliases a separated native path", function()
			with_posix(function()
				helpers.assert_eq(owner.normalize("@/owned/name\\part/config.lua"), "@/owned/name\\part/config.lua")
				helpers.assert_eq(owner.same("@/owned/name\\part/config.lua", "@/owned/name/part/config.lua"), false)
				helpers.assert_eq(owner.normalize("@C:/file.lua", "/owned"), "@/owned/C:/file.lua")
			end)
		end)
	end)

end

return M
