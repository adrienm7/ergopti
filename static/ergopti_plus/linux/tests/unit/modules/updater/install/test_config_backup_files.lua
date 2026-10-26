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

	helpers.it("(config-backup-native-names) a dangling file link refuses through the canonical read", function()
		local dir = scratch()
		local Backup = helpers.load_module("modules.updater.config_backup")
		Backup._overrides = { roots = { { id = "config", dir = dir .. "/cfg" } } }
		local ok, err = pcall(function()
			assert(require("luv").fs_symlink(dir .. "/not-here", dir .. "/cfg/dangling.toml"))
			local owner = assert(Backup.owner())
			local Writer = require("toml_codec.writer")
			local native_read, attempts, observed = Writer.read_classified, 0, nil
			Writer.read_classified = function(path, ...)
				local content, status, detail = native_read(path, ...)
				if path == dir .. "/cfg/dangling.toml" then attempts, observed = attempts + 1, status end
				return content, status, detail
			end
			local called, record, reason = pcall(owner.create, "pre_install")
			Writer.read_classified = native_read
			if not called then error(record, 0) end
			helpers.assert_nil(record, "a listed file with an absent target cannot certify a complete backup")
			helpers.assert_eq(attempts, 1, "the native dangling link must reach classified read, not disappear from the walk")
			helpers.assert_eq(observed, "absent")
			helpers.assert_contains(reason, "cannot read " .. dir .. "/cfg/dangling.toml")
			helpers.assert_eq(read(dir .. "/cfg/config.toml"), "[script]\nlocale = \"fr\"\n")
			helpers.assert_nil(owner.latest("pre_install"), "the refused snapshot must publish no complete record")
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


helpers.describe("config-backup-target-refusal", function()
	for _, mode in ipairs({ "denied", "loop" }) do
		helpers.it("(config-backup-target-refusal) refuses actual " .. mode .. " link target metadata", function()
			local uv = require("luv")
			local dir = scratch()
			local target = dir .. "/cfg/refused.toml"
			local protected = dir .. "/protected"
			if mode == "denied" then
				assert(uv.fs_mkdir(protected, 448))
				write(protected .. "/private.toml", "[retained]\n")
				assert(uv.fs_symlink(protected .. "/private.toml", target))
				assert(uv.fs_chmod(protected, 0))
			else
				assert(uv.fs_symlink(target, target))
			end
			local Backup = helpers.load_module("modules.updater.config_backup")
			local called, entries, reason = pcall(Backup._list, dir .. "/cfg")
			if mode == "denied" then assert(uv.fs_chmod(protected, 448)) end
			local link = assert(uv.fs_lstat(target))
			local retained = read(dir .. "/cfg/config.toml")
			os.execute("rm -rf " .. quote(dir))
			if not called then error(entries, 0) end
			helpers.assert_eq(link.type, "link", "the actual link must remain unchanged after refusal")
			helpers.assert_nil(entries, "non-ENOENT target refusal must never silently omit configuration")
			helpers.assert_contains(reason, mode == "denied" and "EACCES" or "ELOOP")
			helpers.assert_eq(retained, "[script]\nlocale = \"fr\"\n")
		end)
	end
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
				fs_stat = uv.fs_stat,
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
				-- Links are followed through fs_stat only to classify their target.
				fs_stat = uv.fs_stat,
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

helpers.describe("installer-native-publication", function()
	local Fixture = require("tests.support.modules.updater.installer_native_fixture")
	local uv = require("luv")
	for _, mode in ipairs({ "directory", "empty-directory", "directory-link", "file", "absent" }) do
		helpers.it("(installer-native-publication) exact directory move handles " .. mode, function()
			local Installer = helpers.load_module("modules.updater.installer")
			local root = Fixture.scratch()
			local source, destination = root .. "/source", root .. "/destination"
			local ok, err = pcall(function()
				assert(uv.fs_mkdir(source, 448))
				Fixture.write(source .. "/owned.marker", "owned source\n")
				if mode == "directory" or mode == "empty-directory" then
					assert(uv.fs_mkdir(destination, 448))
					if mode == "directory" then Fixture.write(destination .. "/foreign.marker", "foreign destination\n") end
				elseif mode == "directory-link" then
					assert(uv.fs_mkdir(root .. "/foreign", 448))
					Fixture.write(root .. "/foreign/foreign.marker", "foreign destination\n")
					assert(uv.fs_symlink(root .. "/foreign", destination))
				elseif mode == "file" then Fixture.write(destination, "foreign file\n") end
				local moved = Installer.DEFAULT_OPS.move(source, destination)
				if mode == "absent" then
					helpers.assert_eq(moved, true)
					helpers.assert_eq(Fixture.read(destination .. "/owned.marker"), "owned source\n")
					helpers.assert_eq(uv.fs_stat(source), nil)
				else
					helpers.assert_eq(moved, false, "an occupied path must never become a container or be overwritten")
					helpers.assert_eq(Fixture.read(source .. "/owned.marker"), "owned source\n")
					helpers.assert_eq(uv.fs_stat(destination .. "/source"), nil, "no nested source may be published")
					if mode == "directory" or mode == "directory-link" then
						helpers.assert_eq(Fixture.read(destination .. "/foreign.marker"), "foreign destination\n")
					elseif mode == "file" then helpers.assert_eq(Fixture.read(destination), "foreign file\n") end
				end
			end)
			Fixture.remove(root)
			if not ok then error(err, 0) end
		end)
	end

	helpers.it("(installer-native-publication) activation race retains foreign root and original backup", function()
		local Installer = helpers.load_module("modules.updater.installer")
		local fixture = Fixture.create(Installer)
		local current, work_dir, candidate, foreign, injected = uv.fs_stat(fixture.installed), nil, nil, nil, false
		local ops = {}
		for name, operation in pairs(fixture.ops) do ops[name] = operation end
		ops.make_work_dir = function(parent)
			work_dir = Installer.DEFAULT_OPS.make_work_dir(parent)
			return work_dir
		end
		ops.move = function(source, destination)
			if source == work_dir .. "/candidate" then candidate = uv.fs_stat(source) end
			local moved = Installer.DEFAULT_OPS.move(source, destination)
			if moved and source == fixture.installed and destination == fixture.installed .. ".old" then
				assert(uv.fs_mkdir(fixture.installed, 448))
				Fixture.write(fixture.installed .. "/foreign.marker", "concurrent foreign owner\n")
				foreign, injected = uv.fs_stat(fixture.installed), true
			end
			return moved
		end
		local ok, err = pcall(function()
			local installed, reason = Installer.install({ archive_path = fixture.archive, expected_version = "1.2.3",
				context = fixture.context, ops = ops })
			helpers.assert_eq(injected, true, "the real transaction must reach the backup/activation boundary")
			helpers.assert_true(type(candidate) == "table", "the exact assembled candidate must exist before publication")
			helpers.assert_eq(installed, false)
			helpers.assert_eq(Fixture.read(fixture.installed .. "/foreign.marker"), "concurrent foreign owner\n",
				"rollback and staging cleanup must never remove a concurrent destination owner")
			local retained = assert(uv.fs_stat(fixture.installed))
			helpers.assert_eq({ retained.dev, retained.ino }, { foreign.dev, foreign.ino })
			local backup = assert(uv.fs_stat(fixture.installed .. ".old"))
			helpers.assert_eq({ backup.dev, backup.ino }, { current.dev, current.ino })
			helpers.assert_eq(Fixture.read(fixture.installed .. ".old/old.marker"), "original installation\n")
			helpers.assert_contains(reason, "backup remains at " .. fixture.installed .. ".old")
			helpers.assert_eq(uv.fs_stat(fixture.installed .. "/candidate"), nil)
			helpers.assert_eq(uv.fs_stat(fixture.installed .. "/ergopti.old"), nil)
			helpers.assert_eq(uv.fs_stat(work_dir), nil, "only the private staging namespace is cleaned")
			helpers.assert_true(uv.fs_stat(fixture.archive) ~= nil, "failure retains the authenticated archive for retry")
		end)
		Fixture.remove(fixture.root)
		if not ok then error(err, 0) end
	end)

	helpers.it("(installer-native-publication) genuine absent destinations still install and retain the rollback root", function()
		local Installer = helpers.load_module("modules.updater.installer")
		local fixture = Fixture.create(Installer)
		local old = assert(uv.fs_stat(fixture.installed))
		local ok, err = pcall(function()
			local installed, reason = Installer.install({ archive_path = fixture.archive, expected_version = "1.2.3", context = fixture.context, ops = fixture.ops })
			helpers.assert_eq(installed, true, tostring(reason))
			helpers.assert_eq(Fixture.read(fixture.installed .. "/linux/new.marker"), "selected installation\n")
			local backup = assert(uv.fs_stat(fixture.installed .. ".old"))
			helpers.assert_eq({ backup.dev, backup.ino }, { old.dev, old.ino })
			helpers.assert_eq(uv.fs_stat(fixture.archive), nil)
			helpers.assert_true(Fixture.read(fixture.installed .. "/.ergopti-owned-files") ~= nil)
		end)
		Fixture.remove(fixture.root)
		if not ok then error(err, 0) end
	end)

	helpers.it("(installer-native-publication) native refusal cannot fall back to a shell move", function()
		local root = Fixture.scratch()
		local source, destination = root .. "/source", root .. "/destination"
		assert(uv.fs_mkdir(source, 448))
		Fixture.write(source .. "/owned.marker", "owned source\n")
		local original = assert(uv.fs_stat(source))
		local previous = package.loaded["modules.updater.installer"]
		local native_owner = require("infra.no_replace_move")
		helpers.assert_eq(type(native_owner.move), "function", "the double must mirror the real canonical port")
		local probes, forks = 0, 0
		local Installer = helpers.load_module_with_dependency("modules.updater.installer", "infra.no_replace_move", {
			move = function(from, to)
				probes = probes + 1
				helpers.assert_eq(from, source)
				helpers.assert_eq(to, destination)
				return false, "native no-replace move unavailable"
			end,
		})
		local execute = os.execute
		os.execute = function(...) forks = forks + 1; return execute(...) end
		local ok, err = pcall(function()
			local moved, reason = Installer.DEFAULT_OPS.move(source, destination)
			helpers.assert_eq(moved, false)
			helpers.assert_eq(reason, "native no-replace move unavailable")
			helpers.assert_eq(probes, 1)
			helpers.assert_eq(forks, 0, "a refused atomic primitive must never become an unsafe mv")
			local retained = assert(uv.fs_stat(source))
			helpers.assert_eq({ retained.dev, retained.ino }, { original.dev, original.ino })
			helpers.assert_eq(Fixture.read(source .. "/owned.marker"), "owned source\n")
			helpers.assert_eq(uv.fs_stat(destination), nil)
		end)
		os.execute = execute
		package.loaded["modules.updater.installer"] = previous
		Fixture.remove(root)
		if not ok then error(err, 0) end
	end)

end)

helpers.describe("config-backup-rule-source", function()
	local uv = require("luv")
	local Paths = require("infra.paths")
	local rules = assert(read(Paths.shared("modules/updater/defaults.json")))
	for _, kind in ipairs({ "fifo", "fifo-link", "denied", "file", "file-link" }) do
		helpers.it("(config-backup-rule-source) classifies " .. kind .. " before building a backup owner", function()
			local dir = assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-backup-rules-XXXXXX"))
			local source, target = dir .. "/rules\\source\n", dir .. "/target\\source\n"
			assert(uv.fs_mkdir(dir .. "/config", 448))
			if kind == "fifo" or kind == "fifo-link" then
				assert(require("adapters.shell_runner").run("mkfifo -- " .. quote(kind == "fifo" and source or target)))
			else write(kind == "file-link" and target or source, rules) end
			if kind == "fifo-link" or kind == "file-link" then assert(uv.fs_symlink(target, source)) end
			if kind == "denied" then assert(uv.fs_chmod(source, 0)) end
			local admitted = kind == "file" or kind == "file-link"
			local code = string.format([[package.path = %q
local original = require("infra.paths")
package.loaded["infra.paths"] = setmetatable({ shared = function(relative)
 if relative == "modules/updater/defaults.json" then return %q end
 return original.shared(relative)
end }, { __index = original })
local backup = require("modules.updater.config_backup")
backup._overrides = { roots = { { id = "config", dir = %q } } }
local owner, detail = backup.owner()
assert((owner ~= nil) == %s, "backup rules admission disagrees with actual source type: " .. tostring(detail))
]], package.path, source, dir .. "/config", tostring(admitted))
			local expired, exited, status, signal = false, false, nil, nil
			local timer, child = assert(uv.new_timer()), nil
			child = assert(uv.spawn(assert(arg[-1]), { args = { "-e", code } }, function(result, killed)
				exited, status, signal = true, result, killed
				uv.timer_stop(timer); uv.close(timer); uv.close(child)
			end))
			assert(require("infra.native_timer").start(uv, timer, 2000, 0, function()
				expired = true; child:kill("sigkill")
			end))
			while not exited do uv.run("once") end
			uv.run("nowait")
			uv.fs_chmod(source, 384)
			assert(require("adapters.shell_runner").run("rm -r -- " .. quote(dir)))
			helpers.assert_eq(expired, false, "configuration backup must not wait for a FIFO writer")
			helpers.assert_eq(status, 0, "only complete regular rule sources can construct a backup owner")
			helpers.assert_eq(signal, 0, "a killed backup constructor never counts as admission")
		end)
	end

	helpers.it("(config-backup-rule-source) refuses valid bytes when the stream close is unacknowledged", function()
		local previous_paths = package.loaded["infra.paths"]
		local previous_backup = package.loaded["modules.updater.config_backup"]
		local path = os.tmpname()
		write(path, rules)
		package.loaded["infra.paths"] = setmetatable({ shared = function(relative)
			if relative == "modules/updater/defaults.json" then return path end
			return Paths.shared(relative)
		end }, { __index = Paths })
		local Backup = helpers.load_module("modules.updater.config_backup")
		Backup._overrides = { roots = { { id = "config", dir = path .. "-unused" } } }
		local open, closes = io.open, 0
		io.open = function(file, mode)
			local handle, detail, code = open(file, mode)
			if not handle then return nil, detail, code end
			if file ~= path and not file:match("^/proc/self/fd/%d+$") then return handle end
			return { read = function(_, ...) return handle:read(...) end, close = function()
				closes = closes + 1
				assert(handle:close())
				return nil, "unacknowledged close"
			end }
		end
		local called, owner, detail = pcall(Backup.owner)
		io.open = open
		package.loaded["infra.paths"] = previous_paths
		package.loaded["modules.updater.config_backup"] = previous_backup
		os.remove(path)
		helpers.assert_eq(called, true, "the public owner must report a refusal without throwing")
		helpers.assert_eq(closes, 1, "the actual rules stream is closed exactly once")
		helpers.assert_nil(owner, "valid JSON cannot override an incomplete read receipt")
		helpers.assert_true(type(detail) == "string")
	end)
end)
