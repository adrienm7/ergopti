--- adapters/file_system.lua

--- ==============================================================================
--- MODULE: FileSystem Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the FileSystem port contract defined in
--- static/ergopti_plus/_shared/core/ports/FileSystem.spec.js. Wraps Lua's io.open and
--- hs.fs behind the five canonical methods (read, write, append, exists, delete)
--- so domain modules perform file I/O without coupling to OS-specific APIs.
---
--- FEATURES & RATIONALE:
--- 1. UTF-8 everywhere: all reads and writes use the "r"/"w"/"a" modes which
---    pass raw bytes through. Hammerspoon on macOS runs in a UTF-8 locale so
---    string content is already UTF-8 by default.
--- 2. Fail-safe returns: read() returns nil on any error; write/append/delete
---    return false. No exceptions propagate to the caller.
--- 3. Defensive pcall: every io.open / hs.fs call is wrapped in pcall because
---    permission errors and locked files can panic the Lua runtime.
--- 4. Classified creation: prepare_parent_for_create() creates only missing
---    directory components on a previously resolved route, then revalidates
---    every observed symlink before a caller may classify the final file.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("infra.logger")
local FsDir  = require("infra.fs_dir")

local LOG = "adapters.file_system"

local TEMP_INSTANCE_TAG = tostring({}):gsub("[^%w]", "")
local _temp_sequence = 0

local STAGING_LOCK_SUFFIX = ".ergoptiplus-stage-lock"
local STAGING_PAYLOAD_NAME = "payload"
local WRITE_LOCK_SUFFIX = ".ergoptiplus-write-lock-v1"
local ENOENT_ERROR_CODE = 2
local MAX_SYMLINK_HOPS = 32
local MAX_STAGING_RESERVATION_ATTEMPTS = 64

-- fcntl locks are per process, so a second Lua entry in this Hammerspoon
-- process could otherwise appear to reacquire its own kernel lock. The handle
-- is retained until explicit release; macOS releases the kernel lock if the
-- process dies, while the stable empty lock file intentionally remains.
local _held_write_locks = {}
-- A staging owner whose exact release did not commit remains authoritative
-- across later writes. No successor may reserve another sidecar until this
-- debt settles, which bounds transient cleanup failures to one owned artifact.
local _staging_cleanup_debt = nil
local acquire_cooperative_write_lock
local release_cooperative_write_lock




-- ========================================
-- ========================================
-- ======= 1/ Adapter Methods =============
-- ========================================
-- ========================================

--- Reads the entire contents of a file as a string.
--- @param path string Absolute path to the file.
--- @return string|nil File contents, or nil on any error.
-- Defined after the lstat helpers so both the legacy read() contract and the
-- classified API use the same fail-closed implementation.

--- Ensures all intermediate directories on the path exist.
--- Walks up the directory chain and creates any missing nodes via hs.fs.mkdir.
--- Silently succeeds when the full chain already exists.
--- @param dir string Absolute directory path to create.
local function ensure_dir(dir)
	if not dir or dir == "" or dir == "/" then return end
	-- Skip if the directory already exists
	if hs.fs.attributes(dir, "mode") == "directory" then return end
	-- Recursively ensure the parent exists first
	local parent = dir:match("^(.+)/[^/]+$")
	if parent and parent ~= dir then ensure_dir(parent) end
	pcall(function() hs.fs.mkdir(dir) end)
end

--- Returns the parent directory of a slash-separated path.
--- @param path string Filesystem path.
--- @return string|nil parent Parent directory, when present.
local function parent_dir(path)
	return path:match("^(.+)/[^/]+$")
end

--- Lexically removes `.` and `..` segments without requiring the path to exist.
--- This is required for a dangling symlink whose relative target cannot be
--- canonicalized by hs.fs.pathToAbsolute().
--- @param path string Slash-separated path.
--- @return string normalized_path
local function normalize_path(path)
	local drive = path:match("^(%a:)/")
	local absolute = path:sub(1, 1) == "/" or drive ~= nil
	local prefix = drive and (drive .. "/") or (absolute and "/" or "")
	local body = drive and path:sub(4) or (path:sub(1, 1) == "/" and path:sub(2) or path)
	local parts = {}
	for part in body:gmatch("[^/]+") do
		if part == ".." then
			if #parts > 0 and parts[#parts] ~= ".." then
				table.remove(parts)
			elseif not absolute then
				parts[#parts + 1] = part
			end
		elseif part ~= "." and part ~= "" then
			parts[#parts + 1] = part
		end
	end
	local joined = table.concat(parts, "/")
	if joined == "" then return prefix ~= "" and prefix or "." end
	return prefix .. joined
end

--- Resolves one symlink target, accepting relative values defensively even
--- though current Hammerspoon documents `target` as absolute.
--- @param link_path string Pathname containing the link.
--- @param target string Target returned by hs.fs.symlinkAttributes().
--- @return string absolute_target
local function resolve_link_target(link_path, target)
	if target:sub(1, 1) == "/" or target:match("^%a:/") then
		return normalize_path(target)
	end
	local parent = parent_dir(link_path) or "."
	return normalize_path(parent .. "/" .. target)
end

--- Reads lstat-style attributes without following the final symlink.
--- @param path string Filesystem path.
--- @return table|nil attributes
--- @return string|nil error_message
local function symlink_attributes(path)
	if not hs or not hs.fs or type(hs.fs.symlinkAttributes) ~= "function" then
		return nil, "hs.fs.symlinkAttributes is unavailable"
	end
	local call_ok, attributes, attributes_err = pcall(hs.fs.symlinkAttributes, path)
	if not call_ok then return nil, tostring(attributes) end
	return attributes, attributes_err
end

--- Proves that one pathname is absent without parsing localized lstat errors.
--- Hammerspoon's symlinkAttributes() exposes `nil, error` but no errno. A
--- successful parent listing that excludes the basename is therefore the only
--- portable absence proof. The iterator is exhausted even after a match so its
--- directory handle is not left open until garbage collection.
--- @param path string Pathname whose lstat returned nil.
--- @param known_parent string|nil Parent already established by a component walk.
--- @param known_basename string|nil Basename already established by a component walk.
--- @return boolean absent
--- @return string|nil error_message
local function parent_listing_proves_absence(path, known_parent, known_basename)
	if type(FsDir) ~= "table" or type(FsDir.try_entries) ~= "function" then
		return false, "infra.fs_dir.try_entries is unavailable"
	end
	local basename = known_basename or path:match("([^/]+)$")
	if type(basename) ~= "string" or basename == "" then
		return false, "pathname has no basename"
	end
	local parent = known_parent or parent_dir(path)
	if parent == nil then parent = path:sub(1, 1) == "/" and "/" or "." end
	if parent:match("^%a:$") then parent = parent .. "/" end

	local entries, listed, list_err = FsDir.try_entries(parent)
	if listed ~= true or type(entries) ~= "table" then
		return false, "cannot list parent '" .. parent .. "': " .. tostring(list_err)
	end
	local found = false
	for _, entry in ipairs(entries) do
		if entry == basename then found = true end
	end
	if found then
		return false, "parent lists '" .. basename .. "' but lstat failed"
	end
	return true
end

--- Returns attributes, a proven-absent nil, or an error for an unknown path.
--- @param path string Pathname to inspect.
--- @param known_parent string|nil Parent already established by a component walk.
--- @param known_basename string|nil Basename already established by a component walk.
--- @return table|nil attributes
--- @return string|nil error_message
local function inspect_path(path, known_parent, known_basename)
	local attributes, attributes_err = symlink_attributes(path)
	if type(attributes) == "table" then
		if attributes_err ~= nil then
			return nil, "lstat returned attributes and an error for '" .. path .. "': " .. tostring(attributes_err)
		end
		return attributes
	end
	if attributes ~= nil then
		return nil, "lstat returned an unexpected value for '" .. path .. "'"
	end
	local absent, absence_err = parent_listing_proves_absence(path, known_parent, known_basename)
	if absent then return nil end
	local details = tostring(absence_err)
	if attributes_err ~= nil then details = details .. "; lstat: " .. tostring(attributes_err) end
	return nil, "cannot inspect '" .. path .. "': " .. details
end

--- Splits a slash-separated path into its root and ordered components.
--- Dot segments are deliberately preserved until preceding symlinks resolve.
--- @param path string Filesystem path.
--- @return string root Empty, `/`, or a Windows drive root used by tests.
--- @return table components Ordered path components.
local function split_path(path)
	local drive = path:match("^(%a:)/")
	local root = drive and (drive .. "/") or (path:sub(1, 1) == "/" and "/" or "")
	local body = drive and path:sub(4) or (root == "/" and path:sub(2) or path)
	local components = {}
	for component in body:gmatch("[^/]+") do components[#components + 1] = component end
	return root, components
end

--- Appends one component to a root or partial path.
--- @param prefix string Root or already-built prefix.
--- @param component string Next path component.
--- @return string path Combined path.
local function append_component(prefix, component)
	if prefix == "" then return component end
	if prefix:sub(-1) == "/" then return prefix .. component end
	return prefix .. "/" .. component
end

--- Resolves a destination through Unix symlinks in every path component,
--- including a final link whose target exists. Resolving only the final pathname is not
--- sufficient: Karabiner officially supports symlinking its configuration
--- directory, and pathToAbsolute returns nil while the final JSON is absent.
--- The returned chain is later revalidated before and after publication.
--- @param path string Requested destination.
--- @return string|nil real_path Resolved target or nil on an unsafe lookup.
--- @return table chain Symlink path/target observations.
--- @return string|nil error_message
local function resolve_write_path(path)
	-- POSIX resolves components from left to right: in `link/../file`, `..`
	-- applies to the link target, not to the directory containing the link.
	-- Keep the caller's initial component order and normalize only after a
	-- symlink substitution has made that ordering explicit.
	local current = path
	local chain = {}
	local visited_links = {}
	local hop_count = 0

	while true do
		local root, components = split_path(current)
		local prefix = root
		local replaced = false

		for index, component in ipairs(components) do
			local component_parent = prefix == "" and "." or prefix
			prefix = append_component(prefix, component)
			local attributes, attributes_err = inspect_path(prefix, component_parent, component)
			if attributes_err ~= nil then return nil, chain, attributes_err end
			if type(attributes) == "table" and attributes.mode == "link" then
				hop_count = hop_count + 1
				if hop_count > MAX_SYMLINK_HOPS then
					return nil, chain, "symlink chain exceeds " .. tostring(MAX_SYMLINK_HOPS) .. " hops"
				end
				if visited_links[prefix] then
					return nil, chain, "symlink cycle detected at " .. prefix
				end
				visited_links[prefix] = true
				if type(attributes.target) ~= "string" or attributes.target == "" then
					return nil, chain, "symlink target is unavailable for " .. prefix
				end

				local target = resolve_link_target(prefix, attributes.target)
				chain[#chain + 1] = {
					path = prefix,
					target = target,
					dev = attributes.dev,
					ino = attributes.ino,
				}
				for remainder = index + 1, #components do
					target = append_component(target, components[remainder])
				end
				current = normalize_path(target)
				replaced = true
				break
			end

			if attributes == nil then
				-- The parent was listed successfully and excluded this component.
				-- No descendant can exist yet, so keep the complete destination for
				-- ensure_dir() instead of probing an unlistable missing child.
				return current, chain
			end
			if index < #components and attributes.mode ~= "directory" then
				return nil, chain, "non-directory path component: " .. prefix
			end
		end

		if not replaced then return current, chain end
	end
end

--- Confirms that every observed symlink still has the same identity and target.
--- @param requested_path string Original destination.
--- @param expected_path string Previously resolved target.
--- @param chain table Previously observed symlink chain.
--- @return boolean unchanged
--- @return string|nil error_message
local function revalidate_write_path(requested_path, expected_path, chain)
	for _, observed in ipairs(chain) do
		local attributes, attributes_err = inspect_path(observed.path)
		if attributes_err ~= nil then
			return false, "symlink revalidation failed: " .. tostring(attributes_err)
		end
		if type(attributes) ~= "table" or attributes.mode ~= "link" then
			return false, "symlink disappeared or changed type: " .. observed.path
		end
		if type(attributes.target) ~= "string"
			or resolve_link_target(observed.path, attributes.target) ~= observed.target then
			return false, "symlink target changed: " .. observed.path
		end
		if observed.dev ~= nil and observed.ino ~= nil
			and (attributes.dev ~= observed.dev or attributes.ino ~= observed.ino) then
			return false, "symlink identity changed: " .. observed.path
		end
	end

	local current_path, _, resolve_err = resolve_write_path(requested_path)
	if not current_path then return false, resolve_err end
	if normalize_path(current_path) ~= normalize_path(expected_path) then
		return false, "resolved target changed before publication"
	end
	return true
end

--- Resolves a pathname for reading while preserving the distinction between a
--- proven missing final entry and every unsafe lookup failure. A missing path
--- prefix and a dangling final symlink are errors: neither authorizes creation.
--- @param path string Requested pathname.
--- @return string|nil resolved_path
--- @return string status `present`, `absent`, or `error`.
--- @return string|nil detail
--- @return table chain Observed symlinks for post-read revalidation.
--- @return table|nil final_identity Final regular-file lstat observation.
local function classify_read_path(path)
	local current = path
	local chain = {}
	local visited_links = {}
	local hop_count = 0
	local final_link_requires_target = false

	while true do
		local root, components = split_path(current)
		if #components == 0 then return nil, "error", "pathname has no final component", chain end
		local prefix = root
		local replaced = false

		for index, component in ipairs(components) do
			local component_parent = prefix == "" and "." or prefix
			prefix = append_component(prefix, component)
			local attributes, attributes_err = inspect_path(prefix, component_parent, component)
			if attributes_err ~= nil then return nil, "error", attributes_err, chain end
			if attributes == nil then
				if index < #components then
					return nil, "error", "missing path prefix: " .. prefix, chain
				end
				if final_link_requires_target then
					return nil, "error", "dangling final symlink resolves to: " .. prefix, chain
				end
				return normalize_path(prefix), "absent", nil, chain
			end

			if attributes.mode == "link" then
				hop_count = hop_count + 1
				if hop_count > MAX_SYMLINK_HOPS then
					return nil, "error", "symlink chain exceeds " .. tostring(MAX_SYMLINK_HOPS) .. " hops", chain
				end
				if visited_links[prefix] then
					return nil, "error", "symlink cycle detected at " .. prefix, chain
				end
				visited_links[prefix] = true
				if type(attributes.target) ~= "string" or attributes.target == "" then
					return nil, "error", "symlink target is unavailable for " .. prefix, chain
				end

				local target = resolve_link_target(prefix, attributes.target)
				chain[#chain + 1] = {
					path = prefix,
					target = target,
					dev = attributes.dev,
					ino = attributes.ino,
				}
				if index == #components then final_link_requires_target = true end
				for remainder = index + 1, #components do
					target = append_component(target, components[remainder])
				end
				current = normalize_path(target)
				replaced = true
				break
			end

			if index < #components and attributes.mode ~= "directory" then
				return nil, "error", "non-directory path component: " .. prefix, chain
			end
			if index == #components then
				if attributes.mode ~= "file" then
					return nil, "error", "pathname is not a regular file: " .. prefix, chain
				end
				return normalize_path(prefix), "present", nil, chain, {
					path = normalize_path(prefix),
					mode = attributes.mode,
					dev = attributes.dev,
					ino = attributes.ino,
					size = attributes.size,
					modification = attributes.modification,
					change = attributes.change,
				}
			end
		end

		if not replaced then return nil, "error", "pathname resolution did not terminate", chain end
	end
end

--- Revalidates the final regular-file identity after the stream is closed.
--- Every lstat attribute captured before open is compared when available.
--- The stream length is also checked against the pre-open size so a truncate
--- and restore between the two metadata probes cannot publish partial bytes.
--- @param expected table Final lstat observation captured before open.
--- @param content string Bytes read from the closed stream.
--- @return boolean unchanged
--- @return string|nil error_message
local function revalidate_read_identity(expected, content)
	if type(expected) ~= "table" or type(expected.path) ~= "string" then
		return false, "final file identity was not captured"
	end
	local current, inspect_err = inspect_path(expected.path)
	if inspect_err ~= nil then return false, inspect_err end
	if type(current) ~= "table" or current.mode ~= "file" then
		return false, "final regular file disappeared or changed type: " .. expected.path
	end
	if expected.dev ~= nil and expected.ino ~= nil
			and (current.dev ~= expected.dev or current.ino ~= expected.ino) then
		return false, "final regular file identity changed: " .. expected.path
	end
	for _, field in ipairs({ "size", "modification", "change" }) do
		if expected[field] ~= nil and current[field] ~= expected[field] then
			return false, "final regular file " .. field .. " changed: " .. expected.path
		end
	end
	if type(expected.size) == "number" and #content ~= expected.size then
		return false, string.format(
			"read byte length %d does not match captured size %d: %s",
			#content,
			expected.size,
			expected.path
		)
	end
	return true
end

--- Reads a regular file without turning lookup or stream failures into absence.
--- @param path string Absolute path to the file.
--- @return string|nil content
--- @return string status `ok`, `absent`, or `error`.
--- @return string|nil detail
function M.read_with_status(path)
	if type(path) ~= "string" or path == "" then
		return nil, "error", "path must be a non-empty string"
	end

	-- Preserve the caller's component order until every preceding symlink has
	-- resolved. POSIX applies `..` to the link target in `link/../file`; lexical
	-- normalization here would silently inspect a different pathname.
	local requested_path = path
	local resolved_path, classification, detail, chain, final_identity = classify_read_path(requested_path)
	if classification == "absent" then return nil, "absent", detail end
	if classification ~= "present" then
		Logger.error(LOG, "read_with_status(): cannot inspect '%s' safely — %s", path, tostring(detail))
		return nil, "error", detail
	end

	local open_ok, fh, open_err = pcall(io.open, resolved_path, "r")
	if not open_ok or not fh then
		detail = tostring((open_ok and open_err) or fh or "open failed")
		Logger.error(LOG, "read_with_status(): cannot open '%s' — %s", path, detail)
		return nil, "error", detail
	end
	local read_ok, content, read_err = pcall(fh.read, fh, "*a")
	local close_ok, closed, close_err = pcall(fh.close, fh)
	if not read_ok or type(content) ~= "string" then
		detail = tostring((read_ok and read_err) or content or "read failed")
		Logger.error(LOG, "read_with_status(): read failed for '%s' — %s", path, detail)
		return nil, "error", detail
	end
	if not close_ok or closed ~= true then
		detail = tostring((close_ok and close_err) or closed or "close failed")
		Logger.error(LOG, "read_with_status(): close failed for '%s' — %s", path, detail)
		return nil, "error", detail
	end

	local unchanged, revalidate_err = revalidate_write_path(requested_path, resolved_path, chain)
	if not unchanged then
		Logger.error(LOG, "read_with_status(): pathname changed while reading '%s' — %s",
			path, tostring(revalidate_err))
		return nil, "error", revalidate_err
	end
	unchanged, revalidate_err = revalidate_read_identity(final_identity, content)
	if not unchanged then
		Logger.error(LOG, "read_with_status(): file identity changed while reading '%s' — %s",
			path, tostring(revalidate_err))
		return nil, "error", revalidate_err
	end
	return content, "ok"
end

--- Reads the entire contents of a file as a string.
--- @param path string Absolute path to the file.
--- @return string|nil File contents, or nil on absence/error.
function M.read(path)
	local content, status, detail = M.read_with_status(path)
	if status == "absent" then
		Logger.debug(LOG, "read(): '%s' is absent.", tostring(path))
	elseif status == "error" then
		Logger.debug(LOG, "read(): '%s' failed — %s", tostring(path), tostring(detail))
	end
	return content
end

--- Creates every missing component of one already-resolved directory route.
--- Existing symlinks are rejected here: resolve_write_path() must have replaced
--- them with their observed targets before this helper receives the route.
--- @param dir string Symlink-resolved directory path.
--- @return boolean prepared
--- @return string|nil error_message
local function create_directory_chain(dir)
	if not hs or not hs.fs or type(hs.fs.mkdir) ~= "function" then
		return false, "hs.fs.mkdir is unavailable"
	end

	local root, components = split_path(dir)
	local prefix = root
	if #components == 0 then
		local attributes, inspect_err = inspect_path(dir)
		if inspect_err ~= nil then return false, inspect_err end
		if type(attributes) ~= "table" or attributes.mode ~= "directory" then
			return false, "parent route is not a directory: " .. tostring(dir)
		end
		return true
	end

	for _, component in ipairs(components) do
		local component_parent = prefix == "" and "." or prefix
		prefix = append_component(prefix, component)
		local attributes, inspect_err = inspect_path(prefix, component_parent, component)
		if inspect_err ~= nil then return false, inspect_err end
		if attributes == nil then
			local mkdir_ok, created, mkdir_err = pcall(hs.fs.mkdir, prefix)
			local mkdir_detail = tostring(mkdir_ok and (mkdir_err or created) or created)
			attributes, inspect_err = inspect_path(prefix, component_parent, component)
			if inspect_err ~= nil then return false, inspect_err end
			if (not mkdir_ok or created ~= true or mkdir_err ~= nil) and attributes == nil then
				return false, string.format(
					"cannot create parent directory '%s': %s",
					prefix,
					mkdir_detail
				)
			end
			if attributes == nil then
				return false, "mkdir reported success but the directory is absent: " .. prefix
			end
		end
		if attributes.mode ~= "directory" then
			return false, "parent route component is not a directory: " .. prefix
		end
	end

	return true
end

--- Prepares the parent of a destination before a classified read/create flow.
--- The requested route is resolved first, every observed symlink is revalidated
--- before and after directory creation, and permission or lookup ambiguity fails
--- closed. This method never shells out and always returns a literal boolean.
--- @param path string Absolute destination path.
--- @return boolean prepared
--- @return string|nil error_message
function M.prepare_parent_for_create(path)
	if type(path) ~= "string" or path == "" then
		return false, "path must be a non-empty string"
	end

	local call_ok, prepared, detail = pcall(function()
		local resolved_path, chain, resolve_err = resolve_write_path(path)
		if not resolved_path then return false, resolve_err or "path resolution failed" end

		local unchanged, revalidate_err = revalidate_write_path(path, resolved_path, chain)
		if not unchanged then return false, revalidate_err end

		local dir = parent_dir(resolved_path)
		if dir == nil then dir = resolved_path:sub(1, 1) == "/" and "/" or "." end
		local created, create_err = create_directory_chain(dir)
		if created ~= true then return false, create_err end

		unchanged, revalidate_err = revalidate_write_path(path, resolved_path, chain)
		if not unchanged then return false, revalidate_err end
		return true
	end)

	if not call_ok then
		detail = tostring(prepared)
		Logger.error(LOG, "prepare_parent_for_create(): unexpected error for '%s' — %s", path, detail)
		return false, detail
	end
	if prepared ~= true then
		detail = tostring(detail or "parent preparation failed")
		Logger.error(LOG, "prepare_parent_for_create(): refused '%s' — %s", path, detail)
		return false, detail
	end
	return true
end

--- Builds a staging candidate beside the destination for POSIX rename.
--- The tag and sequence reduce collisions, but do not prove uniqueness across
--- processes. reserve_staging_area() supplies that proof with an atomic mkdir.
--- @param real_path string Resolved destination.
--- @return string tmp_path Unique adjacent staging path.
local function next_staging_path(real_path)
	_temp_sequence = _temp_sequence + 1
	return string.format("%s.tmp.%s.%d", real_path, TEMP_INSTANCE_TAG, _temp_sequence)
end

--- Atomically reserves a private adjacent staging pathname.
--- hs.fs.mkdir has create-only semantics on macOS: exactly one process can own
--- a candidate lock directory. The payload lives inside that newly-created
--- directory, so no lstat result is needed to prove that its name is private.
--- The directory remains adjacent to the destination, keeping publication on
--- one filesystem.
--- @param real_path string Resolved destination.
--- @return table|nil area Owned { payload_path, lock_path } pair.
--- @return string|nil error_message
local function reserve_staging_area(real_path)
	if not hs or not hs.fs or type(hs.fs.mkdir) ~= "function" then
		return nil, "hs.fs.mkdir is unavailable; exclusive staging is unsupported"
	end

	local last_err = nil
	for _ = 1, MAX_STAGING_RESERVATION_ATTEMPTS do
		local lock_path = next_staging_path(real_path) .. STAGING_LOCK_SUFFIX
		local payload_path = lock_path .. "/" .. STAGING_PAYLOAD_NAME
		local call_ok, created, mkdir_err = pcall(hs.fs.mkdir, lock_path)
		if call_ok and created == true then
			return { payload_path = payload_path, lock_path = lock_path }
		elseif not call_ok then
			last_err = tostring(created)
		else
			-- A unique next candidate is cheaper and safer than trying to classify
			-- whether this refusal was a collision, permission error, or transient
			-- filesystem failure.
			last_err = tostring(mkdir_err or created)
		end
	end

	return nil, string.format(
		"cannot reserve a private staging path after %d attempts: %s",
		MAX_STAGING_RESERVATION_ATTEMPTS,
		tostring(last_err)
	)
end

--- Removes a pathname or accepts authoritative absence after a concurrent delete.
--- @param path string Pathname to remove.
--- @return boolean removed_or_absent
--- @return string|nil error_message
local function remove_path_or_absent(path)
	local call_ok, removed, remove_err, remove_code = pcall(os.remove, path)
	if call_ok and removed == true then return true end
	if call_ok and remove_code == ENOENT_ERROR_CODE then return true end
	return false, string.format(
		"%s (errno=%s)",
		tostring(call_ok and remove_err or removed),
		tostring(remove_code)
	)
end

--- Releases one staging area owned through its exclusive lock directory.
--- An unpublished payload is removed before its lock. A published payload is
--- never touched: rename consumed our file, so that pathname may already belong
--- to another owner by the time cleanup runs.
--- @param area table Owned { payload_path, lock_path } pair.
--- @param payload_published boolean Whether rename already consumed the payload.
--- @return boolean released
--- @return string|nil error_message
local function release_staging_area(area, payload_published)
	if type(area) ~= "table" then return true end
	if payload_published ~= true then
		local payload_removed, payload_err = remove_path_or_absent(area.payload_path)
		if not payload_removed then return false, payload_err end
	end
	if not hs or not hs.fs or type(hs.fs.rmdir) ~= "function" then
		return false, "hs.fs.rmdir is unavailable; staging lock retained at " .. tostring(area.lock_path)
	end
	local call_ok, removed, rmdir_err = pcall(hs.fs.rmdir, area.lock_path)
	if not call_ok or removed ~= true then
		return false, tostring(call_ok and rmdir_err or removed)
	end
	return true
end

--- Builds the exact cleanup owner transferred by a staging transaction.
--- @param operation string Public operation label.
--- @param requested_path string Caller-visible destination.
--- @param resolved_path string Symlink-resolved destination.
--- @param route_chain table Observed symlink route.
--- @param area table Owned staging area.
--- @param payload_published boolean Whether publication consumed the payload.
--- @return table owner
local function new_staging_cleanup_owner(
	operation,
	requested_path,
	resolved_path,
	route_chain,
	area,
	payload_published
)
	return {
		operation = operation,
		requested_path = requested_path,
		resolved_path = resolved_path,
		route_chain = route_chain,
		area = area,
		payload_published = payload_published == true,
	}
end

--- Retains one exact staging owner after its release could not commit.
--- @param owner table Cleanup owner.
--- @param context string Failure phase.
--- @param reason string|nil Concrete release refusal.
--- @return boolean false
--- @return string detail Stable fail-closed result.
local function retain_staging_cleanup_debt(owner, context, reason)
	if type(owner) ~= "table" or type(owner.area) ~= "table" then
		return false, "prior staging cleanup remains pending: invalid cleanup owner"
	end
	if _staging_cleanup_debt ~= nil and _staging_cleanup_debt ~= owner then
		return false, "prior staging cleanup remains pending: another cleanup owner is retained"
	end
	owner.context = tostring(context or "release failure")
	owner.reason = tostring(reason or "release refused")
	_staging_cleanup_debt = owner
	Logger.warn(
		LOG,
		"%s(): retaining staging cleanup debt for '%s' after %s — %s.",
		tostring(owner.operation or "write"),
		tostring(owner.area.lock_path),
		owner.context,
		owner.reason
	)
	return false, "prior staging cleanup remains pending: " .. owner.reason
end

--- Releases one exact staging owner while its destination lock is held.
--- Route revalidation prevents a later symlink retarget from redirecting cleanup.
--- @param owner table Cleanup owner.
--- @param context string Release phase.
--- @return boolean released
--- @return string|nil detail
local function release_staging_owner(owner, context)
	local unchanged, revalidate_err = revalidate_write_path(
		owner.requested_path,
		owner.resolved_path,
		owner.route_chain
	)
	if not unchanged then
		return retain_staging_cleanup_debt(owner, context, revalidate_err)
	end
	local released, release_err = release_staging_area(
		owner.area,
		owner.payload_published == true
	)
	if not released then
		return retain_staging_cleanup_debt(owner, context, release_err)
	end
	if _staging_cleanup_debt == owner then _staging_cleanup_debt = nil end
	return true
end

--- Retries the exact retained cleanup owner before any successor write.
--- @return boolean settled
--- @return string|nil detail
local function settle_staging_cleanup_debt()
	local owner = _staging_cleanup_debt
	if owner == nil then return true end

	local write_lock, lock_err = acquire_cooperative_write_lock(owner.resolved_path)
	if not write_lock then
		local detail = "prior staging cleanup remains pending: "
			.. tostring(lock_err or "cooperative write lock refused")
		Logger.error(LOG, "%s(): %s.", tostring(owner.operation or "write"), detail)
		return false, detail
	end

	local released, release_err = release_staging_owner(owner, "retry")
	local lock_released, lock_release_err = release_cooperative_write_lock(write_lock)
	if not lock_released then
		local prefix = _staging_cleanup_debt == owner
			and "prior staging cleanup remains pending: "
			or "prior staging cleanup settled but its cooperative lock release failed: "
		local detail = prefix .. tostring(lock_release_err or "cooperative write lock release failed")
		Logger.error(LOG, "%s(): %s.", tostring(owner.operation or "write"), detail)
		return false, detail
	end
	if not released then return false, release_err end
	if lock_release_err ~= nil then
		Logger.warn(
			LOG,
			"%s(): prior staging cleanup lock release was partial — %s.",
			tostring(owner.operation or "write"),
			tostring(lock_release_err)
		)
	end
	Logger.info(
		LOG,
		"%s(): prior staging cleanup settled for '%s'.",
		tostring(owner.operation or "write"),
		tostring(owner.area.lock_path)
	)
	return true
end

--- Creates a regular file only when its final directory entry is proven absent.
--- Publication uses hard-link create semantics, so a concurrent winner can
--- never be overwritten between the absence probe and publication. The whole
--- compare/link transaction shares the adjacent advisory mutex used by
--- replacement writers, closing the cooperating create-vs-replace gap.
--- @param path string Absolute destination path.
--- @param content string UTF-8 content.
--- @return boolean created True only when this call published the file.
--- @return string status `created`, `exists`, or `error`.
--- @return string|nil detail
function M.create_if_absent(path, content)
	if type(path) ~= "string" or path == "" then
		return false, "error", "path must be a non-empty string"
	end
	content = type(content) == "string" and content or ""
	local debt_settled, debt_err = settle_staging_cleanup_debt()
	if not debt_settled then return false, "error", debt_err end
	-- Keep `.`/`..` components intact until classify_read_path() has resolved
	-- every preceding symlink, matching resolve_write_path() and kernel ordering.
	local requested_path = path
	local resolved_path = nil
	local route_chain = nil
	local staging_area = nil
	local write_lock = nil

	local function cleanup_staging()
		if staging_area == nil then return true end
		local owner = new_staging_cleanup_owner(
			"create_if_absent",
			requested_path,
			resolved_path,
			route_chain,
			staging_area,
			false
		)
		local released, release_err = release_staging_owner(owner, "transaction cleanup")
		staging_area = nil
		return released, release_err
	end

	local call_ok, created, status, result_detail
	call_ok, created, status, result_detail = pcall(function()
		local _, read_status, read_detail = M.read_with_status(requested_path)
		if read_status == "ok" then return false, "exists" end
		if read_status ~= "absent" then return false, "error", read_detail end

		local classification, classification_detail
		resolved_path, classification, classification_detail, route_chain = classify_read_path(requested_path)
		if classification ~= "absent" then
			if classification == "present" then return false, "exists" end
			return false, "error", classification_detail
		end

		local lock_err = nil
		write_lock, lock_err = acquire_cooperative_write_lock(resolved_path)
		if not write_lock then
			return false, "error", tostring(lock_err or "cooperative write lock failed")
		end

		local unchanged, revalidate_err = revalidate_write_path(requested_path, resolved_path, route_chain)
		if not unchanged then return false, "error", revalidate_err end

		-- The first absence proof happened before lock acquisition. Repeat it while
		-- owning the shared writer mutex so every cooperating mutation is ordered.
		local locked_path, locked_classification, locked_detail, locked_chain =
			classify_read_path(requested_path)
		if locked_classification ~= "absent" then
			if locked_classification == "present" then return false, "exists" end
			return false, "error", locked_detail
		end
		if locked_path ~= resolved_path then
			return false, "error", locked_detail or "destination changed while acquiring write lock"
		end
		unchanged, revalidate_err = revalidate_write_path(requested_path, locked_path, locked_chain)
		if not unchanged then return false, "error", revalidate_err end
		route_chain = locked_chain

		local reserve_err = nil
		staging_area, reserve_err = reserve_staging_area(resolved_path)
		if not staging_area then return false, "error", reserve_err end

		local open_ok, fh, open_err = pcall(io.open, staging_area.payload_path, "w")
		if not open_ok or not fh then
			return false, "error", tostring((open_ok and open_err) or fh or "open failed")
		end
		local write_ok, written, write_err = pcall(fh.write, fh, content)
		local close_ok, closed, close_err = pcall(fh.close, fh)
		if not write_ok or written == nil or written == false then
			return false, "error", tostring((write_ok and write_err) or written or "write failed")
		end
		if not close_ok or closed ~= true then
			return false, "error", tostring((close_ok and close_err) or closed or "close failed")
		end

		local current_path, current_classification, current_detail, current_chain =
			classify_read_path(requested_path)
		if current_classification ~= "absent" or current_path ~= resolved_path then
			if current_classification == "present" then return false, "exists" end
			return false, "error", current_detail or "destination changed before publication"
		end
		unchanged, revalidate_err = revalidate_write_path(requested_path, resolved_path, route_chain)
		if not unchanged then return false, "error", revalidate_err end
		-- Keep both observations explicit: a symlink introduced after the second
		-- classification must not inherit an earlier empty chain.
		unchanged, revalidate_err = revalidate_write_path(requested_path, current_path, current_chain)
		if not unchanged then return false, "error", revalidate_err end

		if not hs or not hs.fs or type(hs.fs.link) ~= "function" then
			return false, "error", "hs.fs.link is unavailable; create-only publication is unsupported"
		end
		local link_ok, linked, link_err = pcall(
			hs.fs.link,
			staging_area.payload_path,
			resolved_path,
			false
		)
		if not link_ok or linked ~= true then
			local _, winner_status, winner_detail = M.read_with_status(requested_path)
			if winner_status == "ok" then return false, "exists" end
			return false, "error", winner_detail or tostring(link_ok and link_err or linked)
		end
		return true, "created"
	end)

	local cleanup_ok, cleanup_completed, cleanup_err = pcall(cleanup_staging)
	if not cleanup_ok then
		local unexpected_err = tostring(cleanup_completed)
		cleanup_completed = false
		if staging_area ~= nil then
			local owner = new_staging_cleanup_owner(
				"create_if_absent",
				requested_path,
				resolved_path,
				route_chain,
				staging_area,
				false
			)
			staging_area = nil
			local _, retained_err = retain_staging_cleanup_debt(
				owner,
				"unexpected cleanup error",
				unexpected_err
			)
			cleanup_err = retained_err
		else
			cleanup_err = unexpected_err
		end
		Logger.error(LOG, "create_if_absent(): unexpected staging cleanup error for '%s' — %s.",
			path, unexpected_err)
	end
	if cleanup_completed ~= true then
		result_detail = cleanup_err or "prior staging cleanup remains pending"
		if created ~= true or status ~= "created" then
			created = false
			status = "error"
		end
	end
	local lock_released, lock_release_err = release_cooperative_write_lock(write_lock)
	write_lock = nil
	if not lock_released then
		Logger.error(LOG, "create_if_absent(): cooperative publication lock for '%s' was not released — %s",
			tostring(resolved_path or path), tostring(lock_release_err))
	elseif lock_release_err ~= nil then
		Logger.warn(LOG, "create_if_absent(): cooperative publication lock cleanup for '%s' was partial — %s",
			tostring(resolved_path or path), tostring(lock_release_err))
	end

	if not call_ok then
		Logger.error(LOG, "create_if_absent(): unexpected error on '%s' — %s", path, tostring(created))
		return false, "error", tostring(created)
	end
	if not lock_released then
		return false, "error", tostring(lock_release_err or "cooperative write lock release failed")
	end
	return created, status, result_detail
end

--- Acquires the stable, adjacent fcntl mutex used by all cooperating Ergopti writers.
--- The lock pathname is never removed: unlink/recreate would split contenders
--- across different inodes. hs.fs.lock uses non-blocking F_SETLK, and the kernel
--- releases it automatically when a Hammerspoon process exits or is killed.
--- This serializes cooperating Ergopti writers only; it cannot constrain an
--- arbitrary editor that ignores advisory locks.
--- @param resolved_path string Symlink-resolved destination path.
--- @return table|nil owner Retained `{ path, handle }` lock owner.
--- @return string|nil error_message
acquire_cooperative_write_lock = function(resolved_path)
	if not hs or not hs.fs or type(hs.fs.lock) ~= "function"
		or type(hs.fs.unlock) ~= "function" then
		return nil, "hs.fs.lock/unlock are unavailable; cooperative publication is unsupported"
	end

	local lock_path = resolved_path .. WRITE_LOCK_SUFFIX
	if _held_write_locks[lock_path] ~= nil then
		return nil, "cooperative write lock is already held by this Hammerspoon process"
	end

	local before, inspect_err = inspect_path(lock_path)
	if inspect_err ~= nil then return nil, inspect_err end
	if before ~= nil and before.mode ~= "file" then
		return nil, "cooperative write lock pathname is not a regular file: " .. lock_path
	end

	-- a+ creates the stable empty inode when absent and never truncates an
	-- existing one. The preceding lstat rejects an existing symlink or directory.
	-- A non-cooperating process can still replace a pathname after this check;
	-- advisory serialization deliberately makes no guarantee about that actor.
	local open_ok, handle, open_err = pcall(io.open, lock_path, "a+")
	if not open_ok or handle == nil then
		return nil, tostring((open_ok and open_err) or handle or "lock open failed")
	end

	local function close_unowned_handle()
		if type(handle.close) == "function" then pcall(handle.close, handle) end
	end

	local call_ok, locked, lock_err = pcall(hs.fs.lock, handle, "w")
	if not call_ok or locked ~= true then
		close_unowned_handle()
		return nil, tostring((call_ok and lock_err) or locked or "write lock refused")
	end

	local owner = { path = lock_path, handle = handle }
	_held_write_locks[lock_path] = owner
	return owner
end

--- Releases one cooperative writer mutex exactly once.
--- Either a successful unlock or a successful close proves the kernel lock no
--- longer belongs to this process. If both fail, retain the owner and fail all
--- same-process re-entry closed instead of pretending the mutex was released.
--- @param owner table|nil Owner returned by acquire_cooperative_write_lock().
--- @return boolean released
--- @return string|nil error_message
release_cooperative_write_lock = function(owner)
	if owner == nil then return true end
	if type(owner) ~= "table" or type(owner.path) ~= "string" or owner.handle == nil then
		return false, "invalid cooperative write-lock owner"
	end
	if _held_write_locks[owner.path] ~= owner then
		return false, "cooperative write-lock ownership changed before release"
	end

	local unlock_ok, unlocked, unlock_err = pcall(hs.fs.unlock, owner.handle)
	local close_ok, closed, close_err = false, nil, nil
	if type(owner.handle.close) == "function" then
		close_ok, closed, close_err = pcall(owner.handle.close, owner.handle)
	end
	local unlocked_exactly = unlock_ok and unlocked == true
	local closed_exactly = close_ok and closed == true
	if unlocked_exactly or closed_exactly then
		_held_write_locks[owner.path] = nil
		if unlocked_exactly and closed_exactly then return true end
		return true, tostring(unlocked_exactly
			and (close_err or closed or "lock handle close failed")
			or (unlock_err or unlocked or "explicit unlock failed"))
	end

	return false, string.format(
		"unlock failed (%s); close failed (%s)",
		tostring(unlock_ok and (unlock_err or unlocked) or unlocked),
		tostring(close_ok and (close_err or closed) or closed)
	)
end

--- Classifies one final pathname without following a symbolic link.
--- Unlike read_with_status(), this returns inode identity needed by an owned
--- hard-link move and distinguishes proven absence from an unreadable path.
--- @param path string Filesystem path.
--- @return table|nil attributes lstat-style attributes for a present path.
--- @return string status `ok`, `absent`, or `error`.
--- @return string|nil detail Concrete classification failure.
function M.classify_no_follow(path)
	if type(path) ~= "string" or path == "" then
		return nil, "error", "path must be a non-empty string"
	end
	local attributes, inspect_err = inspect_path(path)
	if type(attributes) == "table" then return attributes, "ok" end
	if inspect_err ~= nil then return nil, "error", tostring(inspect_err) end
	return nil, "absent"
end

--- Allocates one process-unique temporary regular file through Lua's POSIX
--- os.tmpname() boundary. On macOS Lua creates the file while choosing the name,
--- so another user cannot pre-create a symlink in the selection/open gap.
--- Callers own the returned pathname and must remove it explicitly.
--- @return string|nil path Owned regular-file pathname.
--- @return string|nil detail Concrete allocation or classification failure.
function M.create_secure_temp_file()
	local call_ok, path = pcall(os.tmpname)
	if not call_ok or type(path) ~= "string" or path == "" then
		return nil, tostring(path or "os.tmpname returned no pathname")
	end
	local attributes, status, detail = M.classify_no_follow(path)
	if status ~= "ok" or type(attributes) ~= "table" or attributes.mode ~= "file" then
		return nil, tostring(detail or "os.tmpname did not create a regular file")
	end
	return path
end

--- Acquires the stable adjacent writer locks for several paths in lexical
--- resolved-path order. Ordering prevents two cooperating multi-path writers
--- from deadlocking each other. The returned group is also returned on partial
--- acquisition when cleanup itself remains unsettled, so callers never lose the
--- only exact lock capability.
--- @param paths table Array of requested paths.
--- @return table|nil group Retained ordered lock capability.
--- @return boolean committed True only when every path is locked and revalidated.
--- @return string|nil detail Failure detail.
function M.acquire_write_locks(paths)
	if type(paths) ~= "table" or #paths == 0 then
		return nil, false, "paths must be a non-empty array"
	end

	local routes = {}
	local resolved_seen = {}
	for index, requested_path in ipairs(paths) do
		if type(requested_path) ~= "string" or requested_path == "" then
			return nil, false, "path " .. tostring(index) .. " is invalid"
		end
		local resolved_path, chain, resolve_err = resolve_write_path(requested_path)
		if type(resolved_path) ~= "string" or resolved_path == "" then
			return nil, false, tostring(resolve_err or "path resolution failed")
		end
		if resolved_seen[resolved_path] then
			return nil, false, "multiple requested paths resolve to '" .. resolved_path .. "'"
		end
		resolved_seen[resolved_path] = true
		routes[#routes + 1] = {
			requested = requested_path,
			resolved = resolved_path,
			chain = chain,
		}
	end
	table.sort(routes, function(left, right) return left.resolved < right.resolved end)

	local group = {
		routes = routes,
		locks = {},
		resolved_paths = {},
		committed = false,
		released = false,
	}
	local acquisition_ok, acquired, acquisition_detail = xpcall(function()
		for _, route in ipairs(routes) do
			group.resolved_paths[route.requested] = route.resolved
			local lock, lock_err = acquire_cooperative_write_lock(route.resolved)
			if not lock then
				return false, tostring(lock_err or "cooperative write lock failed")
			end
			group.locks[#group.locks + 1] = { route = route, owner = lock }
		end

		for _, route in ipairs(routes) do
			local unchanged, revalidate_err = revalidate_write_path(
				route.requested, route.resolved, route.chain)
			if not unchanged then
				return false, tostring(revalidate_err or "path changed while acquiring locks")
			end
		end
		return true
	end, debug.traceback)
	if not acquisition_ok or acquired ~= true then
		local released, release_err = M.release_write_locks(group)
		local detail = tostring(acquisition_ok and acquisition_detail or acquired)
		if released then return nil, false, detail end
		return group, false, detail .. "; cleanup retained: " .. tostring(release_err)
	end

	group.committed = true
	return group, true
end

--- Releases an ordered writer-lock group in reverse acquisition order.
--- Successfully released members are cleared individually; a retry therefore
--- targets only the exact unresolved lock owners.
--- @param group table|nil Group returned by acquire_write_locks().
--- @return boolean released True only when every retained lock settled.
--- @return string|nil detail First unresolved release detail.
function M.release_write_locks(group)
	if group == nil then return true end
	if type(group) ~= "table" or type(group.locks) ~= "table" then
		return false, "invalid cooperative write-lock group"
	end
	if group.released == true then return true end

	local first_error = nil
	for index = #group.locks, 1, -1 do
		local item = group.locks[index]
		if type(item) == "table" and item.owner ~= nil then
			local released, release_err = release_cooperative_write_lock(item.owner)
			if released then
				item.owner = nil
			elseif first_error == nil then
				first_error = tostring(release_err or "write-lock release refused")
			end
		end
	end

	for _, item in ipairs(group.locks) do
		if type(item) == "table" and item.owner ~= nil then
			return false, first_error or "write-lock release remains pending"
		end
	end
	group.committed = false
	group.released = true
	return true
end

--- Creates one hard link at an absent exact pathname.
--- The kernel link operation is create-only: an existing file, symlink, or
--- directory at destination is never interpreted as a container or replaced.
--- @param source string Existing regular-file pathname.
--- @param destination string Exact absent pathname to create.
--- @return boolean linked Literal native success.
--- @return string|nil detail Failure detail.
function M.hard_link_create_only(source, destination)
	if type(source) ~= "string" or source == ""
		or type(destination) ~= "string" or destination == "" then
		return false, "source and destination must be non-empty strings"
	end
	if not hs or not hs.fs or type(hs.fs.link) ~= "function" then
		return false, "hs.fs.link is unavailable"
	end
	local call_ok, linked, link_err = pcall(hs.fs.link, source, destination, false)
	if not call_ok then return false, tostring(linked) end
	if linked ~= true then return false, tostring(link_err or linked or "hard link refused") end
	return true
end

--- Removes one exact pathname and preserves the native literal-true contract.
--- @param path string Pathname to unlink.
--- @return boolean removed Literal native success.
--- @return string|nil detail Failure detail.
function M.remove_exact(path)
	if type(path) ~= "string" or path == "" then
		return false, "path must be a non-empty string"
	end
	local call_ok, removed, remove_err = pcall(os.remove, path)
	if not call_ok then return false, tostring(removed) end
	if removed ~= true then return false, tostring(remove_err or removed or "remove refused") end
	return true
end

--- Writes content to a file atomically (temp file + rename), overwriting any
--- existing content. Creates parent directories when they do not exist.
--- A crash or process kill mid-write can never leave a torn/truncated file at
--- `path` — a reader (e.g. Karabiner-Elements' own FSEvents watcher on
--- karabiner.json) either sees the old complete content or the new complete
--- content, never a partial write (filesystem-adapter-nonatomic-write).
--- Pre-existing symlink components are resolved before staging, so an ordinary
--- write through an observed link lands on its resolved target instead of
--- replacing that link with a plain file. The observed chain is revalidated
--- around publication; this is not a claim of compare-and-swap semantics for
--- a final pathname that was absent during resolution. Replacement writers in
--- Ergopti processes are serialized by one stable adjacent advisory fcntl lock;
--- external writers that ignore that lock remain outside the guarantee.
--- @param path    string Absolute path to the file.
--- @param content string UTF-8 content to write.
--- @return boolean true on success, false on any error.
--- @return string|nil error_message Concrete failure reason when available.
local function write_atomic(path, content, expected_source)
	if type(path) ~= "string" or path == "" then
		Logger.error(LOG, "write(): path must be a non-empty string.")
		return false, "path must be a non-empty string"
	end
	content = type(content) == "string" and content or ""
	local debt_settled, debt_err = settle_staging_cleanup_debt()
	if not debt_settled then return false, debt_err end

	local staging_area = nil
	local resolved_path = nil
	local symlink_chain = nil
	local payload_published = false
	local write_lock = nil

	local function preserve_staging_area(context, reason)
		if not staging_area then return false end
		local owner = new_staging_cleanup_owner(
			"write",
			path,
			resolved_path,
			symlink_chain,
			staging_area,
			payload_published
		)
		staging_area = nil
		return retain_staging_cleanup_debt(owner, context, reason)
	end

	local function cleanup_staging_if_safe(context)
		if not staging_area then return true end
		local owner = new_staging_cleanup_owner(
			"write",
			path,
			resolved_path,
			symlink_chain,
			staging_area,
			payload_published
		)
		local released, release_err = release_staging_owner(owner, context)
		staging_area = nil
		return released, release_err
	end

	local function fail_after_cleanup(context, reason)
		local cleaned, cleanup_err = cleanup_staging_if_safe(context)
		if cleaned then return false, reason end
		return false, tostring(reason) .. "; "
			.. tostring(cleanup_err or "prior staging cleanup remains pending")
	end

	local ok, result, result_err = pcall(function()
		-- Resolve every existing component before creating any missing parent.
		-- A dangling final link has no safe target in Hammerspoon and fails closed.
		local resolve_err = nil
		resolved_path, symlink_chain, resolve_err = resolve_write_path(path)
		if not resolved_path then
			Logger.error(LOG, "write(): cannot resolve '%s' safely — %s", path, tostring(resolve_err))
			return false, tostring(resolve_err or "path resolution failed")
		end

		local dir = parent_dir(resolved_path)
		if dir then ensure_dir(dir) end

		write_lock, resolve_err = acquire_cooperative_write_lock(resolved_path)
		if not write_lock then
			Logger.error(
				LOG,
				"write(): cannot acquire cooperative publication lock for '%s' — %s",
				resolved_path,
				tostring(resolve_err)
			)
			return false, tostring(resolve_err or "cooperative write lock failed")
		end
		local route_unchanged, route_err = revalidate_write_path(path, resolved_path, symlink_chain)
		if not route_unchanged then
			Logger.error(LOG, "write(): destination changed while acquiring its lock — %s",
				tostring(route_err))
			return false, tostring(route_err or "destination changed while acquiring write lock")
		end

		staging_area, resolve_err = reserve_staging_area(resolved_path)
		if not staging_area then
			Logger.error(
				LOG,
				"write(): cannot reserve private staging for '%s' — %s",
				resolved_path,
				tostring(resolve_err)
			)
			return false, tostring(resolve_err or "staging reservation failed")
		end

		-- Stage beside the resolved target so publication stays on one filesystem.
		local tmp_path = staging_area.payload_path
		local fh, err  = io.open(tmp_path, "w")
		if not fh then
			local reason = tostring(err or "open failed")
			Logger.error(LOG, "write(): cannot open '%s' for writing — %s", tmp_path, reason)
			return fail_after_cleanup("open failure", reason)
		end
		local write_ok, write_result, write_err = pcall(function() return fh:write(content) end)
		local close_ok, close_result, close_err = pcall(function() return fh:close() end)
		if not write_ok or write_result == nil or write_result == false then
			local reason = tostring((write_ok and write_err) or write_result or "write failed")
			Logger.error(
				LOG,
				"write(): write failed for '%s' — %s",
				tmp_path,
				reason
			)
			return fail_after_cleanup("write failure", reason)
		end
		if not close_ok or close_result == nil or close_result == false then
			local reason = tostring((close_ok and close_err) or close_result or "close failed")
			Logger.error(
				LOG,
				"write(): close failed for '%s' — %s",
				tmp_path,
				reason
			)
			return fail_after_cleanup("close failure", reason)
		end

		local unchanged, revalidate_err = revalidate_write_path(path, resolved_path, symlink_chain)
		if not unchanged then
			Logger.error(LOG, "write(): destination changed before publication — %s", tostring(revalidate_err))
			local reason = tostring(revalidate_err or "destination changed before publication")
			local _, cleanup_err = preserve_staging_area(
				"pre-publication revalidation failure",
				revalidate_err
			)
			return false, reason .. "; "
				.. tostring(cleanup_err or "prior staging cleanup remains pending")
		end

		if type(expected_source) == "table" then
			local current, current_status, current_detail = M.read_with_status(path)
			local source_unchanged = current_status == expected_source.status
				and (current_status ~= "ok" or current == expected_source.content)
			if not source_unchanged then
				local reason = tostring(current_detail or current_status or "source changed before publication")
				Logger.error(
					LOG,
					"write(): source changed before publication — %s",
					reason
				)
				return fail_after_cleanup("source precondition failure", reason)
			end
		end

		local rename_ok, rename_err = os.rename(tmp_path, resolved_path)
		if not rename_ok then
			local reason = tostring(rename_err or "rename failed")
			Logger.error(
				LOG,
				"write(): rename '%s' -> '%s' failed — %s",
				tmp_path,
				resolved_path,
				reason
			)
			return fail_after_cleanup("rename failure", reason)
		end
		payload_published = true
		unchanged, revalidate_err = revalidate_write_path(path, resolved_path, symlink_chain)
		if not unchanged then
			Logger.error(
				LOG,
				"write(): content reached prior resolved target '%s' after symlink retarget — %s",
				resolved_path,
				tostring(revalidate_err)
			)
			local reason = tostring(revalidate_err or "destination changed after publication")
			local _, cleanup_err = preserve_staging_area(
				"post-publication revalidation failure",
				revalidate_err
			)
			return false, reason .. "; "
				.. tostring(cleanup_err or "prior staging cleanup remains pending")
		end
		local cleanup_completed, cleanup_err = cleanup_staging_if_safe("successful publication")
		if not cleanup_completed then return true, cleanup_err end
		return true
	end)
	if not ok and staging_area then
		local cleanup_ok, cleanup_completed, cleanup_err = pcall(
			cleanup_staging_if_safe,
			"unexpected error"
		)
		if not cleanup_ok then
			local unexpected_err = tostring(cleanup_completed)
			if staging_area ~= nil then
				local owner = new_staging_cleanup_owner(
					"write",
					path,
					resolved_path,
					symlink_chain,
					staging_area,
					payload_published
				)
				local _, retained_err = retain_staging_cleanup_debt(
					owner,
					"unexpected cleanup error",
					unexpected_err
				)
				staging_area = nil
				cleanup_err = retained_err
			else
				cleanup_err = unexpected_err
			end
			cleanup_completed = false
			Logger.error(LOG, "write(): unexpected cleanup error for '%s' — %s.", path, unexpected_err)
		end
		if cleanup_completed ~= true then
			result = tostring(result) .. "; "
				.. tostring(cleanup_err or "prior staging cleanup remains pending")
		end
	end

	local lock_released, lock_release_err = release_cooperative_write_lock(write_lock)
	write_lock = nil
	if not lock_released then
		Logger.error(LOG, "write(): cooperative publication lock for '%s' was not released — %s",
			tostring(resolved_path or path), tostring(lock_release_err))
	elseif lock_release_err ~= nil then
		Logger.warn(LOG, "write(): cooperative publication lock cleanup for '%s' was partial — %s",
			tostring(resolved_path or path), tostring(lock_release_err))
	end

	if not ok then
		Logger.error(LOG, "write(): unexpected error on '%s' — %s", path, tostring(result))
		return false, tostring(result)
	end
	if not lock_released then
		return false, tostring(lock_release_err or "cooperative write lock release failed")
	end
	if result == true then return true, result_err end
	return false, result_err or "atomic write failed"
end

--- Writes content atomically through the canonical two-argument FileSystem port.
--- @param path string Absolute destination path.
--- @param content string UTF-8 content.
--- @return boolean written
--- @return string|nil error_message
function M.write(path, content)
	return write_atomic(path, content, nil)
end

--- Performs a last-moment classified-source check before atomic publication.
--- This is intentionally NOT described as pathname compare-and-swap: public
--- Darwin rename APIs cannot bind an expected inode/content hash to replacement,
--- so a non-cooperating writer may still publish between the check and rename.
--- This macOS extension keeps that bounded compare-before-write behavior outside
--- the shared two-argument FileSystem port contract.
--- @param path string Absolute destination path.
--- @param content string UTF-8 content.
--- @param expected_source table `{ status = "ok"|"absent", content = string|nil }`.
--- @return boolean written
--- @return string|nil error_message
function M.write_if_unchanged(path, content, expected_source)
	if type(expected_source) ~= "table" then
		return false, "expected_source must be a table"
	end
	return write_atomic(path, content, expected_source)
end

--- Appends content to a file, creating it if it does not exist.
--- @param path    string Absolute path to the file.
--- @param content string UTF-8 content to append.
--- @return boolean true on success, false on any error.
function M.append(path, content)
	if type(path) ~= "string" or path == "" then
		Logger.error(LOG, "append(): path must be a non-empty string.")
		return false
	end
	content = type(content) == "string" and content or ""

	local ok, result = pcall(function()
		local fh, err = io.open(path, "a")
		if not fh then
			Logger.error(LOG, "append(): cannot open '%s' for appending — %s", path, tostring(err))
			return false
		end
		local write_ok, write_err = pcall(function() fh:write(content) end)
		fh:close()
		if not write_ok then
			Logger.error(LOG, "append(): write failed for '%s' — %s", path, tostring(write_err))
			return false
		end
		return true
	end)

	if not ok then
		Logger.error(LOG, "append(): unexpected error on '%s' — %s", path, tostring(result))
		return false
	end
	return result == true
end

--- Returns true if a file or directory exists at the given path.
--- @param path string Absolute path to test.
--- @return boolean true if the path exists, false otherwise.
function M.exists(path)
	if type(path) ~= "string" or path == "" then return false end

	-- hs.fs.attributes returns a table on success, nil on failure
	if hs and hs.fs and type(hs.fs.attributes) == "function" then
		local ok, attrs = pcall(hs.fs.attributes, path)
		return ok and attrs ~= nil
	end

	-- Fallback: try to open as a file
	local ok, fh = pcall(io.open, path, "r")
	if ok and fh then
		fh:close()
		return true
	end
	return false
end

--- Expands a path that may begin with "~" to an absolute path.
--- Delegates to hs.fs.pathToAbsolute so the result follows macOS symlink
--- resolution (important for ~/.config which may be a symlink on some setups).
--- Falls back to naive HOME substitution when hs.fs is unavailable (unit tests).
--- @param path string Path to expand (may start with "~").
--- @return string Expanded absolute path.
function M.expand_path(path)
	if type(path) ~= "string" or path == "" then
		Logger.error(LOG, "expand_path(): path must be a non-empty string.")
		return path or ""
	end

	if hs and hs.fs and type(hs.fs.pathToAbsolute) == "function" then
		local ok, abs = pcall(hs.fs.pathToAbsolute, path)
		if ok and type(abs) == "string" and abs ~= "" then
			return abs
		end
		-- pathToAbsolute returns nil when the path does not exist yet — fall
		-- through to naive expansion so callers can still build paths for files
		-- that have not been created yet.
	end

	-- Naive fallback: replace leading "~" with HOME env var
	if path:sub(1, 1) == "~" then
		local home = os.getenv("HOME") or ""
		return home .. path:sub(2)
	end
	return path
end


--- Deletes a file. Returns true if the file was deleted or was already absent.
--- @param path string Absolute path to the file to delete.
--- @return boolean true on success or file-not-found, false on any other error.
function M.delete(path)
	if type(path) ~= "string" or path == "" then
		Logger.error(LOG, "delete(): path must be a non-empty string.")
		return false
	end

	-- Already absent — contract says this is a no-op success
	if not M.exists(path) then return true end

	local removed, remove_err = remove_path_or_absent(path)
	if not removed then
		Logger.error(LOG, "delete(): os.remove failed for '%s' — %s.", path, tostring(remove_err))
		return false
	end
	return true
end

return M
