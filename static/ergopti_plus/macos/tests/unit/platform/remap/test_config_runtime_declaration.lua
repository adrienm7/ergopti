--- tests/unit/platform/remap/test_config_runtime_declaration.lua

--- ==============================================================================
--- MODULE: Native Runtime Declaration Admission
--- DESCRIPTION:
--- Fixed JSON controls reject malformed declarations and prove defaults belong
--- to shared data rather than native enum literals. No runtime is activated.
--- ==============================================================================

local helpers = require("tests.helpers")

local DECLARATION = [[{"$schema":"./runtime_setting.schema.json","path":"karabiner.runtime","file":"config_karabiner.toml","owner":"platform.remap.config","platforms":["hs"],"type":"enum","enum_values":["shared","owned"],"default":"shared","recommended":"shared","description_key":"menu.global.karabiner_runtime","unavailable_key":"menu.global.karabiner_runtime_unavailable"}]]

--- Reads the actual native owner against one exact private declaration image.
--- @param bytes string|nil Fixed declaration bytes; nil means missing source.
--- @param body function Receives owner and private source read controls.
local function with_declaration(bytes, body)
	helpers.with_stub_scope({ "platform.remap.config", "adapters.file_system", "infra.paths" }, function()
		local config = helpers.load_with_stubs("platform.remap.config")
		local path = os.tmpname()
		if bytes then
			local file = assert(io.open(path, "wb")); assert(file:write(bytes)); assert(file:close())
		else os.remove(path) end
		local paths = require("infra.paths")
		local resolve = paths.shared
		paths.shared = function(relative)
			if relative == "platform/remap/runtime_setting.json" then return path end
			return resolve(relative)
		end
		local files = require("adapters.file_system")
		local reader, writer = files.read_with_status, files.write_if_unchanged
		local writes = 0
		files.read_with_status = function() return "", "ok" end
		files.write_if_unchanged = function() writes = writes + 1; return true end
		local ok, err = pcall(body, config, function() return writes end)
		paths.shared, files.read_with_status, files.write_if_unchanged = resolve, reader, writer
		os.remove(path)
		if not ok then error(err, 0) end
	end)
end

helpers.describe("native runtime declaration admission", function()
	for _, control in ipairs({
		{ name = "missing declaration" },
		{ name = "malformed JSON", bytes = "{" },
		{ name = "wrong destination", bytes = DECLARATION:gsub('"config_karabiner.toml"', '"config.toml"') },
		{ name = "foreign owner", bytes = DECLARATION:gsub('"platform.remap.config"', '"future.owner"') },
		{ name = "unexpected platform", bytes = DECLARATION:gsub('%["hs"%]', '["hs","linux"]') },
		{ name = "unknown declared field", bytes = DECLARATION:gsub('}$', ',"installed":true}') },
		{ name = "duplicate values", bytes = DECLARATION:gsub('%["shared","owned"%]', '["shared","shared"]') },
		{ name = "unknown default", bytes = DECLARATION:gsub('"default":"shared"', '"default":"future"') },
		{ name = "unknown recommended", bytes = DECLARATION:gsub('"recommended":"shared"', '"recommended":"future"') },
		{ name = "wrong description route", bytes = DECLARATION:gsub('"menu.global.karabiner_runtime"', '"future.caption"') },
		{ name = "wrong unavailable route", bytes = DECLARATION:gsub('"menu.global.karabiner_runtime_unavailable"', '"future.reason"') },
	}) do
		helpers.it("refuses " .. control.name .. " before native admission", function()
			with_declaration(control.bytes, function(config, writes)
				local state, status = config.load_user_config({}, {}, "declaration-remap.toml")
				helpers.assert_nil(state)
				helpers.assert_eq(status, "error")
				helpers.assert_eq(writes(), 0)
			end)
		end)
	end
	helpers.it("reads defaults from the declaration without native activation", function()
		local bytes = DECLARATION:gsub('"default":"shared"', '"default":"owned"')
			:gsub('"recommended":"shared"', '"recommended":"owned"')
		with_declaration(bytes, function(config, writes)
			local state, status = config.load_user_config({}, {}, "declaration-remap.toml")
			helpers.assert_eq(status, "ok")
			helpers.assert_eq(state.runtime, "owned")
			helpers.assert_eq(config.build_recommended_state({}, {}).runtime, "owned")
			helpers.assert_eq(writes(), 0)
		end)
	end)
end)

return true
