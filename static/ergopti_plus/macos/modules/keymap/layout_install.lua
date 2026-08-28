--- modules/keymap/layout_install.lua

--- ==============================================================================
--- MODULE: Keyboard Layout Install
--- DESCRIPTION:
--- Bundle discovery and on-disk install/upgrade of the Ergopti keyboard-layout
--- bundles (user + system scope). Extracted from ui/menu/menu_keyboard_layout.lua
--- (audit F4) so the 1647-line menu module shrinks to its submenu builder and the
--- install/TIS glue lives in a focused, independently testable module.
---
--- FEATURES & RATIONALE:
--- 1. Single source of truth for bundle discovery: the highest version found in
---    the bundles directory wins, memoised while its directory revision is stable.
--- 2. Idempotent install detection: highest_installed() reports the live on-disk
---    version so the menu can disable already-installed entries.
--- 3. Resilient, SIP-aware filesystem probes: shells out to /bin/test and osascript
---    for privileged copies; every failure path is logged, never silent.
---
--- Owns the bundle-discovery memo (_installed_cache / _latest_bundle_cache); the
--- input-source layer (input_sources.lua) and the menu builder consume this
--- module's public functions, never its private caches.
--- ==============================================================================

local hs            = hs
local Logger        = require("infra.logger")
local text_utils = require("infra.text_utils")
local i18n          = require("infra.i18n")
local notifications = require("infra.notifications")
local LOG           = "menu.keyboard_layout"

-- Target install paths on macOS
local USER_LAYOUTS_DIR   = os.getenv("HOME") and (os.getenv("HOME") .. "/Library/Keyboard Layouts/") or "~/Library/Keyboard Layouts/"
local SYSTEM_LAYOUTS_DIR = "/Library/Keyboard Layouts/"

-- highest_installed(dir) result and directory revision, keyed by directory.
local _installed_cache = {}
-- pick_latest_bundle(dir) result and directory revision, keyed by directory.
local _latest_bundle_cache = {}

--- Returns a cheap identity for one directory listing. Directory entry changes
--- update its size or timestamps on macOS, so external installs and removals can
--- invalidate memoised discovery without repeating the full scan on every read.
--- A platform that cannot expose mutable directory attributes bypasses the memo.
--- @param dir string Directory path.
--- @return string|nil revision Stable revision, or nil when it cannot be proved.
local function directory_revision(dir)
	if not (hs and hs.fs and type(hs.fs.attributes) == "function") then return nil end
	local ok, attrs = pcall(hs.fs.attributes, dir)
	if not ok or type(attrs) ~= "table" then return nil end
	if attrs.size == nil and attrs.modification == nil and attrs.change == nil then return nil end
	return table.concat({
		tostring(attrs.device),
		tostring(attrs.inode),
		tostring(attrs.size),
		tostring(attrs.modification),
		tostring(attrs.change),
	}, "\31")
end

--- Reads a memo only when it belongs to the currently observed directory.
--- @param cache table Cache table.
--- @param dir string Directory path.
--- @param revision string|nil Current directory revision.
--- @return boolean hit Whether the memo is authoritative.
--- @return any value Memoised value; false represents a scanned empty directory.
local function read_revision_cache(cache, dir, revision)
	local record = cache[dir]
	if revision == nil or type(record) ~= "table" or record.revision ~= revision then
		return false, nil
	end
	return true, record.value
end

--- Publishes a scan only if the directory stayed stable throughout it.
--- @param cache table Cache table.
--- @param dir string Directory path.
--- @param before string|nil Revision captured before the scan.
--- @param value any Scanned value; nil is stored as false.
local function publish_revision_cache(cache, dir, before, value)
	local after = directory_revision(dir)
	if before ~= nil and after == before then
		cache[dir] = { revision = before, value = value or false }
	else
		cache[dir] = nil
	end
end

--- Clears the bundle-discovery memo. Called after an install / upgrade changes
--- the on-disk layout set. Exposed for unit tests.
local function invalidate_bundle_caches()
	_installed_cache     = {}
	_latest_bundle_cache = {}
end




-- =====================================
-- =====================================
-- ======= 1/ Bundle Discovery =========
-- =====================================
-- =====================================

--- Parses a bundle directory name like "Ergopti_v2.2.1.bundle" into a
--- comparable version table {2, 2, 1}.
--- @param name string Bundle directory basename.
--- @return table|nil Numeric version components, or nil if unparseable.
local function parse_version(name)
	local v = name:match("_v([%d%.]+)%.bundle$")
	if not v then return nil end
	local parts = {}
	for n in v:gmatch("(%d+)") do parts[#parts + 1] = tonumber(n) end
	if #parts == 0 then return nil end
	return parts
end

--- Compares two version tables lexicographically.
--- @param a table
--- @param b table
--- @return boolean true if a > b.
local function version_gt(a, b)
	for i = 1, math.max(#a, #b) do
		local ai, bi = a[i] or 0, b[i] or 0
		if ai ~= bi then return ai > bi end
	end
	return false
end

--- Lists every "Ergopti_v*.bundle" inside the given directory.
--- Pure-Lua via lfs-less directory scan using io.popen (cross-platform-ish).
--- @param dir string Absolute path of the bundles directory.
--- @return table List of basenames (no trailing slash).
local function list_bundles(dir)
	local out = {}
	local cmd
	if package.config:sub(1, 1) == "\\" then
		-- Windows (used during Lua test runs)
		cmd = string.format('cmd /c dir /b /a:d "%s"', dir:gsub("/", "\\"))
	else
		cmd = string.format("ls -1 '%s'", dir)
	end
	local p = io.popen(cmd)
	if not p then return out end
	for raw_line in p:lines() do
		local line = raw_line:gsub("[\r\n]+$", "")
		if line:match("^Ergopti_v[%d%.]+%.bundle$") then
			out[#out + 1] = line
		end
	end
	p:close()
	return out
end

--- Picks the highest-version bundle inside dir.
--- @param dir string Absolute path of the bundles directory.
--- @return string|nil Basename of the latest bundle, or nil if none found.
local function pick_latest_bundle(dir)
	if type(dir) ~= "string" or dir == "" then return nil end
	local revision = directory_revision(dir)
	local hit, cached = read_revision_cache(_latest_bundle_cache, dir, revision)
	if hit then return cached or nil end
	local best, best_ver = nil, nil
	for _, name in ipairs(list_bundles(dir)) do
		local ver = parse_version(name)
		if ver and (not best_ver or version_gt(ver, best_ver)) then
			best, best_ver = name, ver
		end
	end
	publish_revision_cache(_latest_bundle_cache, dir, revision, best)
	return best
end




-- =====================================
-- =====================================
-- ======= 2/ Install Helpers ==========
-- =====================================
-- =====================================

--- Returns true if the file/dir at the given path exists (best-effort).
--- io.open(path, "r") fails on directories on macOS, and os.rename() on a
--- system-protected location like "/Library/Keyboard Layouts" can hit SIP
--- restrictions even for stat-style probes — so we shell out to /bin/test
--- which handles files, directories, and bundles uniformly.
--- @param path string Absolute path.
--- @return boolean
local function path_exists(path)
	if type(path) ~= "string" or path == "" then return false end
	if hs and hs.fs and type(hs.fs.attributes) == "function" then
		local attrs = hs.fs.attributes(path)
		if attrs then return true end
	end
	-- Shell fallback — handles SIP-protected paths that hs.fs.attributes can't stat.
	-- /bin/test -e accepts any filesystem object (file, dir, bundle symlink).
	-- shell_quote, not %q. Lua's %q escapes for a LUA literal: it leaves $,
	-- backticks and ! untouched, every one of which /bin/sh expands. This path is
	-- user-influenced (the config directory is a setting), so %q here is both
	-- wrong for ordinary paths and a shell-injection hazard.
	local cmd = string.format("/bin/test -e %s && echo OK", text_utils.shell_quote(path))
	local out = hs.execute and hs.execute(cmd) or nil
	if type(out) == "string" and out:find("OK") then return true end
	-- Pure-Lua fallback for unit-test runs where hs is unavailable.
	-- os.rename is intentionally omitted: on SIP-protected paths it returns true
	-- even when the file does not exist, which would make find_installed_bundles
	-- report a phantom installed bundle and show "Mettre à jour" instead of "Installer".
	local f = io.open(path, "r")
	if f then f:close(); return true end
	return false
end

--- Lists every Ergopti_v*.bundle currently installed in `dir`.
--- Returns the parsed version components for each so callers can compare to
--- the latest available version without having to re-parse strings.
---
--- Bundle entries are only counted when their internal Contents/Info.plist
--- exists — a stray empty .bundle directory left behind by a failed install
--- (or by macOS while moving files between locations) would otherwise be
--- picked up here, with the upstream menu builder then offering an
--- "in-place upgrade" against a non-existent install. The structural check
--- guarantees `installed` only points at bundles that the OS would itself
--- treat as a real keyboard layout.
--- @param dir string Absolute path of the Keyboard Layouts directory.
--- @return table Array of { name = string, version = table } entries.
local function find_installed_bundles(dir)
	local out = {}
	if type(dir) ~= "string" or dir == "" then return out end
	-- shell_quote, not %q: the sibling function 60 lines down already documents
	-- why (%q escapes for a Lua literal and leaves $, backticks and ! live for
	-- /bin/sh), and every path reaching here is user-configurable.
	local cmd = string.format("ls -1 %s 2>/dev/null", text_utils.shell_quote(dir))
	local p = io.popen(cmd)
	if not p then return out end
	local dir_with_slash = dir:match("[/\\]$") and dir or (dir .. "/")
	for raw_line in p:lines() do
		local line = raw_line:gsub("[\r\n]+$", "")
		if line:match("^Ergopti_v[%d%.]+%.bundle$") then
			local v = parse_version(line)
			local info_plist = dir_with_slash .. line .. "/Contents/Info.plist"
			local plist_ok = v and path_exists(info_plist)
			Logger.debug(LOG, "Bundle probe — dir=%s name=%s plist_exists=%s.", dir, line, tostring(plist_ok))
			if plist_ok then
				out[#out + 1] = { name = line, version = v }
			end
		end
	end
	p:close()
	return out
end

--- Returns the highest installed Ergopti version in the given directory.
--- @param dir string Absolute path of the Keyboard Layouts directory.
--- @return table|nil { name = string, version = table } or nil if none.
local function highest_installed(dir)
	if type(dir) ~= "string" or dir == "" then return nil end
	local revision = directory_revision(dir)
	local hit, cached = read_revision_cache(_installed_cache, dir, revision)
	if hit then return cached or nil end
	local best
	for _, entry in ipairs(find_installed_bundles(dir)) do
		if not best or version_gt(entry.version, best.version) then
			best = entry
		end
	end
	publish_revision_cache(_installed_cache, dir, revision, best)
	return best
end

--- Renders a version components table back to a human-readable string.
--- @param v table Numeric version components, e.g. {2,2,1}.
--- @return string e.g. "2.2.1".
local function version_str(v)
	if type(v) ~= "table" then return "?" end
	local parts = {}
	for _, n in ipairs(v) do parts[#parts + 1] = tostring(n) end
	return table.concat(parts, ".")
end

--- Builds a same-filesystem replacement transaction for one bundle scope.
--- The source is copied and structurally verified before installed bundles move
--- into a rollback directory. The exit trap restores every moved bundle unless
--- the staged bundle reaches its final name.
--- @param target_dir string Keyboard Layouts directory receiving the bundle.
--- @param bundles_dir string Directory containing the source bundle.
--- @param bundle_name string Basename of the source bundle.
--- @return string|nil command POSIX shell command, or nil on invalid input.
--- @return string|nil detail Validation failure detail.
local function build_install_transaction(target_dir, bundles_dir, bundle_name)
	if type(target_dir) ~= "string" or target_dir == "" then
		return nil, "target directory is missing"
	end
	if type(bundles_dir) ~= "string" or bundles_dir == "" then
		return nil, "source directory is missing"
	end
	if type(bundle_name) ~= "string"
		or not bundle_name:match("^Ergopti_v[%d%.]+%.bundle$") then
		return nil, "bundle name is invalid"
	end

	local target = target_dir:gsub("/+$", "")
	local source_dir = bundles_dir:match("/$") and bundles_dir or (bundles_dir .. "/")
	local sq = text_utils.shell_quote
	return table.concat({
		"target=" .. sq(target) .. ";",
		"source=" .. sq(source_dir .. bundle_name) .. ";",
		"name=" .. sq(bundle_name) .. ";",
		'mkdir -p "$target" || exit 1;',
		'work="$(mktemp -d "$target/.ergopti-install.XXXXXX")" || exit 1;',
		'stage="$work/$name";',
		'backup="$work/backup";',
		'mkdir "$backup" || { rm -rf "$work"; exit 1; };',
		'cp -R "$source" "$stage" || { rm -rf "$work"; exit 1; };',
		'test -f "$stage/Contents/Info.plist" || { rm -rf "$work"; exit 1; };',
		'committed=0;',
		'restore_install() {',
			'if [ "$committed" -eq 0 ]; then',
				'restore_ok=1;',
				'for prior in "$backup"/Ergopti_v*.bundle; do',
					'[ -e "$prior" ] || continue;',
					'mv "$prior" "$target/" || restore_ok=0;',
				'done;',
				'if [ "$restore_ok" -eq 1 ]; then',
					'rm -rf "$work";',
				'fi;',
				'return;',
			'fi;',
			'rm -rf "$work";',
		'};',
		'trap restore_install 0;',
		"trap 'exit 1' 1 2 15;",
		'for prior in "$target"/Ergopti_v*.bundle; do',
			'[ -e "$prior" ] || continue;',
			'mv "$prior" "$backup/" || exit 1;',
		'done;',
		'[ ! -e "$target/$name" ] || exit 1;',
		'mv "$stage" "$target/$name" || exit 1;',
		'committed=1;',
		'rm -rf "$backup" || true;',
		'trap - 0 1 2 15;',
		'rm -rf "$work" || true;',
		'exit 0;',
	}, " ")
end

--- Executes one user-owned shell replacement and invalidates discovery state.
--- @param target_dir string Keyboard Layouts directory receiving the bundle.
--- @param bundles_dir string Directory containing the source bundle.
--- @param bundle_name string Basename of the source bundle.
--- @return boolean committed Whether the replacement committed.
--- @return any detail Native output or validation/exception detail.
local function execute_install_transaction(target_dir, bundles_dir, bundle_name)
	local command, detail = build_install_transaction(target_dir, bundles_dir, bundle_name)
	if not command then return false, detail end
	local call_ok, output, native_ok = pcall(hs.execute, command)
	invalidate_bundle_caches()
	if not call_ok then return false, output end
	if native_ok ~= true then return false, output end
	return true, output
end

--- Removes obsolete bundles from the scope that did not receive the new copy.
--- This is deliberately post-commit: refusal can leave two valid copies, never
--- zero valid copies.
--- @param dir string Keyboard Layouts directory to clean.
--- @param scope_label string Developer-facing scope name for diagnostics.
--- @return boolean
local function cleanup_other_scope(dir, scope_label)
	local target = dir:gsub("/+$", "")
	local command = "rm -rf " .. text_utils.shell_quote(target) .. "/Ergopti_v*.bundle"
	local call_ok, output, native_ok = pcall(hs.execute, command)
	invalidate_bundle_caches()
	if not call_ok or native_ok ~= true then
		Logger.warn(LOG, "Post-install %s cleanup failed: %s.", scope_label, tostring(output))
		return false
	end
	return true
end

--- Copies the latest bundle to the user's Keyboard Layouts directory.
--- The user replacement commits before obsolete system copies are removed.
--- @param bundles_dir string Absolute path of the source bundles directory.
--- @param bundle_name string Basename of the bundle to install.
--- @return boolean true on success.
local function install_user(bundles_dir, bundle_name)
	Logger.start(LOG, "Installing %s into the user Keyboard Layouts folder…", bundle_name)
	local committed, detail = execute_install_transaction(
		USER_LAYOUTS_DIR, bundles_dir, bundle_name)
	if committed then
		cleanup_other_scope(SYSTEM_LAYOUTS_DIR, "system scope")
		Logger.success(LOG, "User install done — %s.", bundle_name)
		pcall(notifications.notify, i18n.get("menu.layout.installed_user"), nil, "success")
		return true
	end
	Logger.error(LOG, "User install failed: %s.", tostring(detail))
	return false
end

--- Copies the latest bundle to /Library/Keyboard Layouts/ via osascript with
--- administrator privileges. Triggers a macOS password prompt. The system
--- replacement commits before obsolete user copies are removed.
--- @param bundles_dir string Absolute path of the source bundles directory.
--- @param bundle_name string Basename of the bundle to install.
--- @return boolean true on success.
local function install_system(bundles_dir, bundle_name)
	Logger.start(LOG, "Installing %s into the system Keyboard Layouts folder (sudo)…", bundle_name)
	local shell_cmd, command_detail = build_install_transaction(
		SYSTEM_LAYOUTS_DIR, bundles_dir, bundle_name)
	if not shell_cmd then
		Logger.error(LOG, "System install failed: %s.", tostring(command_detail))
		return false
	end
	-- TWO layers, and only the inner one was handled. shell_cmd above is correctly
	-- quoted for /bin/sh, but shell_quote wraps in SINGLE quotes and escapes only
	-- the single quote — so a `\` or a `"` anywhere in bundles_dir, bundle_name or
	-- SYSTEM_LAYOUTS_DIR passed through untouched into this AppleScript literal.
	-- The backslash was then eaten (the privileged cp -R targeting a different
	-- path) or the quote terminated the literal outright.
	local script = text_utils.applescript_format(
		"do shell script \"%s\" with administrator privileges",
		shell_cmd
	)
	local call_ok, native_ok = false, false
	if hs.osascript and type(hs.osascript.applescript) == "function" then
		call_ok, native_ok = pcall(hs.osascript.applescript, script)
	end
	invalidate_bundle_caches()
	if call_ok and native_ok == true then
		cleanup_other_scope(USER_LAYOUTS_DIR, "user scope")
		Logger.success(LOG, "System install done — %s.", bundle_name)
		pcall(notifications.notify, i18n.get("menu.layout.installed_system"), nil, "success")
		return true
	end
	Logger.error(LOG, "System install failed (sudo cancelled or copy error).")
	return false
end



return {
	USER_LAYOUTS_DIR       = USER_LAYOUTS_DIR,
	SYSTEM_LAYOUTS_DIR     = SYSTEM_LAYOUTS_DIR,
	parse_version          = parse_version,
	version_gt             = version_gt,
	version_str            = version_str,
	pick_latest_bundle     = pick_latest_bundle,
	path_exists            = path_exists,
	highest_installed      = highest_installed,
	install_user           = install_user,
	install_system         = install_system,
	invalidate_bundle_caches = invalidate_bundle_caches,
}
