--- _shared/lua/updater/config_backup.lua

--- ==============================================================================
--- MODULE: Configuration Backup (Shared)
--- DESCRIPTION:
--- Owns the timestamped backup of the whole user configuration that a release
--- install from the Versions window makes before anything is downloaded, and
--- the restore of such a backup. The rules (which files, where, what name) are
--- the `config_backup` block of _shared/modules/updater/defaults.json; the
--- macOS and Linux drivers supply the folders and the file I/O.
---
--- FEATURES & RATIONALE:
--- 1. The whole configuration: every file of the configuration folder whose
---    extension the rules list (config.toml, the tap-hold and layer files, the
---    personal hotstrings and shortcuts, the JSON settings), in every subfolder
---    but the excluded top-level ones (the backups themselves, the metrics
---    data). A driver adds the files that live outside that folder as file
---    roots (the Linux settings store).
--- 2. Verified and complete, or nothing: every copy is written create-only and
---    read back; the manifest is written last, so a folder without one is an
---    interrupted backup that latest() and restore() never use.
--- 3. Restore backs up first: the configuration it replaces becomes a
---    pre-restore backup, then every file is checked present before the first
---    one is written back.
--- 4. Paths are relative to named roots, never absolute, and a path climbing
---    out of its root is refused, so a manifest cannot write outside the
---    configuration.
--- 5. Pure Lua: no driver require, no io, no os.
--- ==============================================================================

local M = {}

M.SCHEMA_VERSION = 1

-- A backup id is a folder name; a release tag inside it keeps only these bytes.
local TAG_SAFE = "[^%w%._%-]"
local STAMP_PATTERN = "^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d$"
local ROOT_ID_PATTERN = "^[a-z][a-z_]*$"





-- ===================================
-- ===================================
-- ======= 1/ Rules and Paths ========
-- ===================================
-- ===================================

--- Validates the `config_backup` block of the shared updater defaults.
--- @param defaults table Decoded defaults.json.
--- @return table|nil rules { folder, manifest, kinds, extensions, excluded }
--- @return string|nil error Why the block is unusable.
function M.rules(defaults)
	local block = type(defaults) == "table" and defaults.config_backup or nil
	if type(block) ~= "table" then return nil, "updater defaults declare no config_backup block" end
	local function name(value)
		return type(value) == "string" and value ~= "" and not value:find("[/\\]") and value ~= "."
			and value ~= ".."
	end
	if not name(block.folder) or not name(block.manifest) then
		return nil, "config_backup needs a folder and a manifest name"
	end
	local kinds = block.kinds
	if type(kinds) ~= "table" or not name(kinds.pre_install) or not name(kinds.pre_restore)
		or kinds.pre_install == kinds.pre_restore then
		return nil, "config_backup needs two distinct kind prefixes"
	end
	if type(block.include_extensions) ~= "table" or #block.include_extensions == 0 then
		return nil, "config_backup lists no extension"
	end
	local extensions = {}
	for _, extension in ipairs(block.include_extensions) do
		if type(extension) ~= "string" or not extension:match("^%.[%w]+$") then
			return nil, "config_backup has an invalid extension"
		end
		extensions[#extensions + 1] = extension:lower()
	end
	local excluded = {}
	for _, dir in ipairs(type(block.exclude_dirs) == "table" and block.exclude_dirs or {}) do
		if not name(dir) then return nil, "config_backup has an invalid excluded folder" end
		excluded[dir] = true
	end
	-- Backing the backups up would copy every earlier backup into each new one.
	if not excluded[block.folder] then
		return nil, "config_backup must exclude its own folder"
	end
	return {
		folder = block.folder,
		manifest = block.manifest,
		kinds = { pre_install = kinds.pre_install, pre_restore = kinds.pre_restore },
		extensions = extensions,
		excluded = excluded,
	}, nil
end

--- Joins a directory and a relative path with exactly one slash.
--- @param dir string
--- @param relative string
--- @return string
local function join(dir, relative)
	return (dir:gsub("/+$", "")) .. "/" .. relative
end

--- The parent directory of a path.
--- @param path string
--- @return string
local function parent(path)
	return path:match("^(.*)/[^/]+$") or path
end

--- Whether a relative path stays inside its root: no absolute path, no empty,
--- "." or ".." segment.
--- @param relative any
--- @return boolean
local function contained(relative)
	if type(relative) ~= "string" or relative == "" or relative:sub(1, 1) == "/"
		or relative:find("\\", 1, true) or relative:find("\0", 1, true) then
		return false
	end
	for segment in (relative .. "/"):gmatch("([^/]*)/") do
		if segment == "" or segment == "." or segment == ".." then return false end
	end
	return true
end

M._contained = contained

--- Whether a file name ends with one of the rules' extensions.
--- @param rules table
--- @param name string
--- @return boolean
local function included(rules, name)
	local lower = name:lower()
	for _, extension in ipairs(rules.extensions) do
		if #lower > #extension and lower:sub(-#extension) == extension then return true end
	end
	return false
end





-- ===================================
-- ===================================
-- ======= 2/ The Owner ==============
-- ===================================
-- ===================================

--- Creates the backup owner of one driver.
--- @param options table {
---   rules = M.rules() result,
---   roots = array of { id, dir } (the first holds the backups) or { id, file },
---   io = { list(dir) -> entries|nil, err (entries: { name, kind = "file"|"dir"|"other" }),
---          read(path) -> content|nil, status ("absent" or an error),
---          make_dir(path) -> true|nil, err, create(path, content) -> true|nil, err
---          (create-only), replace(path, content) -> true|nil, err (atomic) },
---   json = { encode(value) -> string, decode(text) -> value|nil, err },
---   clock = function() -> { stamp = "YYYYMMDD-HHMMSS", iso = "YYYY-MM-DDTHH:MM:SSZ" },
---   logger, log }
--- @return table owner { create, latest, restore, folder }
function M.new(options)
	assert(type(options) == "table" and type(options.rules) == "table", "config_backup needs its rules")
	assert(type(options.roots) == "table" and #options.roots > 0, "config_backup needs its roots")
	local io_port, json, clock = options.io, options.json, options.clock
	assert(type(io_port) == "table" and type(io_port.list) == "function" and type(io_port.read) == "function"
		and type(io_port.make_dir) == "function" and type(io_port.create) == "function"
		and type(io_port.replace) == "function", "config_backup needs its file ports")
	assert(type(json) == "table" and type(json.encode) == "function" and type(json.decode) == "function",
		"config_backup needs a JSON codec")
	assert(type(clock) == "function", "config_backup needs a clock")
	local Logger, LOG = options.logger, options.log or "config_backup"
	assert(type(Logger) == "table", "config_backup needs a logger")
	local rules = options.rules

	local roots, by_id = {}, {}
	for index, root in ipairs(options.roots) do
		assert(type(root) == "table" and type(root.id) == "string" and root.id:match(ROOT_ID_PATTERN)
			and not by_id[root.id], "config_backup roots need distinct ids")
		assert((type(root.dir) == "string" and root.dir:sub(1, 1) == "/")
			or (type(root.file) == "string" and root.file:sub(1, 1) == "/"), "config_backup roots are absolute")
		assert(index > 1 or root.dir ~= nil, "the first config_backup root is the configuration folder")
		local entry = { id = root.id, dir = root.dir and (root.dir:gsub("/+$", "")) or nil, file = root.file }
		roots[#roots + 1] = entry
		by_id[root.id] = entry
	end
	local folder = join(roots[1].dir, rules.folder)
	local owner = { folder = folder }

	--- Collects every file of a folder root the rules include.
	--- @param root table
	--- @return table|nil files { { root, path } }
	--- @return string|nil error
	--- @return table skipped Relative paths neither file nor folder (a link to a folder).
	local function walk(root)
		local files, skipped = {}, {}
		local pending = { "" }
		while #pending > 0 do
			local relative = table.remove(pending, 1)
			local dir = relative == "" and root.dir or join(root.dir, relative)
			local entries, err = io_port.list(dir)
			if entries == nil then
				-- An absent configuration folder has nothing to back up.
				if relative == "" and err == "absent" then return files, nil, skipped end
				return nil, "cannot list " .. dir .. ": " .. tostring(err), skipped
			end
			table.sort(entries, function(a, b) return a.name < b.name end)
			for _, entry in ipairs(entries) do
				local name = entry.name
				local path = relative == "" and name or (relative .. "/" .. name)
				if type(name) ~= "string" or not contained(name) then
					return nil, "unexpected entry name in " .. dir, skipped
				elseif entry.kind == "dir" then
					if not (relative == "" and rules.excluded[name]) then pending[#pending + 1] = path end
				elseif entry.kind == "file" then
					if included(rules, name) then files[#files + 1] = { root = root.id, path = path } end
				else
					skipped[#skipped + 1] = path
				end
			end
		end
		return files, nil, skipped
	end

	--- Whether a file root lies inside the configuration folder, where the walk
	--- already copies it.
	--- @param file string
	--- @return boolean
	local function inside_config(file)
		local prefix = roots[1].dir .. "/"
		return file:sub(1, #prefix) == prefix
	end

	--- Reads the current bytes of every file to back up.
	--- @return table|nil entries { { root, path, source, content } }
	--- @return string|nil error
	--- @return table skipped
	local function snapshot()
		local entries, skipped = {}, {}
		for _, root in ipairs(roots) do
			if root.dir then
				local files, err, root_skipped = walk(root)
				for _, path in ipairs(root_skipped) do skipped[#skipped + 1] = root.id .. "/" .. path end
				if not files then return nil, err, skipped end
				for _, file in ipairs(files) do
					local source = join(root.dir, file.path)
					local content, status = io_port.read(source)
					if content == nil then
						return nil, "cannot read " .. source .. ": " .. tostring(status), skipped
					end
					entries[#entries + 1] = { root = root.id, path = file.path, source = source, content = content }
				end
			elseif not inside_config(root.file) then
				local content, status = io_port.read(root.file)
				if content ~= nil then
					local name = root.file:match("([^/]+)$")
					entries[#entries + 1] = { root = root.id, path = name, source = root.file, content = content }
				elseif status ~= "absent" then
					return nil, "cannot read " .. root.file .. ": " .. tostring(status), skipped
				end
			end
		end
		return entries, nil, skipped
	end

	--- Where one root's file lives.
	--- @param root_id string
	--- @param path string
	--- @return string|nil
	local function target(root_id, path)
		local root = by_id[root_id]
		if not root or not contained(path) then return nil end
		if root.dir then return join(root.dir, path) end
		return root.file:match("([^/]+)$") == path and root.file or nil
	end

	--- Makes one backup of the current configuration.
	--- @param kind string "pre_install" or "pre_restore".
	--- @param meta table|nil { tag, from_version } recorded in the manifest.
	--- @return table|nil record { id, path, kind, created_at, tag, from_version, files }
	--- @return string|nil error
	function owner.create(kind, meta)
		local prefix = rules.kinds[kind]
		assert(prefix ~= nil, "unknown config_backup kind")
		meta = type(meta) == "table" and meta or {}
		Logger.start(LOG, "Backing up the configuration (%s)…", kind)
		local time = clock()
		if type(time) ~= "table" or type(time.stamp) ~= "string" or not time.stamp:match(STAMP_PATTERN)
			or type(time.iso) ~= "string" then
			Logger.error(LOG, "Configuration backup refused: the clock gave no usable time.")
			return nil, "clock"
		end
		local entries, err, skipped = snapshot()
		if not entries then
			Logger.error(LOG, "Configuration backup refused: %s.", tostring(err))
			return nil, err
		end
		for _, path in ipairs(skipped) do
			Logger.warn(LOG, "Backup skips '%s': it is neither a file nor a folder of its own.", path)
		end
		local id = prefix .. "-" .. time.stamp
		local tag = type(meta.tag) == "string" and meta.tag:gsub(TAG_SAFE, "") or ""
		if tag ~= "" then id = id .. "-" .. tag end
		local made, make_err = io_port.make_dir(folder)
		if not made then
			Logger.error(LOG, "Configuration backup refused: cannot create %s: %s.", folder, tostring(make_err))
			return nil, "cannot create " .. folder
		end
		-- Two backups within one second get distinct folders: the manifest's
		-- create-only write refuses an existing one.
		local base, suffix, path = id, 1, join(folder, id)
		while io_port.read(join(path, rules.manifest)) ~= nil or (io_port.list(path)) ~= nil do
			suffix = suffix + 1
			id = base .. "-" .. suffix
			path = join(folder, id)
		end
		local manifest_files = {}
		for _, entry in ipairs(entries) do
			local copy = join(path, entry.root .. "/" .. entry.path)
			local dir_ok, dir_err = io_port.make_dir(parent(copy))
			local written, write_err = false, dir_err
			if dir_ok then written, write_err = io_port.create(copy, entry.content) end
			if not written then
				Logger.error(LOG, "Configuration backup failed writing %s: %s.", copy, tostring(write_err))
				return nil, "cannot write " .. copy
			end
			local back = io_port.read(copy)
			if back ~= entry.content then
				Logger.error(LOG, "Configuration backup failed: %s does not read back as written.", copy)
				return nil, "verification failed for " .. copy
			end
			manifest_files[#manifest_files + 1] = { root = entry.root, path = entry.path }
		end
		local record = {
			schema_version = M.SCHEMA_VERSION,
			id = id,
			kind = kind,
			created_at = time.iso,
			tag = type(meta.tag) == "string" and meta.tag or "",
			from_version = type(meta.from_version) == "string" and meta.from_version or "",
			files = manifest_files,
		}
		local encoded, encode_err = json.encode(record)
		if type(encoded) ~= "string" then
			Logger.error(LOG, "Configuration backup failed encoding its manifest: %s.", tostring(encode_err))
			return nil, "cannot encode the manifest"
		end
		local wrote, manifest_err = io_port.create(join(path, rules.manifest), encoded)
		if not wrote then
			Logger.error(LOG, "Configuration backup failed writing its manifest: %s.", tostring(manifest_err))
			return nil, "cannot write the manifest"
		end
		record.path = path
		Logger.success(LOG, "Configuration backed up to %s (%d file(s)).", path, #manifest_files)
		return record, nil
	end

	--- Reads and validates one backup's manifest.
	--- @param id string Backup folder name.
	--- @return table|nil record
	--- @return string|nil error
	local function load(id)
		if type(id) ~= "string" or not contained(id) or id:find("/", 1, true) then return nil, "invalid id" end
		local path = join(folder, id)
		local raw, status = io_port.read(join(path, rules.manifest))
		if raw == nil then return nil, "no manifest (" .. tostring(status) .. ")" end
		local record, decode_err = json.decode(raw)
		if type(record) ~= "table" or decode_err then return nil, "unreadable manifest" end
		if record.schema_version ~= M.SCHEMA_VERSION or record.id ~= id
			or type(record.files) ~= "table" or rules.kinds[record.kind] == nil then
			return nil, "unexpected manifest"
		end
		for _, file in ipairs(record.files) do
			if type(file) ~= "table" or not target(file.root, file.path) then
				return nil, "manifest names a file outside the configuration"
			end
		end
		record.path = path
		return record, nil
	end

	--- The newest complete backup of one kind, or nil when there is none.
	--- @param kind string
	--- @return table|nil record
	function owner.latest(kind)
		local prefix = rules.kinds[kind]
		assert(prefix ~= nil, "unknown config_backup kind")
		local entries = io_port.list(folder)
		if entries == nil then return nil end
		local best = nil
		for _, entry in ipairs(entries) do
			local name = entry.name
			if entry.kind == "dir" and type(name) == "string" and name:sub(1, #prefix + 1) == prefix .. "-" then
				local record = load(name)
				if record and record.kind == kind
					and (best == nil or tostring(record.created_at) > tostring(best.created_at)
						or (record.created_at == best.created_at and record.id > best.id)) then
					best = record
				end
			end
		end
		return best
	end

	--- Puts a backup back: backs the current configuration up first, checks
	--- every copy is present, then writes each file back.
	--- @param id string Backup folder name.
	--- @return boolean restored
	--- @return string|nil reason "missing", "backup" or "write"
	--- @return table|nil pre_restore The backup of the replaced configuration.
	function owner.restore(id)
		Logger.start(LOG, "Restoring the configuration backup %s…", tostring(id))
		local record, err = load(id)
		if not record then
			Logger.error(LOG, "Restore refused: backup %s is %s.", tostring(id), tostring(err))
			return false, "missing", nil
		end
		local copies = {}
		for index, file in ipairs(record.files) do
			local content = io_port.read(join(record.path, file.root .. "/" .. file.path))
			if content == nil then
				Logger.error(LOG, "Restore refused: %s/%s is missing from the backup.", file.root, file.path)
				return false, "missing", nil
			end
			copies[index] = content
		end
		local pre, pre_err = owner.create("pre_restore", { from_version = record.from_version })
		if not pre then
			Logger.error(LOG, "Restore refused: the current configuration could not be backed up (%s).",
				tostring(pre_err))
			return false, "backup", nil
		end
		for index, file in ipairs(record.files) do
			local destination = target(file.root, file.path)
			local dir_ok, dir_err = io_port.make_dir(parent(destination))
			local written, write_err = false, dir_err
			if dir_ok then written, write_err = io_port.replace(destination, copies[index]) end
			if not written then
				Logger.error(LOG, "Restore failed writing %s: %s; the replaced configuration is in %s.",
					destination, tostring(write_err), pre.path)
				return false, "write", pre
			end
		end
		Logger.success(LOG, "Configuration restored from %s (%d file(s)).", record.path, #record.files)
		return true, nil, pre
	end

	return owner
end

return M
