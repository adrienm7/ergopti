--- _shared/tests/lua/settings/backup_contract.lua

--- Exercises the shared configuration backup owner over an in-memory folder
--- tree: what a pre-install backup copies, that it is verified and completed by
--- its manifest, and that a restore backs up first and writes nothing on a
--- missing copy. Registered by the macOS and Linux suites with their decoded
--- shared updater defaults.
local M = {}

--- An in-memory file tree implementing the owner's I/O ports.
--- @return table fs { files, dirs, io, writes, refuse }
local function memory_fs()
	local fs = { files = {}, dirs = { ["/"] = 1 }, writes = {}, refuse = {} }
	local next_inode = 1
	local function parent(path) return path:match("^(.*)/[^/]+$") or "/" end
	function fs.add_dir(path)
		while path ~= "" and path ~= "/" and not fs.dirs[path] do
			next_inode = next_inode + 1
			fs.dirs[path] = next_inode
			path = parent(path)
		end
	end
	function fs.add_file(path, content)
		fs.add_dir(parent(path))
		fs.files[path] = content
	end
	fs.io = {
		directory_status = function(path) return fs.dirs[path] and "present" or "absent" end,
		directory_identity = function(path)
			if not fs.dirs[path] then return nil, "absent" end
			return { dev = 1, ino = fs.dirs[path] }
		end,
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
		make_dir_exclusive = function(path)
			if fs.dirs[path] or fs.files[path] then return nil, "exists" end
			fs.add_dir(path)
			return true
		end,
		create = function(path, content)
			if fs.refuse[path] == "write" then return nil, "disk full" end
			if not fs.dirs[parent(path)] then return nil, "parent absent" end
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
--- @param env table { defaults = decoded _shared/updater/data/defaults.json }
function M.register(helpers, env)
	local Backup = require("updater.engine.config_backup_core")
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
			clock = opts.clock or function()
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
		helpers.it("backs up the filesystem root when it is the configuration directory", function()
			local owner, fs = fixture({ roots = {
				{ id = "config", dir = "/" },
				{ id = "settings_store", file = "/root.toml" },
			} })
			fs.add_file("/root.toml", "important configuration")
			local list = fs.io.list
			fs.io.list = function(path)
				if path == "/" then return { { name = "root.toml", kind = "file" } } end
				return list(path)
			end
			local record = assert(owner.create("pre_install"))
			helpers.assert_eq(paths_of(record), "config/root.toml")
			helpers.assert_eq(fs.files[record.path .. "/config/root.toml"], "important configuration")
		end)
		helpers.it("excludes case aliases of backup and metrics folders on insensitive filesystems", function()
			local owner, fs = fixture()
			for path in pairs(fs.files) do
				if path:sub(1, 13) == "/cfg/backups/" or path:sub(1, 13) == "/cfg/metrics/" then fs.files[path] = nil end
			end
			for path in pairs(fs.dirs) do
				if path:sub(1, 12) == "/cfg/backups" or path:sub(1, 12) == "/cfg/metrics" then fs.dirs[path] = nil end
			end
			fs.add_file("/cfg/Backups/old/config.toml", "old backup")
			fs.add_file("/cfg/Metrics/private.toml", "private metrics")
			local list = fs.io.list
			local directory_status = fs.io.directory_status
			local directory_identity = fs.io.directory_identity
			fs.io.directory_status = function(path)
				if path == "/cfg/backups" then return directory_status("/cfg/Backups") end
				if path == "/cfg/metrics" then return directory_status("/cfg/Metrics") end
				return directory_status(path)
			end
			fs.io.directory_identity = function(path)
				if path == "/cfg/backups" then return directory_identity("/cfg/Backups") end
				if path == "/cfg/metrics" then return directory_identity("/cfg/Metrics") end
				return directory_identity(path)
			end
			fs.io.list = function(path)
				if path == "/cfg/backups" then return list("/cfg/Backups") end
				if path == "/cfg/metrics" then return list("/cfg/Metrics") end
				return list(path)
			end
			local record = assert(owner.create("pre_install"))
			local paths = paths_of(record)
			helpers.assert_nil(paths:find("config/Backups/", 1, true))
			helpers.assert_nil(paths:find("config/Metrics/", 1, true))
		end)

		helpers.it("backs up distinct differently cased folders on sensitive filesystems", function()
			local owner, fs = fixture()
			fs.add_file("/cfg/Backups/personal.toml", "personal")
			fs.add_file("/cfg/Metrics/personal.toml", "personal")
			local record = assert(owner.create("pre_install"))
			local paths = paths_of(record)
			helpers.assert_true(paths:find("config/Backups/personal.toml", 1, true) ~= nil)
			helpers.assert_true(paths:find("config/Metrics/personal.toml", 1, true) ~= nil)
		end)

		helpers.it("keeps a distinct folder when the canonical name appears after enumeration", function()
			local owner, fs = fixture()
			fs.files["/cfg/backups/pre-install-20260101-000000/backup.json"] = nil
			fs.dirs["/cfg/backups/pre-install-20260101-000000"] = nil
			fs.dirs["/cfg/backups"] = nil
			fs.add_file("/cfg/Backups/personal.toml", "keep")
			local status = fs.io.directory_status
			fs.io.directory_status = function(path)
				if path == "/cfg/backups" then fs.add_dir(path) end
				return status(path)
			end
			local record = assert(owner.create("pre_install"))
			helpers.assert_true(paths_of(record):find("config/Backups/personal.toml", 1, true) ~= nil,
				"a concurrent distinct canonical folder cannot hide user data")
		end)

		helpers.it("refuses when a possible excluded-folder alias cannot be classified", function()
			local owner, fs = fixture()
			fs.dirs["/cfg/metrics"] = nil
			fs.files["/cfg/metrics/metrics.toml"] = nil
			fs.add_file("/cfg/Metrics/private.toml", "private")
			fs.io.directory_status = function() return "error", "permission denied" end
			local record = owner.create("pre_install")
			helpers.assert_nil(record)
		end)

		helpers.it("refuses when a possible alias lacks reliable directory identity", function()
			local owner, fs = fixture()
			fs.dirs["/cfg/metrics"] = nil
			fs.files["/cfg/metrics/metrics.toml"] = nil
			fs.add_file("/cfg/Metrics/private.toml", "private")
			fs.io.directory_status = function() return "present" end
			fs.io.directory_identity = function() return nil, "identity unavailable" end
			helpers.assert_nil(owner.create("pre_install"))
		end)
		helpers.it("refuses a backup whose published manifest cannot be read back", function()
			local owner, fs = fixture()
			local create = fs.io.create
			fs.io.create = function(path, content)
				local ok, err = create(path, content)
				if ok and path:match("/backup%.json$") then fs.files[path] = "damaged" end
				return ok, err
			end
			local record = owner.create("pre_install")
			helpers.assert_eq(record, nil, "a corrupted manifest must not authorize installation")
		end)
		helpers.it("refuses a backup directory claimed after listing", function()
			local owner, fs = fixture()
			fs.io.make_dir_exclusive = function(path)
				fs.add_file(path .. "/foreign", "keep")
				return nil, "exists"
			end
			local record = owner.create("pre_install")
			helpers.assert_eq(record, nil)
			helpers.assert_eq(fs.files["/cfg/backups/pre-install-20260930-101500/foreign"], "keep")
		end)
		helpers.it("creates a complete backup when no configuration files exist", function()
			local owner, fs = fixture({ roots = { { id = "config", dir = "/cfg" } } })
			fs.files = {}
			local record, err = owner.create("pre_install")
			helpers.assert_true(record ~= nil, tostring(err))
			helpers.assert_eq(#record.files, 0)
			helpers.assert_eq(owner.latest("pre_install").id, record.id)
		end)
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

		helpers.it("selects the twelfth backup created in the same second", function()
			local owner = fixture()
			local newest
			for _ = 1, 12 do newest = assert(owner.create("pre_install", { tag = "v1" })) end
			local latest = owner.latest("pre_install")
			helpers.assert_eq(latest and latest.id, newest.id, "numeric suffixes must follow creation order")
		end)

		helpers.it("does not reuse an earlier backup suffix after it is deleted", function()
			local owner, fs = fixture()
			assert(owner.create("pre_install", { tag = "v1" }))
			local removed = assert(owner.create("pre_install", { tag = "v1" }))
			assert(owner.create("pre_install", { tag = "v1" }))
			for path in pairs(fs.files) do
				if path:sub(1, #removed.path + 1) == removed.path .. "/" then fs.files[path] = nil end
			end
			for path in pairs(fs.dirs) do
				if path == removed.path or path:sub(1, #removed.path + 1) == removed.path .. "/" then fs.dirs[path] = nil end
			end
			local newest = assert(owner.create("pre_install", { tag = "v1" }))
			helpers.assert_eq(newest.id, "pre-install-20260930-101500-v1-4")
			helpers.assert_eq(owner.latest("pre_install").id, newest.id)
		end)

		helpers.it("refuses a backup when its collision inventory is unavailable", function()
			local owner, fs = fixture()
			local list = fs.io.list
			fs.io.list = function(path)
				if path == "/cfg/backups" then return nil, "permission denied" end
				return list(path)
			end
			local writes = #fs.writes
			local record = owner.create("pre_install", { tag = "v1" })
			helpers.assert_nil(record)
			helpers.assert_eq(#fs.writes, writes)
		end)

		helpers.it("increments a large reserved backup suffix without integer overflow", function()
			local owner, fs = fixture()
			local base = "/cfg/backups/pre-install-20260930-101500-v1"
			fs.add_dir(base .. "-999999999999999999999999999999")
			local created = assert(owner.create("pre_install", { tag = "v1" }))
			helpers.assert_eq(created.id, "pre-install-20260930-101500-v1-1000000000000000000000000000000")
		end)

		helpers.it("orders same-second collision suffixes numerically without confusing tag digits", function()
			for _, tag in ipairs({ "", "release-9" }) do
				local owner = fixture()
				local last
				for _ = 1, 11 do last = assert(owner.create("pre_install", { tag = tag })) end
				helpers.assert_eq(owner.latest("pre_install").id, last.id)
			end
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

		helpers.it("skips a newer backup whose copied file is missing or unreadable", function()
			for _, mode in ipairs({ "missing", "unreadable" }) do
				local owner, fs = fixture({ times = { "20260930-101500", "20260930-111500" } })
				local healthy = assert(owner.create("pre_install", { tag = "v1" }))
				local damaged = assert(owner.create("pre_install", { tag = "v2" }))
				local copy = damaged.path .. "/config/config.toml"
				if mode == "missing" then fs.files[copy] = nil else fs.refuse[copy] = "read" end
				local latest = owner.latest("pre_install")
				helpers.assert_eq(latest and latest.id, healthy.id, "an unusable backup cannot hide a complete one")
			end
		end)

		helpers.it("does not let a backup with invalid metadata hide a healthy backup", function()
			for _, mode in ipairs({ "missing_time", "bad_time", "bad_tag" }) do
				local owner, fs, _, json = fixture({ times = { "20260930-101500", "20260930-111500" } })
				local healthy = assert(owner.create("pre_install", { tag = "v1" }))
				local damaged = assert(owner.create("pre_install", { tag = "v2" }))
				local metadata = { schema_version = 1, id = damaged.id, kind = "pre_install", files = damaged.files,
					created_at = damaged.created_at, tag = "v2", from_version = "" }
				if mode == "missing_time" then metadata.created_at = nil
				elseif mode == "bad_time" then metadata.created_at = "zzz"
				else metadata.tag = false end
				fs.files[damaged.path .. "/backup.json"] = json.encode(metadata)
				local latest = owner.latest("pre_install")
				helpers.assert_eq(latest and latest.id, healthy.id)
				helpers.assert_eq(owner.restore(damaged.id), false)
			end
		end)

		helpers.it("never offers or restores a backup with a corrupt creation timestamp", function()
			for _, case in ipairs({ {}, { value = false }, { value = {} }, { value = "not-a-date" },
				{ value = "9999-99-99T99:99:99Z" }, { value = "2026-02-29T12:00:00Z" } }) do
				local owner, fs, _, json = fixture({ times = { "20260930-101500", "20260930-111500" } })
				local valid = assert(owner.create("pre_install", { tag = "valid" }))
				local broken = assert(owner.create("pre_install", { tag = "broken" }))
				fs.files[broken.path .. "/backup.json"] = json.encode({ schema_version = 1, id = broken.id,
					kind = "pre_install", created_at = case.value, files = broken.files })
				local latest = owner.latest("pre_install")
				helpers.assert_eq(latest and latest.id, valid.id)
				local writes = #fs.writes
				helpers.assert_eq(owner.restore(broken.id), false)
				helpers.assert_eq(#fs.writes, writes)
			end
		end)

		helpers.it("does not publish a backup when its clock returns an invalid creation time", function()
			local owner, fs = fixture({ clock = function()
				return { stamp = "20260930-101500", iso = "2026-02-29T10:15:00Z" }
			end })
			local writes = #fs.writes
			local record, reason = owner.create("pre_install")
			helpers.assert_nil(record)
			helpers.assert_eq(reason, "clock")
			helpers.assert_eq(#fs.writes, writes)
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

		--- A native store holding one value, as the macOS API entries are.
		local function native_port(value)
			local port = { value = value, writes = 0 }
			function port.read()
				if port.value == nil then return nil, "absent" end
				return port.value
			end
			function port.replace(content)
				port.writes = port.writes + 1
				if port.refuse then return nil, "store refused" end
				port.value = port.drop and "other" or content
				return true
			end
			return port
		end

		helpers.it("(config-backup-native-port) backs up and restores a value a driver keeps in a native store", function()
			local port = native_port('{"entries":[1]}')
			local owner, fs = fixture({ times = { "20260930-101500", "20260930-111500" }, roots = {
				{ id = "config", dir = "/cfg/" },
				{ id = "api_entries", name = "api_entries.json", port = port },
			} })
			local record = assert(owner.create("pre_install"))
			helpers.assert_eq(fs.files[record.path .. "/api_entries/api_entries.json"], '{"entries":[1]}')
			port.value = '{"entries":[]}'
			local restored, reason, pre = owner.restore(record.id)
			helpers.assert_eq(restored, true, tostring(reason))
			helpers.assert_eq(port.value, '{"entries":[1]}', "the native store holds the backed-up value again")
			helpers.assert_eq(fs.files[pre.path .. "/api_entries/api_entries.json"], '{"entries":[]}',
				"the replaced value is kept in the pre-restore backup")
		end)

		helpers.it("(config-backup-native-port) an absent native value is no file, an unreadable one refuses", function()
			local owner = fixture({ roots = {
				{ id = "config", dir = "/cfg/" },
				{ id = "api_entries", name = "api_entries.json", port = native_port(nil) },
			} })
			local record = assert(owner.create("pre_install"))
			helpers.assert_true(not paths_of(record):find("api_entries/", 1, true))
			local broken = native_port(nil)
			broken.read = function() return nil, "store unreadable" end
			local refused = fixture({ roots = {
				{ id = "config", dir = "/cfg/" },
				{ id = "api_entries", name = "api_entries.json", port = broken },
			} })
			helpers.assert_nil(refused.create("pre_install"), "an unreadable native store refuses the backup")
		end)

		helpers.it("(config-backup-native-port) a native store that refuses or loses the value fails the restore", function()
			for _, fault in ipairs({ "refuse", "drop" }) do
				local port = native_port('{"entries":[1]}')
				local owner = fixture({ times = { "20260930-101500", "20260930-111500" }, roots = {
					{ id = "config", dir = "/cfg/" },
					{ id = "api_entries", name = "api_entries.json", port = port },
				} })
				local record = assert(owner.create("pre_install"))
				port.value = '{"entries":[]}'
				port[fault] = true
				local restored, reason = owner.restore(record.id)
				helpers.assert_eq(restored, false, fault)
				helpers.assert_eq(reason, "write", fault)
			end
		end)

		helpers.it("refuses to report a substituted staging file as restored", function()
			local owner, fs = fixture({ times = { "20260930-101500", "20260930-111500" } })
			local record = assert(owner.create("pre_install", {}))
			fs.files["/cfg/config.toml"] = "[changed]\n"
			-- A same-user process swaps the stage between its check and the rename.
			fs.io.replace = function(path)
				fs.files[path] = "foreign bytes\n"
				return true
			end
			local restored, reason, pre = owner.restore(record.id)
			helpers.assert_eq(restored, false, "foreign bytes never read as a success")
			helpers.assert_eq(reason, "write")
			helpers.assert_eq(fs.files[pre.path .. "/config/config.toml"], "[changed]\n",
				"the failure still names the backup of what was replaced")
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
				created_at = record.created_at, tag = "", from_version = "",
				files = { { root = "config", path = "../../etc/passwd" } } })
			local writes = #fs.writes
			local restored, reason = owner.restore(record.id)
			helpers.assert_eq(restored, false)
			helpers.assert_eq(reason, "missing")
			helpers.assert_eq(#fs.writes, writes, "nothing is written for a manifest leaving its root")
			helpers.assert_eq(owner.restore("../x"), false)
		end)

		helpers.it("refuses malformed manifest file inventories before restoring", function()
			for _, files in ipairs({
				{ hidden = { root = "config", path = "config.toml" } },
				{ { root = "config", path = "config.toml" }, { root = "config", path = "config.toml" } },
				{ [1] = { root = "config", path = "config.toml" }, [3] = { root = "config", path = "layers.toml" } },
			}) do
				local owner, fs, _, json = fixture()
				local record = assert(owner.create("pre_install", {}))
				fs.files[record.path .. "/backup.json"] = json.encode({ schema_version = 1, id = record.id,
					kind = "pre_install", created_at = record.created_at, tag = "", from_version = "", files = files })
				local writes = #fs.writes
				local restored, reason = owner.restore(record.id)
				helpers.assert_eq(restored, false, "a corrupt inventory must not report a successful restore")
				helpers.assert_eq(reason, "missing")
				helpers.assert_eq(#fs.writes, writes, "invalid inventory must not write configuration or pre-backup")
			end
		end)

		helpers.it("refuses a non-array or sparse manifest file list before any write", function()
			for _, files in ipairs({
				{ unexpected = { root = "config", path = "config.toml" } },
				{ [1] = { root = "config", path = "config.toml" },
					[3] = { root = "config", path = "layers.toml" } },
			}) do
				local owner, fs, _, json = fixture()
				local record = assert(owner.create("pre_install", {}))
				fs.files[record.path .. "/backup.json"] = json.encode({ schema_version = 1, id = record.id,
					kind = "pre_install", created_at = record.created_at, files = files })
				local writes = #fs.writes
				local restored, reason = owner.restore(record.id)
				helpers.assert_eq(restored, false)
				helpers.assert_eq(reason, "missing")
				helpers.assert_eq(#fs.writes, writes, "a truncated manifest must not publish a restore")
			end
		end)
	end)
end

return M
