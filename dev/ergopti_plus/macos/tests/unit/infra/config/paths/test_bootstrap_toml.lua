--- tests/unit/infra/config/paths/test_bootstrap_toml.lua

--- ==============================================================================
--- MODULE: Bootstrap TOML Admission
--- DESCRIPTION:
--- Drives the real path resolver against private files. The classified file port
--- performs real reads and publications; directory probes use LuaFileSystem.
--- Comments belong to TOML syntax and must never erase a configured directory.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"infra.config_paths", "infra.logger", "adapters.file_system", "infra.text_utils",
	"text_utils", "app_dirs", "infra.log_folders", "lfs", "infra.toml.codec",
	"toml_codec", "toml_codec.codec", "toml_codec.record_scanner", "toml_codec.key_path",
	"toml_codec.bom", "toml_codec.basic_string", "compat.utf8",
}

local function read_file(path)
	local handle = assert(io.open(path, "rb"))
	local content = assert(handle:read("*a"))
	assert(handle:close())
	return content
end

local function write_file(path, content)
	local handle = assert(io.open(path, "wb"))
	assert(handle:write(content))
	assert(handle:close())
end

--- Releases only the private tree, including directories the real resolver made.
local function remove_tree(fs, root)
	for name in fs.dir(root) do
		if name ~= "." and name ~= ".." then
			local path = root .. "/" .. name
			if fs.attributes(path, "mode") == "directory" then remove_tree(fs, path)
			else assert(os.remove(path)) end
		end
	end
	assert(fs.rmdir(root))
end

--- Preserves the process cache, environment accessor and native globals on error.
local function fixture(callback)
	local previous_hs, previous_lfs, previous_getenv = rawget(_G, "hs"), rawget(_G, "lfs"), os.getenv
	local fs, root
	local ok, detail = xpcall(function()
		helpers.with_fresh_modules(OWNED_MODULES, function()
			rawset(_G, "lfs", nil)
			fs = require("lfs")
			root = os.tmpname()
			assert(os.remove(root))
			assert(fs.mkdir(root))
			local state = { root = root, file = root .. "/paths.toml", writes = 0 }
			state.codec = require("infra.toml.codec")
			state.config = root .. "/config/"
			state.logs = root .. "/logs/ergopti_plus/"
			state.line = function(key, value)
				return key .. " = " .. state.codec.encode_value(value)
			end
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["adapters.file_system"] = {
				read_with_status = function(path)
					if fs.attributes(path, "mode") == nil then return nil, "absent" end
					return read_file(path), "ok"
				end,
				write_if_unchanged = function(path, content, expected)
					assert(read_file(path) == expected.content, "unexpected bootstrap conflict")
					write_file(path, content)
					state.writes = state.writes + 1
					return true
				end,
				create_if_absent = function() error("existing bootstrap must not be recreated") end,
			}
			_G.hs = { fs = { attributes = fs.attributes, mkdir = fs.mkdir },
				execute = function() error("real directory ports must not need a shell") end }
			os.getenv = function(name)
				if name == "HOME" then return root end
				if name == "ERGOPTI_PATHS_FILE" then return state.file end
				return previous_getenv(name)
			end
			state.load = function(content)
				if content ~= nil then write_file(state.file, content) end
				package.loaded["infra.config_paths"] = nil
				return require("infra.config_paths")
			end
			callback(state)
		end)
	end, debug.traceback)
	os.getenv, _G.hs = previous_getenv, previous_hs
	local cleaned, cleanup_error = pcall(function() if root then remove_tree(fs, root) end end)
	rawset(_G, "lfs", previous_lfs)
	if not ok then error(detail, 0) end
	assert(cleaned, cleanup_error)
end

local function assert_config_survives(comment, suffix)
	fixture(function(s)
		local expected = s.config .. (suffix or "")
		local content = s.line("ConfigDirPath", expected) .. comment .. "\n"
		local paths = s.load(content)
		helpers.assert_true(paths.init(s.root .. "/"))
		helpers.assert_eq(paths.get_config_dir(), expected)
		helpers.assert_true(paths.set_paths(nil, s.logs))
		helpers.assert_eq(assert(s.codec.decode(read_file(s.file))).ConfigDirPath, expected,
			"changing only logs must keep the configured directory on disk")
		local reloaded = s.load()
		helpers.assert_true(reloaded.init(s.root .. "/"))
		helpers.assert_eq(reloaded.get_config_dir(), expected)
		helpers.assert_eq(reloaded.get_logs_dir(), s.logs)
	end)
end

helpers.describe("bootstrap TOML syntax preserves path authority", function()
	helpers.it("keeps an uncommented path through partial save and reload", function()
		assert_config_survives("")
	end)

	helpers.it("keeps a hash inside the quoted path", function()
		assert_config_survives("", "hash#folder/")
	end)

	helpers.it("keeps a path followed by a plain inline comment", function()
		assert_config_survives(" # chosen folder")
	end)

	helpers.it("never treats quotes in an inline comment as part of the path", function()
		assert_config_survives(' # "chosen folder"')
	end)

	helpers.it("keeps the commented logs override when only config changes", function()
		fixture(function(s)
			local paths = s.load(s.line("ConfigDirPath", s.config) .. "\n"
				.. s.line("LogsDirPath", s.logs) .. ' # "logs stay here"\n')
			helpers.assert_true(paths.init(s.root .. "/"))
			helpers.assert_eq(paths.get_logs_dir(), s.logs)
			local next_config = s.root .. "/next/"
			helpers.assert_true(paths.set_paths(next_config, nil))
			local persisted = assert(s.codec.decode(read_file(s.file)))
			helpers.assert_eq(persisted.ConfigDirPath, next_config)
			helpers.assert_eq(persisted.LogsDirPath, s.logs)
		end)
	end)

	for _, invalid in ipairs({
		{ name = "unterminated string", source = 'ConfigDirPath = "unterminated\n' },
		{ name = "invalid later key", source = 'ConfigDirPath = "%s"\nLogsDirPath = ["unterminated\n' },
	}) do
		helpers.it("refuses " .. invalid.name .. " without publishing", function()
			fixture(function(s)
				local content = invalid.source:gsub("%%s", function() return s.config end)
				local paths = s.load(content)
				helpers.assert_true(paths.init(s.root .. "/") == false)
				local changed, reason = paths.set_paths(s.config, s.logs)
				helpers.assert_true(changed == false)
				helpers.assert_not_nil(reason)
				helpers.assert_eq(s.writes, 0)
				helpers.assert_eq(read_file(s.file), content)
			end)
		end)
	end

	helpers.it("roundtrips native quotes and backslashes through the TOML codec", function()
		assert_config_survives("", 'quote"and\\backslash/')
	end)
end)
