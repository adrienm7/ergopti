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
local ENOENT_ERROR_CODE = 2
local MAX_SYMLINK_HOPS = 32
local MAX_STAGING_RESERVATION_ATTEMPTS = 64




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
	if current_path ~= expected_path then return false, "resolved target changed before publication" end
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
				}
			end
		end

		if not replaced then return nil, "error", "pathname resolution did not terminate", chain end
	end
end

--- Revalidates the final regular-file identity after the stream is closed.
--- Hammerspoon/macOS exposes dev+ino. Tests running without host lstat support
--- still get type/presence validation, while injected identities exercise the
--- replacement race deterministically.
--- @param expected table Final lstat observation captured before open.
--- @return boolean unchanged
--- @return string|nil error_message
local function revalidate_read_identity(expected)
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

	local requested_path = normalize_path(path)
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
	unchanged, revalidate_err = revalidate_read_identity(final_identity)
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

--- Removes an adapter-owned transaction sidecar.
--- @param path string Sidecar path.
--- @return boolean removed_or_absent
--- @return string|nil error_message
local function remove_owned_sidecar(path)
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
		local payload_removed, payload_err = remove_owned_sidecar(area.payload_path)
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

--- Creates a regular file only when its final directory entry is proven absent.
--- Publication uses hard-link create semantics, so a concurrent winner can
--- never be overwritten between the absence probe and publication.
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
	local requested_path = normalize_path(path)

	local existing, read_status, read_detail = M.read_with_status(requested_path)
	if read_status == "ok" then return false, "exists" end
	if read_status ~= "absent" then return false, "error", read_detail end

	local resolved_path, classification, detail, chain = classify_read_path(requested_path)
	if classification ~= "absent" then
		if classification == "present" then return false, "exists" end
		return false, "error", detail
	end
	local staging_area, reserve_err = reserve_staging_area(resolved_path)
	if not staging_area then return false, "error", reserve_err end

	local function cleanup()
		local released, release_err = release_staging_area(staging_area, false)
		if not released then
			Logger.warn(LOG, "create_if_absent(): staging cleanup failed for '%s' — %s",
				path, tostring(release_err))
		end
	end

	local open_ok, fh, open_err = pcall(io.open, staging_area.payload_path, "w")
	if not open_ok or not fh then
		cleanup()
		return false, "error", tostring((open_ok and open_err) or fh or "open failed")
	end
	local write_ok, written, write_err = pcall(fh.write, fh, content)
	local close_ok, closed, close_err = pcall(fh.close, fh)
	if not write_ok or written == nil or written == false then
		cleanup()
		return false, "error", tostring((write_ok and write_err) or written or "write failed")
	end
	if not close_ok or closed ~= true then
		cleanup()
		return false, "error", tostring((close_ok and close_err) or closed or "close failed")
	end

	local current_path, current_classification, current_detail, current_chain = classify_read_path(requested_path)
	if current_classification ~= "absent" or current_path ~= resolved_path then
		cleanup()
		if current_classification == "present" then return false, "exists" end
		return false, "error", current_detail or "destination changed before publication"
	end
	local unchanged, revalidate_err = revalidate_write_path(requested_path, resolved_path, chain)
	if not unchanged then
		cleanup()
		return false, "error", revalidate_err
	end
	-- Keep both observations explicit: a symlink introduced after the second
	-- classification must not inherit an earlier empty chain.
	unchanged, revalidate_err = revalidate_write_path(requested_path, current_path, current_chain)
	if not unchanged then
		cleanup()
		return false, "error", revalidate_err
	end

	if not hs or not hs.fs or type(hs.fs.link) ~= "function" then
		cleanup()
		return false, "error", "hs.fs.link is unavailable; create-only publication is unsupported"
	end
	local link_ok, linked, link_err = pcall(
		hs.fs.link,
		staging_area.payload_path,
		resolved_path,
		false
	)
	if not link_ok or linked ~= true then
		cleanup()
		local _, winner_status, winner_detail = M.read_with_status(requested_path)
		if winner_status == "ok" then return false, "exists" end
		return false, "error", winner_detail or tostring(link_ok and link_err or linked)
	end
	cleanup()
	return true, "created"
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
--- a final pathname that was absent during resolution.
--- @param path    string Absolute path to the file.
--- @param content string UTF-8 content to write.
--- @param expected_source table|nil Optional `{ status = "ok"|"absent", content = string }`
---   snapshot that must still match after staging and immediately before rename.
--- @return boolean true on success, false on any error.
function M.write(path, content, expected_source)
	if type(path) ~= "string" or path == "" then
		Logger.error(LOG, "write(): path must be a non-empty string.")
		return false
	end
	content = type(content) == "string" and content or ""

	local staging_area = nil
	local resolved_path = nil
	local symlink_chain = nil
	local payload_published = false

	local function preserve_staging_area(context, reason)
		if not staging_area then return false end
		Logger.warn(
			LOG,
			"write(): preserving staging sidecar '%s' after %s — %s",
			tostring(staging_area.lock_path),
			tostring(context),
			tostring(reason)
		)
		staging_area = nil
		return false
	end

	local function cleanup_staging_if_safe(context)
		if not staging_area then return true end
		local unchanged, revalidate_err = revalidate_write_path(path, resolved_path, symlink_chain)
		if not unchanged then return preserve_staging_area(context, revalidate_err) end
		local area = staging_area
		staging_area = nil
		local released, release_err = release_staging_area(area, payload_published)
		if not released then
			Logger.warn(
				LOG,
				"write(): staging-lock cleanup after %s failed — %s",
				tostring(context),
				tostring(release_err)
			)
		end
		return released, release_err
	end

	local ok, result = pcall(function()
		-- Resolve every existing component before creating any missing parent.
		-- A dangling final link has no safe target in Hammerspoon and fails closed.
		local resolve_err = nil
		resolved_path, symlink_chain, resolve_err = resolve_write_path(path)
		if not resolved_path then
			Logger.error(LOG, "write(): cannot resolve '%s' safely — %s", path, tostring(resolve_err))
			return false
		end

		local dir = parent_dir(resolved_path)
		if dir then ensure_dir(dir) end

		staging_area, resolve_err = reserve_staging_area(resolved_path)
		if not staging_area then
			Logger.error(
				LOG,
				"write(): cannot reserve private staging for '%s' — %s",
				resolved_path,
				tostring(resolve_err)
			)
			return false
		end

		-- Stage beside the resolved target so publication stays on one filesystem.
		local tmp_path = staging_area.payload_path
		local fh, err  = io.open(tmp_path, "w")
		if not fh then
			Logger.error(LOG, "write(): cannot open '%s' for writing — %s", tmp_path, tostring(err))
			cleanup_staging_if_safe("open failure")
			return false
		end
		local write_ok, write_result, write_err = pcall(function() return fh:write(content) end)
		local close_ok, close_result, close_err = pcall(function() return fh:close() end)
		if not write_ok or write_result == nil or write_result == false then
			Logger.error(
				LOG,
				"write(): write failed for '%s' — %s",
				tmp_path,
				tostring(write_ok and write_err or write_result)
			)
			cleanup_staging_if_safe("write failure")
			return false
		end
		if not close_ok or close_result == nil or close_result == false then
			Logger.error(
				LOG,
				"write(): close failed for '%s' — %s",
				tmp_path,
				tostring(close_ok and close_err or close_result)
			)
			cleanup_staging_if_safe("close failure")
			return false
		end

		local unchanged, revalidate_err = revalidate_write_path(path, resolved_path, symlink_chain)
		if not unchanged then
			Logger.error(LOG, "write(): destination changed before publication — %s", tostring(revalidate_err))
			preserve_staging_area("pre-publication revalidation failure", revalidate_err)
			return false
		end

		if type(expected_source) == "table" then
			local current, current_status, current_detail = M.read_with_status(path)
			local source_unchanged = current_status == expected_source.status
				and (current_status ~= "ok" or current == expected_source.content)
			if not source_unchanged then
				Logger.error(
					LOG,
					"write(): source changed before publication — %s",
					tostring(current_detail or current_status)
				)
				cleanup_staging_if_safe("source precondition failure")
				return false
			end
		end

		local rename_ok, rename_err = os.rename(tmp_path, resolved_path)
		if not rename_ok then
			Logger.error(
				LOG,
				"write(): rename '%s' -> '%s' failed — %s",
				tmp_path,
				resolved_path,
				tostring(rename_err)
			)
			cleanup_staging_if_safe("rename failure")
			return false
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
			preserve_staging_area("post-publication revalidation failure", revalidate_err)
			return false
		end
		cleanup_staging_if_safe("successful publication")
		return true
	end)

	if not ok then
		if staging_area then
			local cleanup_ok, cleanup_err = pcall(cleanup_staging_if_safe, "unexpected error")
			if not cleanup_ok then
				Logger.warn(LOG, "write(): unexpected cleanup error for '%s' — %s", path, tostring(cleanup_err))
			end
		end
		Logger.error(LOG, "write(): unexpected error on '%s' — %s", path, tostring(result))
		return false
	end
	return result == true
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

	local ok, result = pcall(os.remove, path)
	if not ok or not result then
		Logger.error(LOG, "delete(): os.remove failed for '%s' — %s", path, tostring(result))
		return false
	end
	return true
end

return M
