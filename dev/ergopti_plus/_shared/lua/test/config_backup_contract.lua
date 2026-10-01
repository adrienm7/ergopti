--- _shared/lua/test/config_backup_contract.lua

--- Exercises the shared configuration backup owner over an in-memory folder
--- tree: what a pre-install backup copies, that it is verified and completed by
--- its manifest, and that a restore backs up first and writes nothing on a
--- missing copy. Registered by the macOS and Linux suites with their decoded
--- shared updater defaults.
local M = {}

--- An in-memory file tree implementing the owner's I/O ports.
--- @return table fs { files, dirs, io, writes, refuse }
local function memory_fs()
	local fs = { files = {}, dirs = { ["/"] = true }, writes = {}, refuse = {} }
	local function parent(path) return path:match("^(.*)/[^/]+$") or "/" end
	function fs.add_dir(path)
		while path ~= "" and path ~= "/" and not fs.dirs[path] do
			fs.dirs[path] = true
			path = parent(path)
		end
	end
	function fs.add_file(path, content)
		fs.add_dir(parent(path))
		fs.files[path] = content
	end
	fs.io = {
		list = function(dir)
			dir = dir:gsub("/+$", "")
			if not fs.dirs[dir] then return nil, "absent" end
			local entries, seen = {}, {}
			for path in pairs(fs.files) do
				local name = path:sub(#dir + 2)
				if path:sub(1, #dir + 1) == dir .. "/" and not name:find("/", 1, true) then
					entries[#entries + 1] = { name = name, kind = "file" }
				end
			end
			for path in pairs(fs.dirs) do
				local name = path:sub(#dir + 2)
				if path:sub(1, #dir + 1) == dir .. "/" and name ~= "" and not name:find("/", 1, true)
					and not seen[name] then
					seen[name] = true
					entries[#entries + 1] = { name = name, kind = "dir" }
				end
			end
			for _, name in ipairs(fs.links or {}) do
				if parent(name) == dir then entries[#entries + 1] = { name = name:match("([^/]+)$"), kind = "other" } end
			end
			return entries
		end,
		read = function(path)
			if fs.refuse[path] == "read" then return nil, "permission denied" end
			local content = fs.files[path]
			if content == nil then return nil, "absent" end
			return content
		end,
		make_dir = function(path)
			fs.add_dir(path:gsub("/+$", ""))
			return true
		end,
		create = function(path, content)
			if fs.refuse[path] == "write" then return nil, "disk full" end
			if fs.files[path] ~= nil then return nil, "exists" end
			fs.files[path] = content
			fs.writes[#fs.writes + 1] = path
			return true
		end,
		replace = function(path, content)
			if fs.refuse[path] == "write" then return nil, "disk full" end
			fs.files[path] = content
			fs.writes[#fs.writes + 1] = path
			return true
		end,
	}
	return fs
end

--- A JSON codec for manifests: the real one is the driver's; this one only has
--- to round-trip what the owner writes.
local function codec()
	local store, count = {}, 0
	return {
		encode = function(value)
			count = count + 1
			local key = "manifest#" .. count
			store[key] = value
			return key
		end,
		decode = function(text)
			local value = store[text]
			if value == nil then return nil, "not json" end
			-- A decoder returns a fresh table; the owner annotates it.
			local copy = {}
			for k, v in pairs(value) do copy[k] = v end
			return copy
		end,
	}
end

--- A silent logger recording its errors.
local function quiet_logger()
	local logger = { errors = {} }
	for _, level in ipairs({ "start", "success", "info", "warn", "debug", "done", "trace" }) do
		logger[level] = function() end
	end
	logger.error = function(_, fmt, ...) logger.errors[#logger.errors + 1] = string.format(fmt, ...) end
	return logger
end

--- @param helpers table Test helpers of the driver suite.
--- @param env table { defaults = decoded _shared/modules/updater/defaults.json }
function M.register(helpers, env)
	local Backup = require("updater.config_backup")
	local rules = assert(Backup.rules(env.defaults))

	local function fixture(opts)
		opts = opts or {}
		local fs = memory_fs()
		fs.add_file("/cfg/config.toml", "[script]\n")
		fs.add_file("/cfg/tap_hold.toml", "[tap]\n")
		fs.add_file("/cfg/layers.toml", "[nav]\n")
		fs.add_file("/cfg/hotstrings/personal_hotstrings.toml", "btw = by the way\n")
		fs.add_file("/cfg/hammerspoon/config.toml", "[mac]\n")
		fs.add_file("/cfg/llm/models.json", "{}")
		fs.add_file("/cfg/metrics/metrics.toml", "never copied")
		fs.add_file("/cfg/db.sqlite", "binary")
		fs.add_file("/cfg/notes.txt", "not configuration")
		fs.add_file("/cfg/backups/pre-install-20260101-000000/backup.json", "old")
		fs.add_file("/state/storage.json", "{\"a\":1}")
		local times = opts.times or { "20260930-101500" }
		local tick = 0
		local logger = quiet_logger()
		local json = codec()
		local owner = Backup.new({
			rules = rules,
			roots = opts.roots or {
				{ id = "config", dir = "/cfg/" },
				{ id = "settings_store", file = "/state/storage.json" },
			},
			io = fs.io,
			json = json,
			clock = function()
				tick = math.min(tick + 1, #times)
				local stamp = times[tick]
				return { stamp = stamp, iso = stamp:gsub("^(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)$",
					"%1-%2-%3T%4:%5:%6Z") }
			end,
			logger = logger,
			log = "test",
		})
		return owner, fs, logger, json
	end

	local function paths_of(record)
		local out = {}
		for _, file in ipairs(record.files) do out[#out + 1] = file.root .. "/" .. file.path end
		table.sort(out)
		return table.concat(out, ",")
	end

	helpers.describe("shared configuration backup (config_backup)", function()
		helpers.it("reads its rules from the shared updater defaults", function()
			helpers.assert_eq(rules.folder, "backups")
			helpers.assert_true(rules.excluded[rules.folder] == true, "the backups folder is excluded")
			local broken = { config_backup = { folder = "backups", manifest = "backup.json",
				kinds = { pre_install = "a", pre_restore = "b" }, include_extensions = { ".toml" },
				exclude_dirs = {} } }
			helpers.assert_eq(Backup.rules(broken), nil)
		end)

		helpers.it("copies every configuration file, and only those, before writing its manifest", function()
			local owner, fs = fixture()
			local record = assert(owner.create("pre_install", { tag = "v0.0.0-dev.139", from_version = "0.0.0-dev.140" }))
			helpers.assert_eq(record.id, "pre-install-20260930-101500-v0.0.0-dev.139")
			helpers.assert_eq(record.path, "/cfg/backups/pre-install-20260930-101500-v0.0.0-dev.139")
			helpers.assert_eq(paths_of(record), table.concat({
				"config/config.toml", "config/hammerspoon/config.toml", "config/hotstrings/personal_hotstrings.toml",
				"config/layers.toml", "config/llm/models.json", "config/tap_hold.toml",
				"settings_store/storage.json" }, ","))
			helpers.assert_eq(fs.files[record.path .. "/config/hotstrings/personal_hotstrings.toml"],
				"btw = by the way\n")
			helpers.assert_eq(fs.files[record.path .. "/settings_store/storage.json"], "{\"a\":1}")
			helpers.assert_eq(fs.writes[#fs.writes], record.path .. "/backup.json", "the manifest is written last")
			helpers.assert_eq(record.tag, "v0.0.0-dev.139")
			helpers.assert_eq(record.created_at, "2026-09-30T10:15:00Z")
		end)

		helpers.it("does not copy a file root twice when it lies in the configuration folder", function()
			local owner = fixture({ roots = {
				{ id = "config", dir = "/cfg" },
				{ id = "settings_store", file = "/cfg/config.toml" },
			} })
			local record = assert(owner.create("pre_install", {}))
			local count = 0
			for _, file in ipairs(record.files) do
				if file.path == "config.toml" then count = count + 1 end
			end
			helpers.assert_eq(count, 1)
		end)

		helpers.it("refuses the whole backup when one file cannot be read, and writes no manifest", function()
			local owner, fs, logger = fixture()
			fs.refuse["/cfg/layers.toml"] = "read"
			local record, err = owner.create("pre_install", {})
			helpers.assert_eq(record, nil)
			helpers.assert_true(tostring(err):find("layers.toml", 1, true) ~= nil, "the error names the file")
			helpers.assert_eq(#fs.writes, 0, "nothing is written before every file is read")
			helpers.assert_true(#logger.errors > 0, "the refusal is logged")
		end)

		helpers.it("stops at a copy it cannot write and leaves the folder without a manifest", function()
			local owner, fs = fixture()
			fs.refuse["/cfg/backups/pre-install-20260930-101500/config/tap_hold.toml"] = "write"
			helpers.assert_eq(owner.create("pre_install", {}), nil)
			helpers.assert_eq(fs.files["/cfg/backups/pre-install-20260930-101500/backup.json"], nil)
			helpers.assert_eq(owner.latest("pre_install"), nil, "an incomplete backup is never offered")
		end)

		helpers.it("gives two backups of one second distinct folders", function()
			local owner = fixture({ times = { "20260930-101500", "20260930-101500" } })
			local first = assert(owner.create("pre_install", {}))
			local second = assert(owner.create("pre_install", {}))
			helpers.assert_true(first.id ~= second.id, "distinct ids")
			helpers.assert_eq(second.id, "pre-install-20260930-101500-2")
		end)

		helpers.it("offers the newest complete backup of a kind", function()
			local owner = fixture({ times = { "20260930-101500", "20260930-111500", "20260930-121500" } })
			assert(owner.create("pre_install", { tag = "v1" }))
			local newest = assert(owner.create("pre_install", { tag = "v2" }))
			assert(owner.create("pre_restore", {}))
			local latest = owner.latest("pre_install")
			helpers.assert_eq(latest and latest.id, newest.id)
			helpers.assert_eq(latest and latest.tag, "v2")
		end)

		helpers.it("restores after backing the replaced configuration up", function()
			local owner, fs = fixture({ times = { "20260930-101500", "20260930-111500" } })
			local record = assert(owner.create("pre_install", { tag = "v0.0.0-dev.139" }))
			fs.files["/cfg/config.toml"] = "[changed]\n"
			fs.files["/state/storage.json"] = "{\"a\":2}"
			local restored, reason, pre = owner.restore(record.id)
			helpers.assert_eq(restored, true, tostring(reason))
			helpers.assert_eq(fs.files["/cfg/config.toml"], "[script]\n")
			helpers.assert_eq(fs.files["/state/storage.json"], "{\"a\":1}")
			helpers.assert_eq(pre and pre.kind, "pre_restore")
			helpers.assert_eq(fs.files[pre.path .. "/config/config.toml"], "[changed]\n",
				"the replaced configuration is kept")
		end)

		helpers.it("writes nothing back when a copy is missing", function()
			local owner, fs = fixture()
			local record = assert(owner.create("pre_install", {}))
			fs.files[record.path .. "/config/layers.toml"] = nil
			fs.files["/cfg/config.toml"] = "[changed]\n"
			local writes = #fs.writes
			local restored, reason, pre = owner.restore(record.id)
			helpers.assert_eq(restored, false)
			helpers.assert_eq(reason, "missing")
			helpers.assert_eq(pre, nil)
			helpers.assert_eq(#fs.writes, writes, "no pre-restore backup and no write")
			helpers.assert_eq(fs.files["/cfg/config.toml"], "[changed]\n")
		end)

		helpers.it("refuses a manifest naming a path outside the configuration", function()
			local owner, fs, _, json = fixture()
			local record = assert(owner.create("pre_install", {}))
			local manifest = record.path .. "/backup.json"
			fs.files[manifest] = json.encode({ schema_version = 1, id = record.id, kind = "pre_install",
				files = { { root = "config", path = "../../etc/passwd" } } })
			local writes = #fs.writes
			local restored, reason = owner.restore(record.id)
			helpers.assert_eq(restored, false)
			helpers.assert_eq(reason, "missing")
			helpers.assert_eq(#fs.writes, writes, "nothing is written for a manifest leaving its root")
			helpers.assert_eq(owner.restore("../x"), false)
		end)
	end)
end

return M
