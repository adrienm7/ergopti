--- tests/unit/infra/file_watchers/test_file_watchers_native_path_identity.lua

--- ==============================================================================
--- MODULE: Native File Watcher Path Identity Tests
--- DESCRIPTION:
--- Exercises the real watcher controller against physically distinct POSIX names.
--- Native realpath replies model only aliases verified against the actual files.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.file_watcher_self_write_fixture")
local fs = require("lfs")

--- Retains one physical tree and removes only its explicitly created entries.
--- @param body function Receives the tree and creation/identity helpers.
local function with_tree(body)
	local root = assert(os.tmpname())
	assert(os.remove(root)); assert(fs.mkdir(root))
	local owned = {}
	local function directory(name)
		local path = root .. "/" .. name
		local created, detail = fs.mkdir(path)
		if not created then assert(fs.attributes(path, "mode") == "directory", detail) end
		if created then owned[#owned + 1] = { path = path, directory = true } end
		return path
	end
	local function file(name)
		local path = root .. "/" .. name
		local present = fs.symlinkattributes(path) ~= nil
		local handle = assert(io.open(path, "wb"))
		assert(handle:write("physical watcher source\n")); assert(handle:close())
		if not present then owned[#owned + 1] = { path = path } end
		return path
	end
	local function same(left, right)
		local a, b = assert(fs.attributes(left)), assert(fs.attributes(right))
		return a.dev == b.dev and a.ino == b.ino
	end
	local function link(source, name)
		local path = root .. "/" .. name
		assert(fs.link(source, path, true))
		owned[#owned + 1] = { path = path }
		return path
	end
	local function run(context, aliases, callback, options)
		options = options or {}
		context.base_dir, context.personal_hotstrings_dir = root, ""
		return Fixture.with_watchers(callback, {
			context = context, attributes = fs.attributes, logger = options.logger,
			resolve_path = function(path)
				if options.resolve then return options.resolve(path) end
				if fs.attributes(path) == nil then return nil end
				return aliases[path] or path
			end,
		})
	end
	local result = table.pack(xpcall(function() return body(root, directory, file, same, run, link) end, debug.traceback))
	for index = #owned, 1, -1 do
		local entry = owned[index]
		if fs.symlinkattributes(entry.path) then
			assert(entry.directory and fs.rmdir(entry.path) or os.remove(entry.path))
		end
	end
	assert(fs.rmdir(root))
	if not result[1] then error(result[2], 0) end
end

helpers.describe("file-watchers-native-path-identity", function()
	helpers.it("distinguishes literal backslashes from directory separators in self writes", function()
		with_tree(function(root, directory, file, same, run)
			directory("folder")
			local own, changed = file("folder/item.toml"), file("folder\\item.toml")
			helpers.assert_eq(same(own, changed), false, "POSIX backslashes must name a different physical file")
			run({ hotstrings_dir = root, self_written_files = { own } }, {}, function(w)
				w.fire(changed)
				helpers.assert_true(type(w.scheduled()) == "function", "a distinct physical file must reload")
				w.settle(); helpers.assert_eq(w.reloads(), 1)
			end)
		end)
	end)

	helpers.it("uses actual filesystem case identity rather than folding distinct self writes", function()
		with_tree(function(root, _, file, same, run)
			local own, changed = file("Config.toml"), file("config.toml")
			local alias = same(own, changed)
			local aliases = alias and { [changed] = own } or {}
			run({ hotstrings_dir = root, self_written_files = { own } }, aliases, function(w)
				w.fire(changed)
				helpers.assert_eq(w.scheduled() == nil, alias,
					"only actual native aliases may be suppressed; the host filesystem determines case identity")
			end)
		end)
	end)

	helpers.it("does not confuse literal-backslash runtime folders with ordinary source folders", function()
		with_tree(function(root, directory, file, _, run)
			local ignored = directory("cache\\runtime")
			directory("cache"); directory("cache/runtime")
			local changed = file("cache/runtime/source.toml")
			run({ hotstrings_dir = root, ignored_dirs = { ignored } }, {}, function(w)
				w.fire(changed)
				helpers.assert_true(type(w.scheduled()) == "function", "an unrelated physical runtime folder cannot hide edits")
			end)
		end)
	end)

	helpers.it("arms a standalone personal-info watcher outside a backslash-named root", function()
		with_tree(function(root, directory, file, _, run)
			local watched = directory("corpus\\personal")
			directory("corpus"); directory("corpus/personal")
			local info = file("corpus/personal/personal_info.toml")
			run({ hotstrings_dir = watched, personal_info_path = info }, {}, function(w)
				helpers.assert_eq(#w.watcher_paths, 3, "two recursive roots do not cover the distinct personal-info file")
			end)
		end)
	end)

	helpers.it("preserves self-write aliases resolved through a real symbolic link", function()
		with_tree(function(root, _, file, same, run, link)
			local physical = file("config.toml")
			local alias = link(physical, "config-alias.toml")
			helpers.assert_true(same(physical, alias), "the native alias control must share its actual inode")
			run({ hotstrings_dir = root, self_written_files = { alias } }, { [alias] = physical }, function(w)
				w.fire(physical)
				helpers.assert_nil(w.scheduled(), "native aliases of a session write remain excluded")
			end)
		end)
	end)

	helpers.it("uses resolved directory aliases for runtime exclusion and watcher coverage", function()
		with_tree(function(root, directory, file, same, run, link)
			local physical = directory("runtime")
			local changed = file("runtime/personal_info.toml")
			local alias = link(physical, "runtime-alias")
			helpers.assert_true(same(physical, alias))
			run({ hotstrings_dir = alias, ignored_dirs = { alias }, personal_info_path = changed },
				{ [alias] = physical }, function(w)
					helpers.assert_eq(#w.watcher_paths, 2, "the existing recursive watcher already covers this physical file")
					w.fire(changed)
					helpers.assert_nil(w.scheduled(), "a real runtime-directory alias remains excluded")
				end)
		end)
	end)

	helpers.it("retains literal removed suffixes after a physically verified missing component", function()
		with_tree(function(root, directory, file, _, run)
			directory("removed")
			local changed = file("removed/entry\\name.toml")
			run({ hotstrings_dir = root }, {}, function(w)
				assert(os.remove(changed)); assert(fs.rmdir(root .. "/removed"))
				w.fire(changed)
				helpers.assert_true(type(w.scheduled()) == "function", "deleting a subtree must still reload its former source")
				w.settle(); helpers.assert_eq(w.reloads(), 1)
			end)
		end)
	end)

	helpers.it("preserves the identity of a removed self-written file", function()
		with_tree(function(root, _, file, _, run)
			local own = file("entry\\config.toml")
			run({ hotstrings_dir = root, self_written_files = { own } }, {}, function(w)
				assert(os.remove(own))
				w.fire(own)
				helpers.assert_nil(w.scheduled(), "a deleted self-written name keeps its exact parent and literal basename")
			end)
		end)
	end)

	helpers.it("never suppresses an unproved identity and reports its native refusal once per batch", function()
		with_tree(function(root, _, file, _, run)
			local own = file("config.toml")
			local logger, warnings, refused = helpers.make_logger_stub(), 0, false
			logger.warn = function() warnings = warnings + 1 end
			run({ hotstrings_dir = root, self_written_files = { own }, ignored_dirs = { root } }, {}, function(w)
				refused = true
				w.fire(own)
				helpers.assert_true(type(w.scheduled()) == "function", "failed native identity cannot prove an exclusion")
				helpers.assert_eq(warnings, 1, "self-write and runtime checks share one refused identity observation")
			end, { logger = logger, resolve = function(path)
				if refused and path == own then return nil end
				return path
			end })
		end)
	end)

	helpers.it("uses actual directory case identity when deciding personal-info coverage", function()
		with_tree(function(root, directory, file, same, run)
			local watched, parent = directory("Corpus"), directory("corpus")
			local info = file("corpus/personal_info.toml")
			local alias = same(watched, parent)
			local aliases = alias and { [parent] = watched, [info] = watched .. "/personal_info.toml" } or {}
			run({ hotstrings_dir = watched, personal_info_path = info }, aliases, function(w)
				helpers.assert_eq(#w.watcher_paths, alias and 2 or 3,
					"only a truly covered native directory may omit the standalone watcher")
			end)
		end)
	end)
end)
