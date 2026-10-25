--- linux/tests/unit/modules/updater/install/test_config_backup_files.lua

--- ==============================================================================
--- MODULE: Configuration Backup on Real Files (Linux)
--- DESCRIPTION:
--- The shared backup owner is proven over an in-memory tree by its contract;
--- this runs the Linux binding (modules/updater/config_backup.lua) on a real
--- temporary folder: a pre-install backup copies the configuration and the
--- settings store, a link to a folder is reported and never walked, and a
--- restore puts the exact bytes back after backing up the replaced ones.
--- ==============================================================================

local helpers = require("tests.helpers")

local function quote(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end

local function write(path, text)
	local handle = assert(io.open(path, "wb"))
	assert(handle:write(text))
	assert(handle:close())
end

local function read(path)
	local handle = io.open(path, "rb")
	if not handle then return nil end
	local text = handle:read("*a")
	handle:close()
	return text
end

local function scratch()
	local uv = require("luv")
	local dir = assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-config-backup-XXXXXX"))
	assert(os.execute("mkdir -p " .. quote(dir .. "/cfg/hotstrings") .. " " .. quote(dir .. "/state")
		.. " " .. quote(dir .. "/cfg/metrics") .. " " .. quote(dir .. "/elsewhere")))
	write(dir .. "/cfg/config.toml", "[script]\nlocale = \"fr\"\n")
	write(dir .. "/cfg/hotstrings/personal_hotstrings.toml", "btw = \"by the way\"\n")
	write(dir .. "/cfg/metrics/metrics.toml", "not configuration")
	write(dir .. "/cfg/db.sqlite", "binary")
	write(dir .. "/elsewhere/linked.toml", "[linked]\n")
	write(dir .. "/state/storage.json", "{\"paths.config_dir\":\"x\"}")
	assert(os.execute("ln -s " .. quote(dir .. "/elsewhere/linked.toml") .. " " .. quote(dir .. "/cfg/linked.toml")))
	assert(os.execute("ln -s " .. quote(dir .. "/cfg") .. " " .. quote(dir .. "/cfg/loop")))
	return dir
end

helpers.describe("config_backup (Linux): real files", function()
	helpers.it("lists files, folders, and a link to a folder as neither", function()
		local dir = scratch()
		local Backup = helpers.load_module("modules.updater.config_backup")
		local entries = assert(Backup._list(dir .. "/cfg"))
		local kinds = {}
		for _, entry in ipairs(entries) do kinds[entry.name] = entry.kind end
		helpers.assert_eq(kinds["config.toml"], "file")
		helpers.assert_eq(kinds["hotstrings"], "dir")
		helpers.assert_eq(kinds["linked.toml"], "file", "a link to a file is copied through it")
		helpers.assert_eq(kinds["loop"], "other", "a link to a folder is never walked")
		local absent, reason = Backup._list(dir .. "/nothing")
		helpers.assert_nil(absent)
		helpers.assert_eq(reason, "absent")
		os.execute("rm -rf " .. quote(dir))
	end)

	helpers.it("backs up and restores the exact bytes of the configuration and the settings store", function()
		local dir = scratch()
		local Backup = helpers.load_module("modules.updater.config_backup")
		Backup._overrides = { roots = {
			{ id = "config", dir = dir .. "/cfg" },
			{ id = "settings_store", file = dir .. "/state/storage.json" },
		} }
		local ok, err = pcall(function()
			local owner = assert(Backup.owner())
			local record = assert(owner.create("pre_install", { tag = "v0.0.0-dev.139", from_version = "0.0.0-dev.140" }))
			helpers.assert_eq(read(record.path .. "/config/config.toml"), "[script]\nlocale = \"fr\"\n")
			helpers.assert_eq(read(record.path .. "/config/linked.toml"), "[linked]\n")
			helpers.assert_eq(read(record.path .. "/settings_store/storage.json"), "{\"paths.config_dir\":\"x\"}")
			helpers.assert_nil(read(record.path .. "/config/metrics/metrics.toml"), "metrics are not configuration")
			helpers.assert_nil(read(record.path .. "/config/db.sqlite"))
			helpers.assert_true(read(record.path .. "/backup.json") ~= nil, "the manifest completes the backup")
			local latest = owner.latest("pre_install")
			helpers.assert_eq(latest and latest.id, record.id)

			write(dir .. "/cfg/config.toml", "[changed]\n")
			write(dir .. "/state/storage.json", "{}")
			local restored, reason, pre = owner.restore(record.id)
			helpers.assert_eq(restored, true, tostring(reason))
			helpers.assert_eq(read(dir .. "/cfg/config.toml"), "[script]\nlocale = \"fr\"\n")
			helpers.assert_eq(read(dir .. "/state/storage.json"), "{\"paths.config_dir\":\"x\"}")
			helpers.assert_eq(read(pre.path .. "/config/config.toml"), "[changed]\n")
		end)
		Backup._overrides = nil
		os.execute("rm -rf " .. quote(dir))
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("config-backup-native-names", function()
	for _, case in ipairs({
		{ slug = "newline-file", relative = "personal\nnotes.toml" },
		{ slug = "newline-directory", relative = "packs\nnested/personal.toml", folder = "packs\nnested" },
	}) do
		helpers.it("(config-backup-native-names) preserves " .. case.slug .. " through backup and restore", function()
			local dir = scratch()
			local Backup = helpers.load_module("modules.updater.config_backup")
			Backup._overrides = { roots = { { id = "config", dir = dir .. "/cfg" } } }
			local ok, err = pcall(function()
				if case.folder then assert(require("luv").fs_mkdir(dir .. "/cfg/" .. case.folder, 448)) end
				local target = dir .. "/cfg/" .. case.relative
				local content = "[literal]\ntext = \"unchanged bytes\"\n"
				write(target, content)
				local owner = assert(Backup.owner())
				local record, reason = owner.create("pre_install", { tag = "v1.2.3" })
				helpers.assert_true(type(record) == "table", "literal native names must produce a complete backup: " .. tostring(reason))
				helpers.assert_eq(read(record.path .. "/config/" .. case.relative), content)
				local matches = 0
				for _, file in ipairs(record.files) do
					if file.root == "config" and file.path == case.relative then matches = matches + 1 end
				end
				helpers.assert_eq(matches, 1, "the manifest must retain the exact filename once")
				write(target, "changed\n")
				helpers.assert_eq(owner.restore(record.id), true)
				helpers.assert_eq(read(target), content, "restoration must address the same native path")
			end)
			Backup._overrides = nil
			os.execute("rm -rf " .. quote(dir))
			if not ok then error(err, 0) end
		end)
	end

	helpers.it("(config-backup-native-names) a dangling link cannot block unrelated configuration backup", function()
		local dir = scratch()
		local Backup = helpers.load_module("modules.updater.config_backup")
		Backup._overrides = { roots = { { id = "config", dir = dir .. "/cfg" } } }
		local ok, err = pcall(function()
			assert(require("luv").fs_symlink(dir .. "/not-here", dir .. "/cfg/dangling.toml"))
			local owner = assert(Backup.owner())
			local record, reason = owner.create("pre_install")
			helpers.assert_true(type(record) == "table", "a dangling link is neither a file nor a directory: " .. tostring(reason))
			helpers.assert_eq(read(record.path .. "/config/config.toml"), "[script]\nlocale = \"fr\"\n")
			for _, file in ipairs(record.files) do
				helpers.assert_true(file.path ~= "dangling.toml", "an absent target must never become a backup file")
			end
		end)
		Backup._overrides = nil
		os.execute("rm -rf " .. quote(dir))
		if not ok then error(err, 0) end
	end)

	helpers.it("(config-backup-native-names) EACCES cannot certify directory absence", function()
		local uv = require("luv")
		local dir = scratch()
		local Backup = helpers.load_module("modules.updater.config_backup")
		assert(uv.fs_chmod(dir, 0))
		local called, entries, reason = pcall(Backup._list, dir .. "/cfg")
		assert(uv.fs_chmod(dir, 448))
		os.execute("rm -rf " .. quote(dir))
		if not called then error(entries, 0) end
		helpers.assert_eq(entries, nil)
		helpers.assert_true(type(reason) == "string" and reason ~= "absent", "only ENOENT can mean absence")
	end)
end)

helpers.describe("config-backup-native-metadata", function()
	for _, mode in ipairs({ "denied", "gone", "file" }) do
		helpers.it("(config-backup-native-metadata) unknown d_type requires actual " .. mode .. " metadata", function()
			local uv = require("luv")
			local root = assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-backup-metadata-XXXXXX"))
			local target = root .. "/config.toml"
			write(target, "[native]\nvalue = 1\n")
			write(root .. "/kept.toml", "[kept]\nvalue = 2\n")
			local previous_directory = package.loaded["infra.native_directory"]
			local previous_backup = package.loaded["modules.updater.config_backup"]
			local closed, probed, native_code = 0, 0, nil
			local backend = {
				fs_opendir = uv.fs_opendir,
				fs_readdir = function(handle)
					local entries, message, code = uv.fs_readdir(handle)
					for _, entry in ipairs(entries or {}) do
						-- DT_UNKNOWN is a supported native filesystem receipt. Keep
						-- the real names/directory owner and defer only their types.
						if entry.name == "config.toml" then entry.type = "unknown" end
					end
					return entries, message, code
				end,
				fs_closedir = function(handle)
					local result, message, code = uv.fs_closedir(handle)
					if result == true then closed = closed + 1 end
					return result, message, code
				end,
				fs_lstat = function(path)
					if path ~= target then return uv.fs_lstat(path) end
					probed = probed + 1
					if mode == "denied" then assert(uv.fs_chmod(root, 0))
					elseif mode == "gone" then assert(uv.fs_unlink(target)) end
					local attributes, message, code = uv.fs_lstat(path)
					native_code = code
					if mode == "denied" then assert(uv.fs_chmod(root, 448)) end
					return attributes, message, code
				end,
			}
			local ok, err = pcall(function()
				local Directory = helpers.load_module_with_dependency("infra.native_directory", "luv", backend)
				package.loaded["infra.native_directory"] = Directory
				local Backup = helpers.load_module("modules.updater.config_backup")
				Backup._overrides = { roots = { { id = "config", dir = root } } }
				local owner = assert(Backup.owner())
				local record, reason = owner.create("pre_install")
				helpers.assert_eq(probed, 1, "unknown native types must be classified exactly once")
				helpers.assert_eq(closed, 1, "the actual directory descriptor must retire before any metadata outcome")
				if mode == "denied" then
					helpers.assert_eq(native_code, "EACCES", "the refusal must come from the real kernel")
					helpers.assert_eq(record, nil, "unreadable metadata must never certify a backup that omits configuration")
					helpers.assert_contains(reason, "EACCES")
					helpers.assert_eq(read(target), "[native]\nvalue = 1\n", "the source still exists after the refused observation")
				elseif mode == "gone" then
					helpers.assert_eq(native_code, "ENOENT")
					helpers.assert_true(type(record) == "table", tostring(reason))
					helpers.assert_eq(#record.files, 1, "only actual absence may omit the vanished source")
					helpers.assert_eq(read(record.path .. "/config/kept.toml"), "[kept]\nvalue = 2\n")
				else
					helpers.assert_eq(native_code, nil)
					helpers.assert_true(type(record) == "table", tostring(reason))
					helpers.assert_eq(read(record.path .. "/config/config.toml"), "[native]\nvalue = 1\n")
				end
			end)
			package.loaded["infra.native_directory"] = previous_directory
			package.loaded["modules.updater.config_backup"] = previous_backup
			uv.fs_chmod(root, 448)
			os.execute("rm -rf " .. quote(root))
			if not ok then error(err, 0) end
		end)
	end
end)
