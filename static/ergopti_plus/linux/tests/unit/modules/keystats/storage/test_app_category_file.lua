--- tests/unit/modules/keystats/storage/test_app_category_file.lua

--- ==============================================================================
--- MODULE: App Category File Tests (Linux)
--- DESCRIPTION:
--- The Linux driver keeps the categories a user assigns to applications in the
--- shared category document, beside config.toml, like macOS. Before it kept the
--- scores in the SQLite `meta` table and the categories on the day rows. These
--- tests pin the file access (fail closed, atomic), the one-time import of the
--- old store and the keystats edit path that now writes the file.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")
local Json = require("core.text.engine.json")
local Store = require("metrics.engine.apps.category_store")

--- Runs a body with the config folder replaced by a scratch directory.
--- @param body function Receives the file module, the file path and the directory.
local function with_config_dir(body)
	local dir = os.tmpname()
	os.remove(dir)
	assert(os.execute("mkdir -p '" .. dir .. "'"))
	local name = "infra.config_paths"
	local previous = package.loaded[name]
	package.loaded[name] = { config = function(rel) return dir .. "/" .. rel end }
	local file_name = "modules.keystats.app_category_file"
	local previous_file = package.loaded[file_name]
	package.loaded[file_name] = nil
	local ok, err = xpcall(function()
		local file_module = require(file_name)
		body(file_module, dir .. "/" .. Store.FILE_NAME, dir)
	end, debug.traceback)
	package.loaded[name], package.loaded[file_name] = previous, previous_file
	os.execute("rm -rf '" .. dir .. "'")
	if not ok then error(err, 0) end
end

local function read(path)
	local handle = io.open(path, "rb")
	if not handle then return nil end
	local text = handle:read("*a")
	handle:close()
	return text
end

local function write(path, text)
	local handle = assert(io.open(path, "wb"))
	assert(handle:write(text))
	assert(handle:close())
end

helpers.describe("app category file: access", function()
	helpers.it("app-category-file: an absent file is an empty store and a save publishes the versioned layout", function()
		with_config_dir(function(file, path, dir)
			local model, _, source = file.load()
			assert(model)
			helpers.assert_eq(model.apps, {})
			assert(Store.set(model, "Firefox", "Browsers", 1))
			helpers.assert_true(file.save(model, source))
			local saved = assert(Store.decode(read(path), Json.decode))
			helpers.assert_eq(saved.legacy, false)
			helpers.assert_eq(saved.apps, { Firefox = { type = "Browsers", score = 1 } })
			helpers.assert_nil(read(path .. ".tmp"), "the temporary file does not outlive the rename")
			helpers.assert_true(os.execute("test -d '" .. dir .. "'") ~= nil)
		end)
	end)

	for _, initial in ipairs({ "absent", "present" }) do
		helpers.it("preserves a concurrent category edit after reading " .. initial .. " source", function()
			with_config_dir(function(file, path)
				if initial == "present" then write(path, '{"Old":{"type":"Work","score":1}}') end
				local model, _, source = file.load()
				assert(model)
				assert(Store.set(model, "Firefox", "Browsers", 1))
				local successor = '{"Other":{"type":"Work","score":2}}'
				write(path, successor)
				helpers.assert_eq(file.save(model, source), false)
				helpers.assert_eq(read(path), successor)
				helpers.assert_nil(read(path .. ".tmp"))
			end)
		end)
	end

	helpers.it("does not publish or delete a replacement staging file", function()
		with_config_dir(function(file, path)
			local model, _, source = file.load()
			assert(Store.set(model, "Firefox", "Browsers", 1))
			local writer, replacement = require("infra.regular_file_writer"), path .. ".foreign"
			local original = writer.open
			writer.open = function(...)
				local stream, detail, errno, cleanup, current = original(...)
				if not stream then return stream, detail, errno, cleanup, current end
				return stream, detail, errno, cleanup, function(text)
					write(replacement, "foreign stage")
					assert(os.rename(replacement, path .. ".tmp"))
					return current(text)
				end
			end
			local ok, saved = pcall(file.save, model, source)
			writer.open = original
			helpers.assert_true(ok)
			helpers.assert_eq(saved, false)
			helpers.assert_nil(read(path))
			helpers.assert_eq(read(path .. ".tmp"), "foreign stage")
		end)
	end)

	helpers.it("app-category-file: a corrupt file is refused, never read as empty, and its bytes survive", function()
		with_config_dir(function(file, path)
			write(path, "{PRIVATE-CORRUPT-CATEGORY")
			local model, reason = file.load()
			helpers.assert_nil(model)
			helpers.assert_eq(reason, "invalid")
			helpers.assert_eq(read(path), "{PRIVATE-CORRUPT-CATEGORY")
		end)
	end)

	helpers.it("app-category-file: the previous flat layout loads and the next save keeps every category", function()
		with_config_dir(function(file, path)
			write(path, '{"Safari":{"type":"Browsers","score":0},"Xcode":{"type":"Developer tools","score":2}}')
			local model, _, source = file.load()
			assert(model)
			helpers.assert_eq(model.legacy, true)
			assert(Store.set(model, "Mail", "Communication", -1))
			helpers.assert_true(file.save(model, source))
			local saved = assert(Store.decode(read(path), Json.decode))
			helpers.assert_eq(saved.legacy, false)
			helpers.assert_eq(saved.apps, {
				Safari = { type = "Browsers", score = 0 },
				Xcode = { type = "Developer tools", score = 2 },
				Mail = { type = "Communication", score = -1 },
			})
		end)
	end)
end)

helpers.describe("app category file: import of the SQLite store", function()
	helpers.it("app-category-file: legacy entries are added, the file's own entries win, an out of range score is clamped", function()
		with_config_dir(function(file, path)
			local model, _, source = file.load()
			assert(Store.set(model, "Firefox", "Work", 2))
			assert(file.save(model, source))
			helpers.assert_true(file.import_legacy({
				Firefox = { type = "Browsers", score = 0 },
				Xcode = { type = "Developer tools", score = 9 },
			}))
			local saved = assert(Store.decode(read(path), Json.decode))
			helpers.assert_eq(saved.apps, {
				Firefox = { type = "Work", score = 2 },
				Xcode = { type = "Developer tools", score = 2 },
			})
		end)
	end)

	helpers.it("keeps a concurrent edit when legacy import finishes staging", function()
		with_config_dir(function(file, path)
			local writer = require("infra.regular_file_writer")
			local original = writer.open
			local successor = '{"Other":{"type":"Work","score":2}}'
			writer.open = function(...)
				local stream, detail, errno, cleanup, current = original(...)
				if not stream then return stream, detail, errno, cleanup, current end
				return stream, detail, errno, cleanup, function(text)
					write(path, successor)
					return current(text)
				end
			end
			local ok, result = pcall(file.import_legacy, { Firefox = { type = "Browsers", score = 1 } })
			writer.open = original
			helpers.assert_true(ok)
			helpers.assert_eq(result, false)
			helpers.assert_eq(read(path), successor)
			helpers.assert_nil(read(path .. ".tmp"))
		end)
	end)

	helpers.it("app-category-file: an unreadable file keeps the legacy store in SQLite", function()
		with_config_dir(function(file, path)
			write(path, "not json")
			helpers.assert_eq(file.import_legacy({ Xcode = { type = "Developer tools", score = 1 } }), false)
			helpers.assert_eq(read(path), "not json")
		end)
	end)
end)

helpers.describe("app category file: the keystats edit path", function()
	--- Loads keystats over a fake writer, a stubbed reader and a scratch config folder.
	local function with_keystats(legacy, body)
		with_config_dir(function(file, path)
			local fake_writer
			fake_writer = setmetatable({
				open_db = function() return true end,
				ensure_token_encoding = function() return true end,
				ensure_awake_definition = function() return true end,
				register_device = function() return true end,
				read_open_walk = function() return nil, true end,
				upsert_open_walk = function() return true end,
				is_available = function() return true end,
				bump_rev = function() return true end,
				drop_legacy_category_scores = function()
					fake_writer.dropped = (fake_writer.dropped or 0) + 1
					return true
				end,
			}, { __index = Fakes.sqlite_writer() })
			require("tests.support.sqlite_flush_fake").attach(fake_writer)
			local reader = {
				read_legacy_category_scores = function() return legacy end,
				read_manifest = function() return {}, true end,
			}
			local names = { "modules.keystats.sqlite_writer", "modules.keystats.sqlite_reader",
				"modules.keystats.keystats", "modules.keystats.app_category_file" }
			local previous = {}
			for _, name in ipairs(names) do previous[name] = package.loaded[name] end
			package.loaded["modules.keystats.sqlite_writer"] = fake_writer
			package.loaded["modules.keystats.sqlite_reader"] = setmetatable(reader, { __index = previous["modules.keystats.sqlite_reader"] })
			package.loaded["modules.keystats.keystats"] = nil
			package.loaded["modules.keystats.app_category_file"] = file
			local ok, err = pcall(function()
				local keystats = require("modules.keystats.keystats")
				keystats.init({ sqlite_path = "/tmp/ergopti_keystats_category_mock.sqlite" })
				body(keystats, fake_writer, path)
			end)
			for _, name in ipairs(names) do package.loaded[name] = previous[name] end
			if not ok then error(err, 0) end
		end)
	end

	helpers.it("app-category-file: init imports the old SQLite categories once and then drops them", function()
		with_keystats({ Xcode = { type = "Developer tools", score = 2 } }, function(_, writer, path)
			local saved = assert(Store.decode(read(path), Json.decode))
			helpers.assert_eq(saved.apps, { Xcode = { type = "Developer tools", score = 2 } })
			helpers.assert_eq(writer.dropped, 1)
		end)
	end)

	helpers.it("app-category-file: nothing to import leaves the file alone and the database untouched", function()
		with_keystats({}, function(_, writer, path)
			helpers.assert_nil(read(path))
			helpers.assert_nil(writer.dropped)
		end)
	end)

	helpers.it("app-category-file: an edit lands in the file and an invalid score is refused", function()
		with_keystats({}, function(keystats, _, path)
			helpers.assert_true(keystats.set_app_category("Firefox", "Browsers", 1))
			helpers.assert_eq(assert(Store.decode(read(path), Json.decode)).apps,
				{ Firefox = { type = "Browsers", score = 1 } })
			helpers.assert_eq(keystats.set_app_category("Firefox", "Work", 7), false)
			helpers.assert_eq(assert(Store.decode(read(path), Json.decode)).apps,
				{ Firefox = { type = "Browsers", score = 1 } }, "a refused edit changes nothing")
		end)
	end)

	helpers.it("category edit receipt preserves a concurrent file edit during the dialog", function()
		with_keystats({}, function(keystats, _, path)
			local receipt = assert(keystats.capture_app_category_edit())
			local successor = '{"Other":{"type":"Work","score":2}}'
			write(path, successor)
			helpers.assert_eq(keystats.set_app_category("Firefox", "Browsers", 1, receipt), false)
			helpers.assert_eq(read(path), successor)
			helpers.assert_eq(keystats.set_app_category("Firefox", "Browsers", 1, receipt), false)
		end)
	end)

	helpers.it("category edit receipt is consumed even when its requested edit is invalid", function()
		with_keystats({}, function(keystats, _, path)
			local receipt = assert(keystats.capture_app_category_edit())
			helpers.assert_eq(keystats.set_app_category("Firefox", "", 1, receipt), false)
			helpers.assert_eq(keystats.set_app_category("Firefox", "Work", 1, receipt), false)
			helpers.assert_nil(read(path))
		end)
	end)

	helpers.it("category edit refuses inexact native source identities", function()
		with_keystats({}, function(keystats, _, path)
			write(path, '{"Other":{"type":"Work","score":2}}')
			local uv = require("luv")
			for _, invalid in ipairs({ -1, 0.5, 2 ^ 53, 0 / 0, math.huge }) do
				for _, field in ipairs({ "dev", "ino" }) do
					local fake = setmetatable({ fs_stat = function(target)
						local stat = uv.fs_stat(target)
						if target == path and stat then stat[field] = invalid end
						return stat
					end }, { __index = uv })
					package.loaded.luv = fake
					local ok, receipt = pcall(keystats.capture_app_category_edit)
					package.loaded.luv = uv
					helpers.assert_true(ok)
					helpers.assert_nil(receipt)
				end
			end
			helpers.assert_not_nil(keystats.capture_app_category_edit(), "real native identity is accepted")
		end)
	end)

	helpers.it("category edit distinguishes adjacent large exact native identities", function()
		with_keystats({}, function(keystats, _, path)
			local original = '{"Other":{"type":"Work","score":2}}'; write(path, original)
			local uv, device = require("luv"), 2 ^ 53 - 2
			local fake = setmetatable({ fs_stat = function(target)
				local stat = uv.fs_stat(target)
				if target == path and stat then stat.dev = device end
				return stat
			end }, { __index = uv })
			package.loaded.luv = fake
			local ok, receipt, saved = pcall(function()
				local captured = assert(keystats.capture_app_category_edit())
				device = 2 ^ 53 - 1
				return captured, keystats.set_app_category("Firefox", "Work", 1, captured)
			end)
			package.loaded.luv = uv
			helpers.assert_true(ok)
			helpers.assert_not_nil(receipt)
			helpers.assert_eq(saved, false)
			helpers.assert_eq(read(path), original)
		end)
	end)

	helpers.it("category edit receipt rejects a replaced file with identical bytes", function()
		with_keystats({}, function(keystats, _, path)
			local original = '{"Other":{"type":"Work","score":2}}'
			write(path, original)
			local receipt = assert(keystats.capture_app_category_edit())
			write(path .. ".replacement", original)
			assert(os.rename(path .. ".replacement", path))
			helpers.assert_eq(keystats.set_app_category("Firefox", "Browsers", 1, receipt), false)
			helpers.assert_eq(read(path), original)
		end)
	end)

	helpers.it("refuses a dashboard edit if the category file changes during staging", function()
		with_keystats({}, function(keystats, _, path)
			local writer = require("infra.regular_file_writer")
			local original = writer.open
			local successor = '{"Other":{"type":"Work","score":2}}'
			writer.open = function(...)
				local stream, detail, errno, cleanup, current = original(...)
				if not stream then return stream, detail, errno, cleanup, current end
				return stream, detail, errno, cleanup, function(text)
					write(path, successor)
					return current(text)
				end
			end
			local ok, result = pcall(keystats.set_app_category, "Firefox", "Browsers", 1)
			writer.open = original
			helpers.assert_true(ok)
			helpers.assert_eq(result, false)
			helpers.assert_eq(read(path), successor)
			helpers.assert_nil(read(path .. ".tmp"))
		end)
	end)

	helpers.it("app-category-file: an unreadable file refuses the edit and keeps its bytes", function()
		with_keystats({}, function(keystats, _, path)
			write(path, "{PRIVATE")
			helpers.assert_eq(keystats.set_app_category("Firefox", "Browsers", 1), false)
			helpers.assert_eq(read(path), "{PRIVATE")
		end)
	end)
end)
