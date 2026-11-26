--- tests/unit/settings/test_paths_default_config_dir.lua

--- ==============================================================================
--- MODULE: Default Configuration Folder Preparation Tests
--- DESCRIPTION:
--- The maintainer's decision of 2026-11-22: a locale chosen while config.toml
--- does not exist creates the file, and its folder when that folder is the
--- default one. A custom folder that is missing is never created: it may be an
--- unmounted volume, so its write refuses the choice instead.
--- ==============================================================================

local helpers = require("tests.helpers")

local FOLDER = require("core.fs.engine.app_dirs").linux.folder_name

--- Loads a fresh paths module whose XDG config root is `root` and whose
--- bootstrap storage holds `override` as the configuration folder.
--- @param root string Absolute XDG config root.
--- @param override string|nil Custom configuration folder.
--- @param body function Receives the loaded module.
local function with_paths(root, override, body)
	local saved_paths, saved_storage = package.loaded["settings.engine.paths"], package.loaded["core.fs.adapters.storage"]
	local env_name = require("core.fs.engine.app_dirs").linux.config_env
	local original_getenv = os.getenv
	local ok, err = xpcall(function()
		os.getenv = function(name)
			if name == env_name then return root end
			return original_getenv(name)
		end
		package.loaded["core.fs.adapters.storage"] = { get = function(key)
			if key == "paths.config_dir" then return override end
			return nil
		end }
		package.loaded["settings.engine.paths"] = nil
		body(require("settings.engine.paths"))
	end, debug.traceback)
	os.getenv = original_getenv
	package.loaded["settings.engine.paths"], package.loaded["core.fs.adapters.storage"] = saved_paths, saved_storage
	if not ok then error(err, 0) end
end

local function is_directory(path)
	local probe = io.open(path .. "/.probe", "wb")
	if not probe then return false end
	probe:close()
	os.remove(path .. "/.probe")
	return true
end

helpers.describe("default configuration folder preparation (locale-creates-config-2026-11-22)", function()
	helpers.it("creates the missing default folder", function()
		local root = os.tmpname()
		os.remove(root)
		with_paths(root, nil, function(Paths)
			helpers.assert_eq(is_directory(root .. "/" .. FOLDER), false, "the folder starts missing")
			helpers.assert_true(Paths.prepare_default_config_dir())
			helpers.assert_true(is_directory(root .. "/" .. FOLDER), "the default folder is created")
		end)
		os.execute("rmdir " .. string.format("%q", root .. "/" .. FOLDER))
		os.execute("rmdir " .. string.format("%q", root))
	end)

	helpers.it("never creates a missing custom folder", function()
		local root, custom = os.tmpname(), os.tmpname()
		os.remove(root); os.remove(custom)
		with_paths(root, custom, function(Paths)
			helpers.assert_true(Paths.prepare_default_config_dir(), "a custom folder is left to its write")
			helpers.assert_eq(is_directory(custom), false, "the custom folder is not created")
			helpers.assert_eq(is_directory(root .. "/" .. FOLDER), false, "nor the default one")
		end)
	end)
end)
